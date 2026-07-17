import Foundation
import Testing

@testable import InnoNetwork

private struct EndpointAck: Codable, Sendable {
    let ok: Bool
}


private struct EndpointHeaderInterceptor: RequestInterceptor {
    let name: String
    let value: String

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue(value, forHTTPHeaderField: name)
        return request
    }
}


private actor EndpointSessionAuthenticationProbe {
    private var currentTokenCallCount = 0
    private var refreshTokenCallCount = 0
    private var currentTokenCallWaiter:
        (
            minimum: Int,
            continuation: CheckedContinuation<Void, Never>
        )?

    func currentToken(_ token: String?) -> String? {
        currentTokenCallCount += 1
        if let waiter = currentTokenCallWaiter,
            currentTokenCallCount >= waiter.minimum
        {
            currentTokenCallWaiter = nil
            waiter.continuation.resume()
        }
        return token
    }

    func refreshedToken(_ token: String) -> String {
        refreshTokenCallCount += 1
        return token
    }

    func counts() -> (current: Int, refresh: Int) {
        (currentTokenCallCount, refreshTokenCallCount)
    }

    func waitForCurrentTokenCalls(_ minimum: Int) async {
        guard currentTokenCallCount < minimum else { return }
        await withCheckedContinuation { continuation in
            currentTokenCallWaiter = (minimum, continuation)
        }
    }
}


private struct FragmentPathRequest: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias Parameter = EmptyParameter
    typealias APIResponse = EmptyResponse

    var method: HTTPMethod { .get }
    var path: String { "/users#section" }
}


@Suite
struct EndpointBuilderTests {
    @Test
    func getProducesEmptyResponseEndpointWithDefaults() async {
        let endpoint = EndpointBuilder<EmptyResponse>.get("/users/42")

        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/users/42")
        #expect(endpoint.parameters == nil)
        // GET endpoints default to query-string transport, which does not set
        // a Content-Type header.
        if case .query = endpoint.transport.requestEncoding {
            // expected
        } else {
            Issue.record("Default GET transport should be .query")
        }
        #expect(endpoint.acceptableStatusCodes == nil)
    }

    @Test("HEAD builder defaults to query-string transport")
    func headProducesQueryTransportByDefault() {
        let endpoint = EndpointBuilder<EmptyResponse>(
            method: .head,
            path: "/users/42"
        )

        #expect(endpoint.method == .head)
        if case .query = endpoint.transport.requestEncoding {
            // expected
        } else {
            Issue.record("Default HEAD transport should be .query")
        }
    }

    @Test
    func decodingPromotesEndpointResponseType() async {
        struct User: Decodable, Sendable, Equatable {
            let id: Int
        }

        let endpoint: EndpointBuilder<User> = EndpointBuilder<EmptyResponse>.get(
            "/users/42"
        ).decoding(User.self)

        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/users/42")
    }

    @Test
    func authenticatedEndpointRequiresRefreshPolicy() async throws {
        let endpoint = EndpointBuilder<EmptyResponse>.get("/me")
            .authentication(.required)
            .decoding(EndpointAck.self)
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        do {
            _ = try await client.request(endpoint)
            Issue.record("Expected auth-required endpoint to reject a public client configuration")
        } catch let error {
            guard case .configuration(reason: .invalidRequest(let message)) = error else {
                Issue.record("Expected NetworkError.invalidRequestConfiguration, got \(error)")
                return
            }
            #expect(message.contains("refreshTokenPolicy"))
            #expect(mockSession.capturedRequest == nil)
        }
    }

    @Test
    func authenticatedEndpointExecutesWithRefreshPolicy() async throws {
        let endpoint = EndpointBuilder<EmptyResponse>.get("/me")
            .authentication(.required)
            .decoding(EndpointAck.self)
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let policy = RefreshTokenPolicy(
            currentToken: { "token-1" },
            refreshToken: { "token-2" }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                refreshTokenPolicy: policy
            ),
            session: mockSession
        )

        let response = try await client.request(endpoint)

