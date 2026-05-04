import Foundation
import Testing
import os

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

    private struct DuplicateAuthHeaderEndpoint: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = BaseURLResponse

        var method: HTTPMethod { .get }
        var path: String { "/users/1" }
        var headers: HTTPHeaders {
            var headers = HTTPHeaders.default
            headers.add(name: "Authorization", value: "Bearer stale")
            headers.add(name: "authorization", value: "Bearer fresh")
            return headers
        }
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

    @Test("Request builder applies single-value header semantics")
    func duplicateSingleValueHeadersUseLastValue() async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(BaseURLResponse(id: 1, name: "Tester"))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
            session: mockSession
        )

        _ = try await client.request(DuplicateAuthHeaderEndpoint())

        #expect(
            mockSession.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
        )
    }

    @Test("Default header providers are evaluated for each request")
    func defaultHeaderProvidersRefreshEachRequest() async throws {
        let userAgent = OSAllocatedUnfairLock(initialState: "TestApp/1")
        let acceptLanguage = OSAllocatedUnfairLock(initialState: "en-US")
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(BaseURLResponse(id: 1, name: "Tester"))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                userAgentProvider: { userAgent.withLock { $0 } },
                acceptLanguageProvider: { acceptLanguage.withLock { $0 } }
            ),
            session: mockSession
        )

        _ = try await client.request(InheritsClientDefaultsEndpoint())
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "User-Agent") == "TestApp/1")
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Accept-Language") == "en-US")

        userAgent.withLock { $0 = "TestApp/2" }
        acceptLanguage.withLock { $0 = "ko-KR" }

        _ = try await client.request(InheritsClientDefaultsEndpoint())
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "User-Agent") == "TestApp/2")
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Accept-Language") == "ko-KR")
    }
}
