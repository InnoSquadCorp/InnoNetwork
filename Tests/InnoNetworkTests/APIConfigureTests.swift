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
        #expect(mockSession.capturedRequest?.url?.absoluteString.hasPrefix("https://api.example.com/v1/users/1") == true)
    }
}
