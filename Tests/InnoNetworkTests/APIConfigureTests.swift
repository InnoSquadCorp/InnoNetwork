import Foundation
import Testing

@testable import InnoNetwork

struct BaseURLDispatchRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = BaseURLResponse

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}


struct BaseURLResponse: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}


@Suite("Base URL Configuration Tests")
struct BaseURLConfigurationTests {
    @Test("safeDefaults produces the public default configuration profile")
    func safeDefaultsProfile() {
        let baseURL = URL(string: "https://api.example.com/v1")!
        let config = NetworkConfiguration.safeDefaults(baseURL: baseURL)

        #expect(config.baseURL == baseURL)
        #expect(config.timeout == 30.0)
        #expect(config.cachePolicy == .useProtocolCachePolicy)
        if case .systemDefault = config.trustPolicy {
            _ = Bool(true)
        } else {
            Issue.record("Expected systemDefault trust policy")
        }
    }

    @Test("advanced builder overrides tuning without changing required base URL")
    func advancedBuilderOverrides() {
        let baseURL = URL(string: "https://api.example.com/v1")!
        let config = NetworkConfiguration.advanced(baseURL: baseURL) {
            $0.timeout = 45
            $0.cachePolicy = .reloadIgnoringLocalCacheData
            $0.eventDeliveryPolicy = EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 256,
                maxBufferedEventsPerConsumer: 128,
                overflowPolicy: .dropNewest
            )
        }

        #expect(config.baseURL == baseURL)
        #expect(config.timeout == 45)
        #expect(config.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(config.eventDeliveryPolicy.overflowPolicy == .dropNewest)
    }

    @Test("urlSessionConfigurationOverride is applied by makeURLSessionConfiguration()")
    func urlSessionConfigurationOverrideIsApplied() {
        let baseURL = URL(string: "https://api.example.com/v1")!
        let config = NetworkConfiguration.advanced(baseURL: baseURL) {
            $0.urlSessionConfigurationOverride = { sessionConfig in
                sessionConfig.httpAdditionalHeaders = ["X-Override": "applied"]
                sessionConfig.timeoutIntervalForRequest = 99
                return sessionConfig
            }
        }

        let resolved = config.makeURLSessionConfiguration()
        #expect(resolved.httpAdditionalHeaders?["X-Override"] as? String == "applied")
        #expect(resolved.timeoutIntervalForRequest == 99)
    }

    @Test("makeURLSessionConfiguration() returns default when no override set")
    func makeURLSessionConfigurationDefaults() {
        let baseURL = URL(string: "https://api.example.com/v1")!
        let config = NetworkConfiguration.safeDefaults(baseURL: baseURL)
        #expect(config.urlSessionConfigurationOverride == nil)
        let resolved = config.makeURLSessionConfiguration()
        // The default URLSessionConfiguration honors the system default request timeout (60s).
        #expect(resolved.timeoutIntervalForRequest > 0)
    }

    @Test("Configured baseURL is used for request dispatch")
    func baseURLDispatchesCorrectly() async throws {
        let mockSession = MockURLSession()
        let expectedResponse = BaseURLResponse(id: 1, name: "Tester")
        try mockSession.setMockJSON(expectedResponse)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let response = try await client.request(BaseURLDispatchRequest())
        #expect(response == expectedResponse)
        #expect(
            mockSession.capturedRequest?.url?.absoluteString.hasPrefix("https://api.example.com/v1/users/1") == true)
    }
}
