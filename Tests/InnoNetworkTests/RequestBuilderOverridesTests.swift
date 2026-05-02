import Foundation
import Testing

@testable import InnoNetwork

@Suite("Request builder overrides")
struct RequestBuilderOverridesTests {

    private struct OverrideEndpoint: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = BaseURLResponse

        var method: HTTPMethod { .get }
        var path: String { "/users/1" }
        var timeoutOverride: TimeInterval? { 7.5 }
        var cachePolicyOverride: URLRequest.CachePolicy? { .reloadIgnoringLocalCacheData }
    }

    private struct InheritsClientDefaultsEndpoint: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = BaseURLResponse

        var method: HTTPMethod { .get }
        var path: String { "/users/1" }
    }

    private struct GetWithBodyParameters: Encodable, Sendable {
        let token: String
    }

    private struct GetWithJSONBodyEndpoint: APIDefinition {
        typealias Parameter = GetWithBodyParameters
        typealias APIResponse = BaseURLResponse

        var method: HTTPMethod { .get }
        var path: String { "/users/1" }
        var transport: TransportPolicy<APIResponse> { .json() }
        var parameters: GetWithBodyParameters? { GetWithBodyParameters(token: "secret") }
    }

    @Test("Per-request timeoutOverride wins over client configuration timeout")
    func perRequestTimeoutWins() async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(BaseURLResponse(id: 1, name: "Tester"))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
            session: mockSession
        )

        _ = try await client.request(OverrideEndpoint())
        let captured = mockSession.capturedRequest
        #expect(captured?.timeoutInterval == 7.5)
        #expect(captured?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("Endpoints without overrides inherit the client defaults")
    func endpointInheritsClientDefaults() async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(BaseURLResponse(id: 1, name: "Tester"))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
            session: mockSession
        )

        _ = try await client.request(InheritsClientDefaultsEndpoint())
        let captured = mockSession.capturedRequest
        // makeTestNetworkConfiguration uses safeDefaults — timeout 30, useProtocolCachePolicy.
        #expect(captured?.timeoutInterval == 30.0)
        #expect(captured?.cachePolicy == .useProtocolCachePolicy)
    }

    @Test("GET requests with a body throw invalidRequestConfiguration")
    func getWithBodyRejected() async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(BaseURLResponse(id: 1, name: "Tester"))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            _ = try await client.request(GetWithJSONBodyEndpoint())
        }
        // The transport must not have been invoked.
        #expect(mockSession.capturedRequest == nil)
    }
}
