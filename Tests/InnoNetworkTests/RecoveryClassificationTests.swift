import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

/// Regression coverage for how the request pipeline classifies failures that
/// are not transient host or transport problems.
@Suite("Recovery Classification Tests")
struct RecoveryClassificationTests {
    private struct DataEcho: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = EmptyParameter
        typealias APIResponse = Data
        var method: HTTPMethod { .get }
        var path: String { "/echo" }
        var headers: HTTPHeaders { [] }

        var transport: TransportPolicy<Data> {
            .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
        }
    }

    private struct AuthenticatedEcho: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .required }
        typealias Parameter = EmptyParameter
        typealias APIResponse = Data
        var method: HTTPMethod { .get }
        var path: String { "/profile" }
        var headers: HTTPHeaders { [] }

        var transport: TransportPolicy<Data> {
            .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
        }
    }

    private actor CountingMonitor: NetworkMonitoring {
        private let current: NetworkSnapshot
        private let changed: NetworkSnapshot
        private(set) var waitCount = 0

        init() {
            current = NetworkSnapshot(status: .unsatisfied, interfaceTypes: [])
            changed = NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi])
        }

        func currentSnapshot() async -> NetworkSnapshot? { current }

        func waitForChange(
            from snapshot: NetworkSnapshot?,
            timeout: TimeInterval?
        ) async -> NetworkSnapshot? {
            waitCount += 1
            return changed
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private struct RefreshRejected: Error {}

    private static let immediateRetry = ExponentialBackoffRetryPolicy(
        maxRetries: 3,
        retryDelay: 0,
        jitterRatio: 0
    )

    // MARK: - Response body limit

    @Test("A response over the body limit is not retried")
    func oversizedBodyIsNotRetried() async throws {
        let oversized = Data(repeating: 0xAB, count: 4 * 1_024)
        let session = MockURLSession()
        session.setScriptedResponses(
            Array(repeating: .http(statusCode: 200, data: oversized), count: 4)
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: Self.immediateRetry,
                responseBodyBufferingPolicy: .buffered(maxBytes: 1_024)
            ),
            session: session
        )

        let error = await #expect(throws: NetworkError.self) {
            _ = try await client.request(DataEcho())
        }

        guard case .policyRejected(.responseBodyLimitExceeded(let limitBytes, let observedBytes)) = error else {
            Issue.record("Expected a body-limit rejection, got \(String(describing: error))")
            return
        }
        #expect(limitBytes == 1_024)
        #expect(observedBytes == Int64(oversized.count))
        #expect(error?.category == .policy)
        #expect(error?.errorCode == NetworkErrorCode.responseBodyLimitExceeded.rawValue)
        #expect(error?.isRetriableHint == false)
        #expect(session.capturedRequestsInOrder.count == 1)
    }

    @Test("Responses over the body limit do not open the circuit breaker")
    func oversizedBodyDoesNotOpenCircuit() async throws {
        let oversized = Data(repeating: 0xAB, count: 4 * 1_024)
        let session = MockURLSession()
        session.setScriptedResponses(
            Array(repeating: .http(statusCode: 200, data: oversized), count: 3)
                + [.http(statusCode: 200, data: Data("ok".utf8))]
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                circuitBreakerPolicy: CircuitBreakerPolicy(failureThreshold: 2, windowSize: 2),
                responseBodyBufferingPolicy: .buffered(maxBytes: 1_024)
            ),
            session: session
        )

        for _ in 0..<3 {
            let error = await #expect(throws: NetworkError.self) {
                _ = try await client.request(DataEcho())
            }
            #expect(error?.isLocalPolicyRejection == true)
        }

        // Three failures with a threshold of two would have opened the
        // circuit if a locally rejected response counted against the host.
        let body = try await client.request(DataEcho())
        #expect(body == Data("ok".utf8))
        #expect(session.capturedRequestsInOrder.count == 4)
    }

    @Test("An open circuit is not retried by the built-in retry policy")
    func openCircuitIsNotRetried() async throws {
        let session = MockURLSession()
        session.setScriptedResponses(
            Array(repeating: .http(statusCode: 503), count: 8)
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: Self.immediateRetry,
                circuitBreakerPolicy: CircuitBreakerPolicy(
                    failureThreshold: 1,
                    windowSize: 1,
                    resetAfter: .seconds(60)
                )
            ),
            session: session
        )

        // The first transport attempt opens the circuit. The retry that
        // follows is rejected locally and must end the request instead of
        // spending the remaining retry budget on the same rejection.
        let error = await #expect(throws: NetworkError.self) {
            _ = try await client.request(DataEcho())
        }

        guard case .policyRejected(.circuitOpen(let open)) = error else {
            Issue.record("Expected an open-circuit rejection, got \(String(describing: error))")
            return
        }
        #expect(open.retryAfter > 0)
        #expect(error?.errorCode == NetworkErrorCode.circuitOpen.rawValue)
        #expect(error?.isRetriableHint == false)
        #expect(session.capturedRequestsInOrder.count == 1)
    }

    // MARK: - waitsForNetworkChanges

    @Test("A retry after a server error does not wait for a network change")
    func serverErrorRetryDoesNotWaitForNetworkChange() async throws {
        let session = MockURLSession()
        session.setScriptedResponses([
            .http(statusCode: 503),
            .http(statusCode: 200, data: Data("ok".utf8)),
        ])
        let monitor = CountingMonitor()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 3,
                    retryDelay: 0,
                    jitterRatio: 0,
                    waitsForNetworkChanges: true,
                    networkChangeTimeout: 30
                ),
                networkMonitor: monitor
            ),
            session: session
        )

        let body = try await client.request(DataEcho())

        #expect(body == Data("ok".utf8))
        #expect(session.capturedRequestsInOrder.count == 2)
        #expect(await monitor.waitCount == 0)
    }

    @Test("A retry after a connectivity failure waits for a network change")
    func connectivityFailureRetryWaitsForNetworkChange() async throws {
        let session = MockURLSession()
        session.setScriptedResponses([
            .failure(URLError(.notConnectedToInternet)),
            .http(statusCode: 200, data: Data("ok".utf8)),
        ])
        let monitor = CountingMonitor()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 3,
                    retryDelay: 0,
                    jitterRatio: 0,
                    waitsForNetworkChanges: true,
                    networkChangeTimeout: 30
                ),
                networkMonitor: monitor
            ),
            session: session
        )

        let body = try await client.request(DataEcho())

        #expect(body == Data("ok".utf8))
        #expect(session.capturedRequestsInOrder.count == 2)
        #expect(await monitor.waitCount == 1)
    }

    @Test("A retry after cellular data is refused waits for a network change")
    func cellularRefusalRetryWaitsForNetworkChange() async throws {
        let session = MockURLSession()
        session.setScriptedResponses([
            .failure(URLError(.dataNotAllowed)),
            .http(statusCode: 200, data: Data("ok".utf8)),
        ])
        let monitor = CountingMonitor()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 3,
                    retryDelay: 0,
                    jitterRatio: 0,
                    waitsForNetworkChanges: true,
                    networkChangeTimeout: 30
                ),
                networkMonitor: monitor
            ),
            session: session
        )

        let body = try await client.request(DataEcho())

        #expect(body == Data("ok".utf8))
        #expect(session.capturedRequestsInOrder.count == 2)
        #expect(await monitor.waitCount == 1)
    }

    // MARK: - Session refresh failure

    @Test("A failed session refresh is an authentication failure and is not retried")
    func refreshFailureIsNotRetried() async throws {
        let session = MockURLSession()
        session.setScriptedResponses(
            Array(repeating: .http(statusCode: 401), count: 4)
        )
        let refreshCount = Counter()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: Self.immediateRetry,
                refreshTokenPolicy: RefreshTokenPolicy(
                    currentToken: { "expired" },
                    refreshToken: {
                        await refreshCount.increment()
                        throw RefreshRejected()
                    }
                )
            ),
            session: session
        )

        let error = await #expect(throws: NetworkError.self) {
            _ = try await client.request(AuthenticatedEcho())
        }

        guard case .authentication(.refreshFailed) = error else {
            Issue.record("Expected an authentication failure, got \(String(describing: error))")
            return
        }
        #expect(error?.category == .authentication)
        #expect(error?.errorCode == NetworkErrorCode.authenticationRefreshFailed.rawValue)
        #expect(error?.isRetriableHint == false)
        #expect(session.capturedRequestsInOrder.count == 1)
        #expect(await refreshCount.value == 1)
    }

    @Test("A server failure of the refresh request stays transient and is retried")
    func serverFailureDuringRefreshStaysTransient() async throws {
        let session = MockURLSession()
        session.setScriptedResponses(
            Array(repeating: .http(statusCode: 401), count: 4)
        )
        let refreshCount = Counter()
        let tokenEndpointResponse = HTTPURLResponse(
            url: URL(string: "https://auth.example.com/token")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: nil
        )!
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: Self.immediateRetry,
                refreshTokenPolicy: RefreshTokenPolicy(
                    currentToken: { "expired" },
                    refreshToken: {
                        await refreshCount.increment()
                        throw NetworkError.statusCode(
                            Response(statusCode: 503, data: Data(), response: tokenEndpointResponse)
                        )
                    }
                )
            ),
            session: session
        )

        let operation = client.start(AuthenticatedEcho())
        let error = await #expect(throws: NetworkError.self) {
            _ = try await operation.value()
        }

        // The token endpoint being unavailable says nothing about the
        // session, so the caller must not be told to sign in again.
        guard case .statusCode(let response) = error else {
            Issue.record("Expected the refresh endpoint's 503, got \(String(describing: error))")
            return
        }
        #expect(response.statusCode == 503)
        #expect(error?.isRetriableHint == true)
        #expect(session.capturedRequestsInOrder.count == 4)
        #expect(await refreshCount.value >= 1)
        let summary = await operation.failureSummary()
        #expect(summary?.recovery == .retry)
    }

    @Test("A request without a token classifies a failed proactive refresh the same way")
    func proactiveRefreshFailureUsesTheSameRule() async throws {
        let rejected = MockURLSession()
        rejected.setMockResponse(statusCode: 200, data: Data("unused".utf8))
        let rejectingClient = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: Self.immediateRetry,
                refreshTokenPolicy: RefreshTokenPolicy(
                    currentToken: { nil },
                    refreshToken: { throw RefreshRejected() }
                )
            ),
            session: rejected
        )

        let rejection = await #expect(throws: NetworkError.self) {
            _ = try await rejectingClient.request(AuthenticatedEcho())
        }
        guard case .authentication(.refreshFailed) = rejection else {
            Issue.record(
                "A rejected proactive refresh must be an authentication failure, got \(String(describing: rejection))"
            )
            return
        }
        // Nothing is sent without a token, and the failure is not retried.
        #expect(rejected.capturedRequestsInOrder.isEmpty)

        let unavailable = MockURLSession()
        unavailable.setMockResponse(statusCode: 200, data: Data("unused".utf8))
        let unavailableClient = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: RefreshTokenPolicy(
                    currentToken: { nil },
                    refreshToken: { throw URLError(.notConnectedToInternet) }
                )
            ),
            session: unavailable
        )

        let offline = await #expect(throws: NetworkError.self) {
            _ = try await unavailableClient.request(AuthenticatedEcho())
        }
        guard case .reachability(.notConnectedToInternet, _, _) = offline else {
            Issue.record(
                "An unreachable token service must stay a connectivity failure, got \(String(describing: offline))"
            )
            return
        }
    }

    @Test("A credential-rejection URLError from the refresh closure ends the session")
    func credentialRejectionFromRefreshIsAuthenticationFailure() {
        let surfaced = NetworkError.sessionRefreshFailed(URLError(.userAuthenticationRequired))

        guard case .authentication(.refreshFailed) = surfaced else {
            Issue.record("A rejected refresh credential must end the session, got \(surfaced)")
            return
        }
        #expect(NetworkError.isTransientTransportFailure(URLError(.userAuthenticationRequired)) == false)
        #expect(NetworkError.isTransientTransportFailure(URLError(.badServerResponse)))
    }

    @Test("A configuration failure while refreshing keeps its identity")
    func configurationFailureDuringRefreshIsNotAnAuthenticationFailure() {
        let surfaced = NetworkError.sessionRefreshFailed(
            NetworkError.configuration(reason: .invalidBaseURL("token client base URL"))
        )

        guard case .configuration(reason: .invalidBaseURL) = surfaced else {
            Issue.record("A misconfigured token client is not an expired session, got \(surfaced)")
            return
        }
    }

    @Test("A connectivity failure while refreshing stays a connectivity failure")
    func connectivityFailureDuringRefreshIsNotAnAuthenticationFailure() async throws {
        let session = MockURLSession()
        session.setScriptedResponses([.http(statusCode: 401)])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: RefreshTokenPolicy(
                    currentToken: { "expired" },
                    refreshToken: { throw URLError(.notConnectedToInternet) }
                )
            ),
            session: session
        )

        let error = await #expect(throws: NetworkError.self) {
            _ = try await client.request(AuthenticatedEcho())
        }

        guard case .reachability(let reason, _, _) = error else {
            Issue.record("Expected a reachability failure, got \(String(describing: error))")
            return
        }
        #expect(reason == .notConnectedToInternet)
    }
}