        #expect(response.ok)
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
    }

    @Test("Anonymous session auth never consults or replays RefreshTokenPolicy")
    func anonymousSessionAuthenticationBypassesRefreshPolicy() async throws {
        let endpoint = EndpointBuilder<EmptyResponse>.get("/public")
            .decoding(EndpointAck.self)
        let mockSession = MockURLSession()
        let body = try JSONEncoder().encode(EndpointAck(ok: true))
        mockSession.setScriptedResponses([
            .http(statusCode: 401),
            .http(statusCode: 200, data: body),
        ])
        let probe = EndpointSessionAuthenticationProbe()
        let policy = RefreshTokenPolicy(
            currentToken: { await probe.currentToken("should-not-be-read") },
            refreshToken: { await probe.refreshedToken("should-not-be-refreshed") }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                refreshTokenPolicy: policy
            ),
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(endpoint)
        }

        #expect(mockSession.capturedRequestsInOrder.count == 1)
        #expect(
            mockSession.capturedRequestsInOrder.first?
                .value(forHTTPHeaderField: "Authorization") == nil
        )
        let counts = await probe.counts()
        #expect(counts.current == 0)
        #expect(counts.refresh == 0)
    }

    @Test("Optional session auth executes without RefreshTokenPolicy")
    func optionalSessionAuthenticationAllowsMissingRefreshPolicy() async throws {
        let endpoint = EndpointBuilder<EmptyResponse>.get("/optionally-authenticated")
            .authentication(.optional)
            .decoding(EndpointAck.self)
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let response = try await client.request(endpoint)

        #expect(response.ok)
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Optional session auth applies the current token and refreshes one 401")
    func optionalSessionAuthenticationUsesRefreshPolicyWhenPresent() async throws {
        let endpoint = EndpointBuilder<EmptyResponse>.get("/optionally-authenticated")
            .authentication(.optional)
            .decoding(EndpointAck.self)
        let mockSession = MockURLSession()
        let body = try JSONEncoder().encode(EndpointAck(ok: true))
        mockSession.setScriptedResponses([
            .http(statusCode: 401),
            .http(statusCode: 200, data: body),
        ])
        let probe = EndpointSessionAuthenticationProbe()
        let policy = RefreshTokenPolicy(
            currentToken: { await probe.currentToken("current") },
            refreshToken: { await probe.refreshedToken("refreshed") }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                refreshTokenPolicy: policy
            ),
            session: mockSession
        )

        let response = try await client.request(endpoint)

        #expect(response.ok)
        #expect(mockSession.capturedRequestsInOrder.count == 2)
        #expect(
            mockSession.capturedRequestsInOrder[0]
                .value(forHTTPHeaderField: "Authorization") == "Bearer current"
        )
        #expect(
            mockSession.capturedRequestsInOrder[1]
                .value(forHTTPHeaderField: "Authorization") == "Bearer refreshed"
        )
        let counts = await probe.counts()
        #expect(counts.current == 1)
        #expect(counts.refresh == 1)
    }

    @Test("Required session auth refreshes a missing token before first transport")
    func requiredSessionAuthenticationRefreshesBeforeTransport() async throws {
        let endpoint = EndpointBuilder<EmptyResponse>.get("/me")
            .authentication(.required)
            .decoding(EndpointAck.self)
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let probe = EndpointSessionAuthenticationProbe()
        let policy = RefreshTokenPolicy(
            currentToken: { await probe.currentToken(nil) },
            refreshToken: { await probe.refreshedToken("proactive") }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                refreshTokenPolicy: policy
            ),
            session: mockSession
        )

        let response = try await client.request(endpoint)

        #expect(response.ok)
        #expect(mockSession.capturedRequestsInOrder.count == 1)
        #expect(
            mockSession.capturedRequest?.value(forHTTPHeaderField: "Authorization")
                == "Bearer proactive"
        )
        let counts = await probe.counts()
        #expect(counts.current == 1)
        #expect(counts.refresh == 1)
    }

    @Test("Concurrent required-auth requests single-flight a proactive refresh")
    func concurrentRequiredSessionAuthenticationSingleFlightsRefresh() async throws {
        let requestCount = 8
        let endpoint = EndpointBuilder<EmptyResponse>.get("/me")
            .authentication(.required)
            .decoding(EndpointAck.self)
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let probe = EndpointSessionAuthenticationProbe()
        let policy = RefreshTokenPolicy(
            currentToken: { await probe.currentToken(nil) },
            refreshToken: {
                await probe.waitForCurrentTokenCalls(requestCount)
                return await probe.refreshedToken("single-flight")
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                refreshTokenPolicy: policy
            ),
            session: mockSession
        )

        let responses = try await withThrowingTaskGroup(
            of: EndpointAck.self,
            returning: [EndpointAck].self
        ) { group in
            for _ in 0..<requestCount {
                group.addTask {
                    try await client.request(endpoint)
                }
            }

            var responses: [EndpointAck] = []
            for try await response in group {
                responses.append(response)
            }
            return responses
        }

        #expect(responses.count == requestCount)
        #expect(responses.allSatisfy { $0.ok })
        #expect(mockSession.capturedRequestsInOrder.count == requestCount)
        #expect(
            mockSession.capturedRequestsInOrder.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer single-flight"
            }
        )
        let counts = await probe.counts()
        #expect(counts.current == requestCount)
        #expect(counts.refresh == 1)
    }

    @Test("Required-auth refresh failure reaches no transport")
    func requiredSessionAuthenticationRefreshFailureSkipsTransport() async throws {
        let endpoint = EndpointBuilder<EmptyResponse>.get("/me")
            .authentication(.required)
            .decoding(EndpointAck.self)
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let probe = EndpointSessionAuthenticationProbe()
        let policy = RefreshTokenPolicy(
            currentToken: { await probe.currentToken(nil) },
            refreshToken: {
                _ = await probe.refreshedToken("unused")
                throw URLError(.userAuthenticationRequired)
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                refreshTokenPolicy: policy
            ),
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(endpoint)
        }

        #expect(mockSession.capturedRequestsInOrder.isEmpty)
        let counts = await probe.counts()
        #expect(counts.current == 1)
        #expect(counts.refresh == 1)
    }

    @Test("Required session auth rejected by appliesTo fails before transport")
    func requiredSessionAuthenticationFailsWhenPolicyDoesNotApply() async throws {
        let endpoint = EndpointBuilder<EmptyResponse>.get("/me")
            .authentication(.required)
            .decoding(EndpointAck.self)
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let probe = EndpointSessionAuthenticationProbe()
        let policy = RefreshTokenPolicy(
            appliesTo: { _ in false },
            currentToken: { await probe.currentToken("current") },
            refreshToken: { await probe.refreshedToken("refreshed") }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                refreshTokenPolicy: policy
            ),
            session: mockSession
        )

        do {
            _ = try await client.request(endpoint)
            Issue.record("Expected required session auth to fail before transport")
        } catch let error {
            guard case .configuration(reason: .invalidRequest(let message)) = error else {
                Issue.record("Expected invalid-request configuration, got \(error)")
                return
            }
            #expect(message.contains("appliesTo"))
        }

        #expect(mockSession.capturedRequest == nil)
        let counts = await probe.counts()
        #expect(counts.current == 0)
        #expect(counts.refresh == 0)
    }

    @Test
    func decodingPreservesNoneEncodingEmptyAwareDecoder() {
        let decoder = JSONDecoder()

        let endpoint: EndpointBuilder<EndpointAck> = EndpointBuilder<EmptyResponse>
            .post("/upload")
            .transport(.multipart(decoder: decoder))
            .decoding(EndpointAck.self)

        if case .none = endpoint.transport.requestEncoding {
            // expected
        } else {
            Issue.record("Promoted multipart endpoint should keep .none request encoding")
        }
        if case .jsonAllowingEmpty(let promotedDecoder) = endpoint.transport.responseDecoding {
            #expect(promotedDecoder === decoder)
        } else {
            Issue.record("Promoted endpoint should keep the empty-aware response decoder")
        }
    }

    @Test
    func decodingPreservesCustomNoneTransportShape() async throws {
        let endpoint: EndpointBuilder<EndpointAck> = EndpointBuilder<EmptyResponse>
            .post("/custom")
            .transport(.custom(encoding: .none) { _, _ in EmptyResponse() })
            .decoding(EndpointAck.self)

        if case .none = endpoint.transport.requestEncoding {
            // expected
        } else {
            Issue.record("Promoted custom .none endpoint should keep .none request encoding")
        }
        if case .custom = endpoint.transport.responseDecoding {
            // expected
        } else {
            Issue.record("Promoted custom .none endpoint should keep a custom response strategy")
        }

        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let response = try await client.request(endpoint)

        #expect(response.ok)
        #expect(mockSession.capturedRequest?.httpBody == nil)
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test
    func decodingPreservesCustomNoneTransportValidation() async throws {
        let endpoint: EndpointBuilder<EndpointAck> = EndpointBuilder<EmptyResponse>
            .post("/custom")
            .transport(
                .custom(encoding: .none) { _, response in
                    guard response.response?.value(forHTTPHeaderField: "X-Promoted-Decode") == "allowed" else {
                        throw NetworkError.configuration(
                            reason: .invalidRequest("custom .none transport was not preserved"))
                    }
                    return EmptyResponse()
                }
            )
            .decoding(EndpointAck.self)

        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        do {
            _ = try await client.request(endpoint)
            Issue.record("Expected promoted custom .none transport validation to run")
        } catch let error {
            guard case .configuration(reason: .invalidRequest(let message)) = error else {
                Issue.record("Expected NetworkError.invalidRequestConfiguration, got \(error)")
                return
            }
            #expect(message == "custom .none transport was not preserved")
        }
    }

    @Test
    func bodyAttachesParametersAndPreservesOtherFields() throws {
        struct CreatePost: Encodable, Sendable {
            let title: String
        }

        let endpoint = EndpointBuilder<EmptyResponse>.post("/posts")
            .body(CreatePost(title: "hello"))
            .decoding(EmptyResponse.self)

        let parameters = try #require(endpoint.parameters)
        let encoded = try JSONEncoder().encode(parameters)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["title"] as? String == "hello")
        #expect(endpoint.method == .post)
        #expect(endpoint.path == "/posts")
    }

    @Test
    func headerCaseInsensitivelyReplacesValues() async {
        let endpoint = EndpointBuilder<EmptyResponse>.get("/items")
            .header("X-Trace-ID", value: "abc")
            .header("x-trace-id", value: "def")

        // Headers collapse case-insensitively, so the second value wins.
        #expect(endpoint.headers.value(for: "X-Trace-ID") == "def")
    }

    @Test
    func acceptableStatusCodesOverrideIsCarriedThroughDecoding() async {
        let endpoint = EndpointBuilder<EmptyResponse>.get("/maybe")
            .acceptableStatusCodes([200, 304])
            .decoding(EmptyResponse.self)

        #expect(endpoint.acceptableStatusCodes == [200, 304])
    }

    @Test
    func transportBuilderUpdatesEndpointEncodingWithoutStoringContentTypeHeader() async {
        let endpoint = EndpointBuilder<EmptyResponse>.post("/login")
            .transport(.formURLEncoded())

        if case .formURLEncoded = endpoint.transport.requestEncoding {
            // expected
        } else {
            Issue.record("transport(.formURLEncoded()) should set requestEncoding to .formURLEncoded")
        }
        #expect(endpoint.headers.value(for: "Content-Type") == nil)
    }

    @Test
    func getQueryRequestEncodesParametersInURL() async throws {
        struct SearchQuery: Encodable, Sendable {
            let limit: Int
            let sort: String
        }
        struct SearchResponse: Codable, Sendable {
            let ok: Bool
        }

        let mockSession = MockURLSession()
        try mockSession.setMockJSON(SearchResponse(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let endpoint = EndpointBuilder<EmptyResponse>.get("/users")
            .query(SearchQuery(limit: 10, sort: "name"))
            .decoding(SearchResponse.self)

        _ = try await client.request(endpoint)

        let url = try #require(mockSession.capturedRequest?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/v1/users")
        #expect(components.queryItems?.contains(URLQueryItem(name: "limit", value: "10")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "sort", value: "name")) == true)
        #expect(mockSession.capturedRequest?.httpBody == nil)
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test
    func noBodyGetDoesNotSendContentType() async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        _ = try await client.request(
            EndpointBuilder<EmptyResponse>.get("/users/1").decoding(EndpointAck.self))

        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test
    func bodylessPostDoesNotSendDefaultJSONContentType() async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        _ = try await client.request(
            EndpointBuilder<EmptyResponse>.post("/ping").decoding(EndpointAck.self))

        #expect(mockSession.capturedRequest?.httpBody == nil)
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test
    func postBodyRequestCarriesJSONContentTypeHeader() async throws {
        struct CreatePost: Encodable, Sendable {
            let title: String
        }
        struct CreatedPost: Codable, Sendable {
            let ok: Bool
        }

        let mockSession = MockURLSession()
        try mockSession.setMockJSON(CreatedPost(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let endpoint = EndpointBuilder<EmptyResponse>.post("/posts")
            .body(CreatePost(title: "hello"))
            .decoding(CreatedPost.self)

        _ = try await client.request(endpoint)

        let contentType = try #require(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.contains("application/json"))
    }

    @Test
    func transportBuilderIsReflectedInRequestHeader() async throws {
        struct Login: Encodable, Sendable {
            let username: String
        }
        struct LoginResponse: Codable, Sendable {
            let ok: Bool
        }

        let mockSession = MockURLSession()
        try mockSession.setMockJSON(LoginResponse(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let endpoint = EndpointBuilder<EmptyResponse>.post("/login")
            .transport(.formURLEncoded())
            .body(Login(username: "test"))
            .decoding(LoginResponse.self)

        _ = try await client.request(endpoint)

        let contentType = try #require(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.contains("application/x-www-form-urlencoded"))
    }

    @Test
    func switchingTransportToQueryDoesNotKeepStaleContentType() async throws {
        struct Login: Encodable, Sendable {
            let username: String
        }

        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let endpoint = EndpointBuilder<EmptyResponse>.post("/login")
            .transport(.formURLEncoded())
            .transport(.query())
            .query(Login(username: "test"))
            .decoding(EndpointAck.self)

        _ = try await client.request(endpoint)

        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == nil)
        let url = try #require(mockSession.capturedRequest?.url)
        let queryItems = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(queryItems.contains(URLQueryItem(name: "username", value: "test")))
    }

    @Test
    func bodyContentTypeOverridesEndpointHeader() async throws {
        var headers = HTTPHeaders.default
        headers.add(name: "Content-Type", value: "text/plain")
        headers.add(name: "X-Custom", value: "kept")
        struct CreatePost: Encodable, Sendable {
            let title: String
        }

        let endpoint = EndpointBuilder<EmptyResponse>.post("/posts")
            .headers(headers)
            .body(CreatePost(title: "hello"))
            .decoding(EndpointAck.self)

        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        _ = try await client.request(endpoint)

        let contentType = mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type")
        #expect(contentType == "application/json; charset=UTF-8")
        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "X-Custom") == "kept")
    }

    @Test
    func requestInterceptorOverridesAutomaticContentType() async throws {
        struct CreatePost: Encodable, Sendable {
            let title: String
        }
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                requestInterceptors: [
                    EndpointHeaderInterceptor(name: "Content-Type", value: "application/vnd.api+json")
                ]
            ),
            session: mockSession
        )

        _ = try await client.request(
            EndpointBuilder<EmptyResponse>.post("/posts")
                .body(CreatePost(title: "hello"))
                .decoding(EndpointAck.self)
        )

        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/vnd.api+json")
    }

    @Test
    func baseURLPathLeadingSlashAndEncodedEndpointPathArePreserved() async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/api/v1"),
            session: mockSession
        )

        _ = try await client.request(
            EndpointBuilder<EmptyResponse>.get("/files/a%2Fb").decoding(EndpointAck.self))

        #expect(mockSession.capturedRequest?.url?.absoluteString == "https://api.example.com/api/v1/files/a%2Fb")
    }

    @Test(
        "Endpoint paths are safely percent-encoded without double-encoding literals",
        arguments: [
            ("/files/raw space", "https://api.example.com/api/v1/files/raw%20space"),
            ("/files/caf\u{00E9}", "https://api.example.com/api/v1/files/caf%C3%A9"),
            ("/files/%E2%9C%93", "https://api.example.com/api/v1/files/%E2%9C%93"),
        ])
    func endpointPathEncodingIsCrashSafe(path: String, expectedURL: String) async throws {
        let mockSession = MockURLSession()
        try mockSession.setMockJSON(EndpointAck(ok: true))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/api/v1"),
            session: mockSession
        )

        _ = try await client.request(
            EndpointBuilder<EmptyResponse>.get(path).decoding(EndpointAck.self))

        #expect(mockSession.capturedRequest?.url?.absoluteString == expectedURL)
    }

    @Test("Dynamic path segments encode slashes and percent signs")
    func dynamicPathSegmentsAreEncodedAsSingleSegments() async {
        #expect(
            EndpointPathEncoding.percentEncodedSegment("a/b 100% \u{2713}")
                == "a%2Fb%20100%25%20%E2%9C%93")
    }

    @Test("Dynamic dot segments are encoded then rejected before transport")
    func dynamicDotSegmentsFailClosedBeforeTransport() async throws {
        for value in [".", "..", "../admin"] {
            let encoded = EndpointPathEncoding.percentEncodedSegment(value)
            if value == "." { #expect(encoded == "%2E") }
            if value == ".." { #expect(encoded == "%2E%2E") }

            let mockSession = MockURLSession()
            let client = DefaultNetworkClient(
                configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
                session: mockSession
            )

            await #expect(throws: NetworkError.self) {
                try await client.request(
                    EndpointBuilder<EmptyResponse>.get("/users/\(encoded)")
                )
            }
            #expect(mockSession.capturedRequest == nil)
        }
    }

    @Test("Dynamic path segments support primitive, UUID, and raw-value identifiers")
    func dynamicPathSegmentsSupportIdentifierTypes() async throws {
        enum Scope: String, Sendable {
            case nested = "admin/root"
        }

        let uuid = try #require(UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-1234567890AB"))

        #expect(EndpointPathEncoding.percentEncodedSegment(42) == "42")
        #expect(EndpointPathEncoding.percentEncodedSegment(uuid) == "A1B2C3D4-E5F6-4789-ABCD-1234567890AB")
        #expect(EndpointPathEncoding.percentEncodedSegment(Scope.nested) == "admin%2Froot")
    }

    @Test(
        "Malformed endpoint paths fail before transport",
        arguments: [
            "/files/%", "/files/%2", "/files/%ZZ", "/files/%ＦＦ", "/users?name=kim",
            "/users#section",
        ])
    func malformedEndpointPathThrows(path: String) async {
        let mockSession = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(EndpointBuilder<EmptyResponse>.get(path))
        }
        #expect(mockSession.capturedRequest == nil)
    }

    @Test
    func endpointPathCannotContainQueryOrFragment() async {
        let mockSession = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(FragmentPathRequest())
        }
        #expect(mockSession.capturedRequest == nil)
    }

    @Test
    func acceptableStatusCodesOverrideIsUsedByExecution() async throws {
        struct AcceptedResponse: Codable, Sendable {
            let ok: Bool
        }

        let mockSession = MockURLSession()
        try mockSession.setMockJSON(AcceptedResponse(ok: true), statusCode: 304)
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let endpoint = EndpointBuilder<EmptyResponse>.get("/empty")
            .acceptableStatusCodes([304])
            .decoding(AcceptedResponse.self)

        let response = try await client.request(endpoint)
        #expect(response.ok)
    }
}
