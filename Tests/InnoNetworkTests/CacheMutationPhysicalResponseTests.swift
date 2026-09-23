import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("Physical response cache invalidation", .timeLimit(.minutes(1)))
struct CacheMutationPhysicalResponseTests {
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            let ready = waiters
            waiters.removeAll()
            for waiter in ready { waiter.resume() }
        }
    }

    private struct Endpoint: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = Data

        var sessionAuthentication: SessionAuthentication { .anonymous }
        var method: HTTPMethod = .get
        var path: String { "/resource" }
        var transport: TransportPolicy<Data> {
            .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
        }
    }

    private actor Session: URLSessionProtocol {
        private(set) var calls = 0
        let handler: @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)

        init(_ handler: @escaping @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)) {
            self.handler = handler
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            calls += 1
            return try await handler(request, calls)
        }
    }

    private struct RejectPutResult: RequestExecutionPolicy {
        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            _ = (input, context)
            let response = try await next.execute()
            if response.request?.httpMethod == "PUT" {
                throw URLError(.cannotDecodeContentData)
            }
            return response
        }
    }

    private static func reply(
        _ request: URLRequest,
        body: String,
        headers: [String: String] = [:]
    ) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)
        )
        return (Data(body.utf8), response)
    }

    @Test(
        "Successful unsafe response invalidates even when local handling throws",
        arguments: ["normal", "oversize", "policy"]
    )
    func unsafeResponseInvalidation(mode: String) async throws {
        let session = Session { request, call in
            if request.httpMethod == "PUT" {
                return try Self.reply(request, body: mode == "oversize" ? "large-body" : "ok")
            }
            return try Self.reply(
                request,
                body: call == 1 ? "old" : "new",
                headers: ["Cache-Control": "max-age=60"]
            )
        }
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .rfc9111Compliant(
                    wrapping: .cacheFirst(maxAge: .seconds(60))
                ),
                responseCache: InMemoryResponseCache(),
                customExecutionPolicies: mode == "policy" ? [RejectPutResult()] : [],
                responseBodyBufferingPolicy: .buffered(maxBytes: 4)
            ),
            session: session
        )
        #expect(try await client.request(Endpoint()) == Data("old".utf8))
        do {
            _ = try await client.request(Endpoint(method: .put))
            #expect(mode == "normal")
        } catch {
            #expect(mode != "normal")
            if mode == "oversize" {
                #expect(error.underlyingError?.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue)
            }
        }
        #expect(try await client.request(Endpoint()) == Data("new".utf8))
        #expect(await session.calls == 3)
    }

    @Test(
        "A post-mutation GET cannot join a pre-mutation physical GET",
        arguments: [false, true]
    )
    func coalescingSeparatesMutationGenerations(cancelEarlierGET: Bool) async throws {
        let firstStarted = Gate()
        let secondStarted = Gate()
        let finishGETs = Gate()
        let session = Session { request, call in
            if request.httpMethod == "PUT" {
                return try Self.reply(request, body: "ok")
            }
            if call == 1 {
                await firstStarted.release()
                await finishGETs.wait()
                return try Self.reply(
                    request, body: "old", headers: ["Cache-Control": "max-age=60"]
                )
            }
            await secondStarted.release()
            await finishGETs.wait()
            return try Self.reply(request, body: "new", headers: ["Cache-Control": "max-age=60"])
        }
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly,
                responseCachePolicy: .rfc9111Compliant(
                    wrapping: .cacheFirst(maxAge: .seconds(60))
                ),
                responseCache: InMemoryResponseCache()
            ),
            session: session
        )

        let before = Task { try await client.request(Endpoint()) }
        await firstStarted.wait()
        _ = try await client.request(Endpoint(method: .put))
        let after = Task { try await client.request(Endpoint()) }
        await secondStarted.wait()
        if cancelEarlierGET { before.cancel() }
        await finishGETs.release()

        do {
            let old = try await before.value
            #expect(!cancelEarlierGET)
            #expect(old == Data("old".utf8))
        } catch {
            #expect(cancelEarlierGET)
            #expect(NetworkError.isCancellation(error))
        }
        #expect(try await after.value == Data("new".utf8))
        #expect(try await client.request(Endpoint()) == Data("new".utf8))
        #expect(await session.calls == 3)
    }
}
