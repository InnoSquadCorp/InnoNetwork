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
