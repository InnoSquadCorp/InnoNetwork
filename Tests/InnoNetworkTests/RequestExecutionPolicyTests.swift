import Foundation
import Testing
import os

@testable import InnoNetwork

@Suite("Request Execution Policy Tests")
struct RequestExecutionPolicyTests {
    private struct DataEcho: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = Data

        var method: HTTPMethod { .get }
        var path: String { "/policy" }
        var transport: TransportPolicy<Data> {
            .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
        }
    }

    private struct HeaderPolicy: RequestExecutionPolicy {
        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            var request = input.request
            request.setValue("policy-\(context.retryIndex)", forHTTPHeaderField: "X-Policy")
            return try await next.execute(request)
        }
    }

    private struct BodyRewritePolicy: RequestExecutionPolicy {
        let body: Data

        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            let response = try await next.execute(input.request)
            guard let httpResponse = response.response else { return response }
            return Response(
                statusCode: response.statusCode,
                data: body,
                request: response.request,
                response: httpResponse
            )
        }
    }

    @Test("Custom execution policy can adapt the transport request")
    func customPolicyAdaptsTransportRequest() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("ok".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                customExecutionPolicies: [HeaderPolicy()]
            ),
            session: mockSession
        )

        _ = try await client.request(DataEcho())

        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "X-Policy") == "policy-0")
    }

    @Test("Custom execution policy can rewrite the transport response before decode")
    func customPolicyRewritesResponseBeforeDecode() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("original".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                customExecutionPolicies: [BodyRewritePolicy(body: Data("rewritten".utf8))]
            ),
            session: mockSession
        )

        let data = try await client.request(DataEcho())

        #expect(String(data: data, encoding: .utf8) == "rewritten")
    }

    private final class CountingObserver: NetworkEventObserving, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[NetworkEvent]>(initialState: [])

        func handle(_ event: NetworkEvent) async {
            lock.withLock { $0.append(event) }
        }

        var responseReceivedCount: Int {
            lock.withLock { events in
                events.reduce(into: 0) { count, event in
                    if case .responseReceived = event { count += 1 }
                }
            }
        }
    }

    private struct ReplayingPolicy: RequestExecutionPolicy {
        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            _ = try await next.execute(input.request)
            return try await next.execute(input.request)
        }
    }

    @Test("responseReceived fires per transport invocation, not per top-level call")
    func responseReceivedFiresPerTransportInvocation() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("ok".utf8))
        let observer = CountingObserver()

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                eventObservers: [observer],
                customExecutionPolicies: [ReplayingPolicy()]
            ),
            session: mockSession
        )

        _ = try await client.request(DataEcho())

        #expect(observer.responseReceivedCount == 2)
    }

    private struct ThrowingPolicy: RequestExecutionPolicy {
        struct PolicyError: Error {}

        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            _ = (input, context, next)
            throw PolicyError()
        }
    }

    @Test("Throwing policy bypasses transport and propagates the error")
    func throwingPolicyBypassesTransport() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("unused".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                customExecutionPolicies: [ThrowingPolicy()]
            ),
            session: mockSession
        )

        do {
            _ = try await client.request(DataEcho())
            Issue.record("Expected ThrowingPolicy.PolicyError to propagate")
        } catch let error as NetworkError {
            switch error {
            case .underlying:
                // Throwing policies surface as `.underlying`; transport never fired.
                break
            default:
                Issue.record("Expected NetworkError.underlying wrapping PolicyError, got \(error)")
            }
        } catch {
            Issue.record("Expected NetworkError, got \(error)")
        }
        #expect(mockSession.capturedRequest == nil)
    }

    private struct StreamingBodyPolicy: RequestExecutionPolicy {
        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            try await next.execute(input.request)
        }
    }

    @Test("Streaming with maxBytes does not silently fall back to a buffered transport")
    func streamingWithMaxBytesDoesNotFallBack() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data(repeating: 0xAB, count: 8_192))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseBodyBufferingPolicy: .streaming(maxBytes: 1_024)
            ),
            session: mockSession
        )

        do {
            _ = try await client.request(DataEcho())
            Issue.record("Expected NetworkError.invalidRequestConfiguration")
        } catch let error as NetworkError {
            switch error {
            case .invalidRequestConfiguration:
                // Expected: streaming bytes() not supported, no buffered fallback.
                break
            default:
                Issue.record("Expected NetworkError.invalidRequestConfiguration, got \(error)")
            }
        }
        #expect(mockSession.capturedRequest == nil)
    }
}
