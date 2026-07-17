import Foundation
import Testing
import os

@testable import InnoNetwork

@Suite("Request builder overrides")
struct RequestBuilderOverridesTests {

    private struct OverrideEndpoint: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = EmptyParameter
        typealias APIResponse = BaseURLResponse

        var method: HTTPMethod { .get }
        var path: String { "/users/1" }
        var timeoutOverride: TimeInterval? { 7.5 }
        var cachePolicyOverride: URLRequest.CachePolicy? { .reloadIgnoringLocalCacheData }
        var priorityOverride: RequestPriority? { .userInitiated }
        var allowsCellularAccessOverride: Bool? { false }
        var allowsExpensiveNetworkAccessOverride: Bool? { false }
        var allowsConstrainedNetworkAccessOverride: Bool? { false }
    }

    private struct InheritsClientDefaultsEndpoint: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = EmptyParameter
        typealias APIResponse = BaseURLResponse

        var method: HTTPMethod { .get }
        var path: String { "/users/1" }
    }

    private struct GetWithBodyParameters: Encodable, Sendable {
        let token: String
    }

    private struct GetWithJSONBodyEndpoint: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = GetWithBodyParameters
        typealias APIResponse = BaseURLResponse

        var method: HTTPMethod { .get }
        var path: String { "/users/1" }
        var transport: TransportPolicy<APIResponse> { .json() }
        var parameters: GetWithBodyParameters? { GetWithBodyParameters(token: "secret") }
    }

    private struct HeadWithJSONBodyEndpoint: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = GetWithBodyParameters
        typealias APIResponse = BaseURLResponse

        var method: HTTPMethod { .head }
        var path: String { "/users/1" }
        var transport: TransportPolicy<APIResponse> { .json() }
        var parameters: GetWithBodyParameters? { GetWithBodyParameters(token: "secret") }
    }

    private struct DuplicateAuthHeaderEndpoint: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
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

    private struct CaseSensitiveMethodEndpoint: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = EmptyParameter
        typealias APIResponse = BaseURLResponse

        let method: HTTPMethod
        var path: String { "/users/1" }
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
        #expect(captured?.networkServiceType == .responsiveData)
        #expect(captured?.allowsCellularAccess == false)
        #expect(captured?.allowsExpensiveNetworkAccess == false)
        #expect(captured?.allowsConstrainedNetworkAccess == false)
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
        #expect(captured?.networkServiceType == .default)
        #expect(captured?.allowsCellularAccess == true)
        #expect(captured?.allowsExpensiveNetworkAccess == true)
        #expect(captured?.allowsConstrainedNetworkAccess == true)
    }

    @Test(
        "Methods whose spelling Foundation rewrites fail before transport",
        arguments: ["get", "head", "connect"]
    )
    func foundationCanonicalizedMethodFailsClosed(rawMethod: String) async throws {
        let method = try #require(HTTPMethod(rawValue: rawMethod))
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
            session: session
        )

        do {
            _ = try await client.request(CaseSensitiveMethodEndpoint(method: method))
            Issue.record("Expected a case-sensitive method preservation error")
        } catch let error {
            guard case .configuration(reason: .invalidRequest(let message)) = error else {
                Issue.record("Expected invalid-request configuration, got \(error)")
                return
            }
            #expect(message.contains(rawMethod))
        }
        #expect(session.capturedRequest == nil)
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

    @Test("HEAD requests with an explicit body fail before transport")
    func headWithBodyRejected() async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(BaseURLResponse(id: 1, name: "Tester"))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
            session: mockSession
        )

        do {
            _ = try await client.request(HeadWithJSONBodyEndpoint())
            Issue.record("Expected the HEAD request body to be rejected")
        } catch let error {
            guard case .configuration(reason: .invalidRequest(let message)) = error else {
                Issue.record("Expected invalid-request configuration, got \(error)")
                return
            }
            #expect(message.contains("HTTP HEAD"))
        }

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
