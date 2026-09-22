import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("Cache lifecycle regression tests", .timeLimit(.minutes(1)))
struct CacheLifecycleRegressionTests {
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            let ready = waiters
            waiters.removeAll()
            for waiter in ready { waiter.resume() }
        }
    }

    private actor RevalidationObserver: NetworkEventObserving {
        let finished = Gate()
        func handle(_ event: NetworkEvent) async {
            guard case .cacheRevalidation(_, let state) = event else { return }
            switch state {
            case .scheduled: break
            case .completed, .notModified, .failed: await finished.open()
            }
        }
    }

    private actor WrappingPolicy: RequestExecutionPolicy {
        let rejectBackground: Bool
        private(set) var calls = 0
        init(rejectBackground: Bool = false) { self.rejectBackground = rejectBackground }
        func execute(input: RequestExecutionInput, context: RequestExecutionContext, next: RequestExecutionNext) async throws -> Response {
            calls += 1
            if rejectBackground, calls > 1 { throw URLError(.cancelled) }
            let response = try await next.execute()
            let http = try #require(response.response)
            return Response(statusCode: response.statusCode, data: Data("wrapped:".utf8) + response.data,
                            request: response.request, response: http)
        }
    }
    private struct Endpoint: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = Data
        var sessionAuthentication: SessionAuthentication { .anonymous }
        var method: HTTPMethod = .get
        var path: String = "/resource"
        var headers: HTTPHeaders = []
        var transport: TransportPolicy<Data> {
            .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
        }
    }

    private actor Session: URLSessionProtocol {
        let handler: @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)
        private(set) var calls = 0

        init(_ handler: @escaping @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)) {
            self.handler = handler
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            calls += 1
            return try await handler(request, calls)
        }
    }

    private static func reply(
        _ request: URLRequest,
        status: Int = 200,
        body: String = "old",
        headers: [String: String] = [:]
    ) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: headers
        ))
        return (Data(body.utf8), response)
    }

    @Test("Request no-store prevents writes even when the origin permits caching",
          arguments: ["no-store", "max-age=60, No-Store"])
    func requestNoStoreDoesNotPersist(directive: String) async throws {
        let cache = InMemoryResponseCache()
        let session = Session { request, call in
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == directive)
            return try Self.reply(request, body: "value-\(call)", headers: ["Cache-Control": "max-age=60"])
        }
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .rfc9111Compliant(wrapping: .cacheFirst(maxAge: .seconds(60))),
                responseCache: cache
            ), session: session
        )
        let endpoint = Endpoint(headers: [HTTPHeader(name: "Cache-Control", value: directive)])
        #expect(try await client.request(endpoint) == Data("value-1".utf8))
        #expect(try await client.request(endpoint) == Data("value-2".utf8))
        #expect(await session.calls == 2)
    }

    @Test("Request no-store does not invalidate an already reusable response")
    func requestNoStorePreservesExistingEntry() async throws {
        let session = Session { request, _ in
            try Self.reply(request, headers: ["Cache-Control": "max-age=60"])
        }
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: InMemoryResponseCache()
            ), session: session
        )
        _ = try await client.request(Endpoint())
        let endpoint = Endpoint(headers: [HTTPHeader(name: "Cache-Control", value: "no-store")])
        #expect(try await client.request(endpoint) == Data("old".utf8))
        #expect(try await client.request(Endpoint()) == Data("old".utf8))
        #expect(await session.calls == 1)
    }

    @Test("Background cache revalidation runs custom response policies")
    func backgroundRevalidationRunsPolicies() async throws {
        let clock = TestClock()
        let observer = RevalidationObserver()
        let policy = WrappingPolicy()
        let session = Session { request, call in try Self.reply(request, body: "raw-\(call)") }
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com", eventObservers: [observer],
                responseCachePolicy: .staleWhileRevalidate(maxAge: .seconds(1), staleWindow: .seconds(60)),
                responseCache: InMemoryResponseCache(), customExecutionPolicies: [policy]
            ), session: session, clock: clock
        )
        #expect(try await client.request(Endpoint()) == Data("wrapped:raw-1".utf8))
        clock.advance(by: .seconds(2))
        #expect(try await client.request(Endpoint()) == Data("wrapped:raw-1".utf8))
        await observer.finished.wait()
        #expect(try await client.request(Endpoint()) == Data("wrapped:raw-2".utf8))
        #expect(await policy.calls == 2)
        #expect(await session.calls == 2)
    }
}
