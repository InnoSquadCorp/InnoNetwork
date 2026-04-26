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
            case .timeout(.requestTimeout):
                break
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
            case .timeout(.connectionTimeout):
                break
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

        #expect(request.errorDescription?.contains("request") == true)
        #expect(connection.errorDescription?.contains("connection") == true)
        #expect(resource.errorDescription?.contains("resource") == true)
    }

    @Test("response and underlyingError are nil for .timeout")
    func responseAccessorsNilForTimeout() {
        let error = NetworkError.timeout(reason: .requestTimeout)
        #expect(error.response == nil)
    }
}
