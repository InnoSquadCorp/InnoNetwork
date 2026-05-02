import Foundation
import Testing

@testable import InnoNetwork

private struct TimingOutAPIRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = EmptyEcho

    var method: HTTPMethod { .get }
    var path: String { "/slow" }
}


private struct EmptyEcho: APIDefinition, HTTPEmptyResponseDecodable {
    typealias Parameter = EmptyParameter
    typealias APIResponse = EmptyEcho
    var method: HTTPMethod { .get }
    var path: String { "/x" }

    static func emptyResponseValue() -> EmptyEcho { EmptyEcho() }
}


@Suite("NetworkError Timeout Tests")
struct NetworkErrorTimeoutTests {

    @Test("URLError.timedOut maps to NetworkError.timeout(.requestTimeout)")
    func urlErrorTimedOutMaps() async throws {
        let mockSession = MockURLSession()
        mockSession.mockError = URLError(.timedOut)
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )
        do {
            _ = try await client.request(TimingOutAPIRequest())
            Issue.record("Expected timeout error")
        } catch let error as NetworkError {
            switch error {
            case .timeout(.requestTimeout, let underlying):
                #expect(underlying?.domain == NSURLErrorDomain)
                #expect(underlying?.code == URLError.Code.timedOut.rawValue)
            default:
                Issue.record("Expected NetworkError.timeout(.requestTimeout), got \(error)")
            }
        }
    }

    @Test("URLError.cannotConnectToHost maps to NetworkError.timeout(.connectionTimeout)")
    func urlErrorCannotConnectMapsToConnectionTimeout() async throws {
        let mockSession = MockURLSession()
        mockSession.mockError = URLError(.cannotConnectToHost)
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )
        do {
            _ = try await client.request(TimingOutAPIRequest())
            Issue.record("Expected connection timeout")
        } catch let error as NetworkError {
            switch error {
            case .timeout(.connectionTimeout, let underlying):
                #expect(underlying?.domain == NSURLErrorDomain)
                #expect(underlying?.code == URLError.Code.cannotConnectToHost.rawValue)
            default:
                Issue.record("Expected NetworkError.timeout(.connectionTimeout), got \(error)")
            }
        }
    }

    @Test("URLError.cannotFindHost remains an underlying transport error")
    func urlErrorCannotFindHostStaysUnderlying() async throws {
        let mockSession = MockURLSession()
        mockSession.mockError = URLError(.cannotFindHost)
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )
        do {
            _ = try await client.request(TimingOutAPIRequest())
            Issue.record("Expected underlying DNS error")
        } catch let error as NetworkError {
            switch error {
            case .underlying(let underlying, nil):
                #expect(underlying.domain == NSURLErrorDomain)
                #expect(underlying.code == URLError.Code.cannotFindHost.rawValue)
            default:
                Issue.record("Expected NetworkError.underlying for cannotFindHost, got \(error)")
            }
        }
    }

    @Test("ExponentialBackoffRetryPolicy retries on .timeout")
    func policyRetriesOnTimeout() {
        let policy = ExponentialBackoffRetryPolicy(maxRetries: 2)
        #expect(policy.shouldRetry(error: .timeout(reason: .requestTimeout), retryIndex: 0) == true)
        #expect(policy.shouldRetry(error: .timeout(reason: .connectionTimeout), retryIndex: 1) == true)
        #expect(policy.shouldRetry(error: .timeout(reason: .resourceTimeout), retryIndex: 2) == false)
    }

    @Test("Localized description differentiates between timeout reasons")
    func localizedDescriptionDifferentiates() {
        let request = NetworkError.timeout(reason: .requestTimeout)
        let connection = NetworkError.timeout(reason: .connectionTimeout)
        let resource = NetworkError.timeout(reason: .resourceTimeout)

        let descriptions = [
            request.errorDescription,
            connection.errorDescription,
            resource.errorDescription,
        ].compactMap { $0 }
        #expect(descriptions.count == 3)
        #expect(Set(descriptions).count == 3, "Each reason must produce a distinct description: \(descriptions)")
    }

    @Test("response and underlyingError are nil for .timeout")
    func responseAccessorsNilForTimeout() {
        let error = NetworkError.timeout(reason: .requestTimeout)
        #expect(error.response == nil)
        #expect(error.underlyingError == nil)
    }

    @Test("NSError bridge uses stable domain and codes")
    func nsErrorBridgeUsesStableDomainAndCodes() {
        let timeout = NetworkError.timeout(reason: .requestTimeout) as NSError
        let cancelled = NetworkError.cancelled as NSError
        let invalidRequest = NetworkError.invalidRequestConfiguration("bad") as NSError

        #expect(timeout.domain == NetworkError.errorDomain)
        #expect(timeout.code == NSURLErrorTimedOut)
        #expect(cancelled.code == NSURLErrorCancelled)
        #expect(invalidRequest.code == 1002)
    }

    @Test("URLError.cancelled maps to NetworkError.cancelled, not a timeout")
    func urlErrorCancelledMapsToCancelled() async throws {
        let mockSession = MockURLSession()
        mockSession.mockError = URLError(.cancelled)
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )
        do {
            _ = try await client.request(TimingOutAPIRequest())
            Issue.record("Expected cancellation")
        } catch let error as NetworkError {
            switch error {
            case .cancelled: break
            default: Issue.record("Expected NetworkError.cancelled, got \(error)")
            }
        }
    }

    @Test("URLError.networkConnectionLost stays underlying (mid-flight drop is not a timeout)")
    func urlErrorNetworkConnectionLostStaysUnderlying() async throws {
        let mockSession = MockURLSession()
        mockSession.mockError = URLError(.networkConnectionLost)
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )
        do {
            _ = try await client.request(TimingOutAPIRequest())
            Issue.record("Expected underlying error")
        } catch let error as NetworkError {
            switch error {
            case .underlying(let underlying, nil):
                #expect(underlying.code == URLError.Code.networkConnectionLost.rawValue)
            default:
                Issue.record("Expected NetworkError.underlying for networkConnectionLost, got \(error)")
            }
        }
    }

    // MARK: - mapTransportError contract lock (P1.11)
    //
    // Locks the documented URLError → NetworkError surface so a future
    // edit cannot silently collapse reachability/DNS failures into
    // `.timeout` (which would change retry policies and user-facing copy).

    @Test("mapTransportError: URLError.timedOut → .timeout(.requestTimeout)")
    func mapTimedOutContract() {
        let error = NetworkError.mapTransportError(URLError(.timedOut))
        guard case .timeout(.requestTimeout, let underlying) = error else {
            Issue.record("Expected .timeout(.requestTimeout), got \(error)")
            return
        }
        #expect(underlying?.code == URLError.Code.timedOut.rawValue)
        #expect(underlying?.domain == NSURLErrorDomain)
    }

    @Test("mapTransportError: URLError.cannotConnectToHost → .timeout(.connectionTimeout)")
    func mapCannotConnectToHostContract() {
        let error = NetworkError.mapTransportError(URLError(.cannotConnectToHost))
        guard case .timeout(.connectionTimeout, let underlying) = error else {
            Issue.record("Expected .timeout(.connectionTimeout), got \(error)")
            return
        }
        #expect(underlying?.code == URLError.Code.cannotConnectToHost.rawValue)
    }

    @Test("mapTransportError: URLError.cannotFindHost → .underlying (DNS, not a timeout)")
    func mapCannotFindHostContract() {
        let error = NetworkError.mapTransportError(URLError(.cannotFindHost))
        guard case .underlying(let underlying, nil) = error else {
            Issue.record("Expected .underlying for cannotFindHost, got \(error)")
            return
        }
        #expect(underlying.code == URLError.Code.cannotFindHost.rawValue)
    }

    @Test("mapTransportError: URLError.dnsLookupFailed → .underlying (DNS, not a timeout)")
    func mapDNSLookupFailedContract() {
        let error = NetworkError.mapTransportError(URLError(.dnsLookupFailed))
        guard case .underlying(let underlying, nil) = error else {
            Issue.record("Expected .underlying for dnsLookupFailed, got \(error)")
            return
        }
        #expect(underlying.code == URLError.Code.dnsLookupFailed.rawValue)
    }

    @Test("mapTransportError: URLError.networkConnectionLost → .underlying (mid-flight drop, not a timeout)")
    func mapNetworkConnectionLostContract() {
        let error = NetworkError.mapTransportError(URLError(.networkConnectionLost))
        guard case .underlying(let underlying, nil) = error else {
            Issue.record("Expected .underlying for networkConnectionLost, got \(error)")
            return
        }
        #expect(underlying.code == URLError.Code.networkConnectionLost.rawValue)
    }

    @Test("mapTransportError: URLError.notConnectedToInternet → .underlying (reachability, not a timeout)")
    func mapNotConnectedContract() {
        let error = NetworkError.mapTransportError(URLError(.notConnectedToInternet))
        guard case .underlying(let underlying, nil) = error else {
            Issue.record("Expected .underlying for notConnectedToInternet, got \(error)")
            return
        }
        #expect(underlying.code == URLError.Code.notConnectedToInternet.rawValue)
    }

    @Test("mapTransportError: URLError.cancelled → .cancelled (collapses with CancellationError)")
    func mapCancelledContract() {
        let error = NetworkError.mapTransportError(URLError(.cancelled))
        guard case .cancelled = error else {
            Issue.record("Expected .cancelled for URLError.cancelled, got \(error)")
            return
        }
    }

    // MARK: - mapTransportError(_:metrics:resourceTimeoutInterval:)

    @Test("mapTransportError(metrics:): elapsed at or beyond resource budget → .resourceTimeout")
    func mapResourceTimeoutFromMetrics() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(60)
        let metrics = StubURLSessionTaskMetrics(taskInterval: DateInterval(start: start, end: end))
        let error = NetworkError.mapTransportError(
            URLError(.timedOut),
            metrics: metrics,
            resourceTimeoutInterval: 60
        )
        guard case .timeout(.resourceTimeout, let underlying) = error else {
            Issue.record("Expected .timeout(.resourceTimeout), got \(error)")
            return
        }
        #expect(underlying?.code == URLError.Code.timedOut.rawValue)
    }

    @Test("mapTransportError(metrics:): elapsed below resource budget → .requestTimeout")
    func mapRequestTimeoutWhenBelowBudget() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(15)
        let metrics = StubURLSessionTaskMetrics(taskInterval: DateInterval(start: start, end: end))
        let error = NetworkError.mapTransportError(
            URLError(.timedOut),
            metrics: metrics,
            resourceTimeoutInterval: 60
        )
        guard case .timeout(.requestTimeout, _) = error else {
            Issue.record("Expected .timeout(.requestTimeout) for sub-budget elapsed, got \(error)")
            return
        }
    }

    @Test("mapTransportError(metrics:): missing inputs fall back to .requestTimeout")
    func mapFallsBackWhenMetricsMissing() {
        let nilMetrics = NetworkError.mapTransportError(
            URLError(.timedOut),
            metrics: nil,
            resourceTimeoutInterval: 60
        )
        guard case .timeout(.requestTimeout, _) = nilMetrics else {
            Issue.record("Expected .requestTimeout when metrics are nil, got \(nilMetrics)")
            return
        }

        let nilInterval = NetworkError.mapTransportError(
            URLError(.timedOut),
            metrics: StubURLSessionTaskMetrics(
                taskInterval: DateInterval(
                    start: Date(timeIntervalSince1970: 0),
                    end: Date(timeIntervalSince1970: 600)
                )
            ),
            resourceTimeoutInterval: nil
        )
        guard case .timeout(.requestTimeout, _) = nilInterval else {
            Issue.record("Expected .requestTimeout when interval is nil, got \(nilInterval)")
            return
        }
    }

    @Test("mapTransportError: existing NetworkError flows through unchanged")
    func mapPassesThroughExistingNetworkError() {
        let original = NetworkError.invalidRequestConfiguration("seed")
        let mapped = NetworkError.mapTransportError(original)
        guard case .invalidRequestConfiguration(let message) = mapped else {
            Issue.record("Expected pass-through, got \(mapped)")
            return
        }
        #expect(message == "seed")
    }

    @Test("URLError.notConnectedToInternet stays underlying (reachability is not a timeout)")
    func urlErrorNotConnectedStaysUnderlying() async throws {
        let mockSession = MockURLSession()
        mockSession.mockError = URLError(.notConnectedToInternet)
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )
        do {
            _ = try await client.request(TimingOutAPIRequest())
            Issue.record("Expected underlying error")
        } catch let error as NetworkError {
            switch error {
            case .underlying(let underlying, nil):
                #expect(underlying.code == URLError.Code.notConnectedToInternet.rawValue)
            default:
                Issue.record("Expected NetworkError.underlying for notConnectedToInternet, got \(error)")
            }
        }
    }
}

private final class StubURLSessionTaskMetrics: URLSessionTaskMetrics, @unchecked Sendable {
    private let stubbedTaskInterval: DateInterval

    init(taskInterval: DateInterval) {
        self.stubbedTaskInterval = taskInterval
        super.init()
    }

    override var taskInterval: DateInterval { stubbedTaskInterval }
}
