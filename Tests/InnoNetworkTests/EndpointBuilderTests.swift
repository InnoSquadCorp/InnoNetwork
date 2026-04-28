import Foundation
import Testing

@testable import InnoNetwork

@Suite
struct EndpointBuilderTests {
    @Test
    func getProducesEmptyResponseEndpointWithDefaults() {
        let endpoint = Endpoint.get("/users/42")

        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/users/42")
        #expect(endpoint.parameters == nil)
        #expect(endpoint.contentType == .json)
        #expect(endpoint.acceptableStatusCodes == nil)
    }

    @Test
    func decodingPromotesEndpointResponseType() {
        struct User: Decodable, Sendable, Equatable {
            let id: Int
        }

        let endpoint: Endpoint<User> = Endpoint.get("/users/42").decoding(User.self)

        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/users/42")
    }

    @Test
    func bodyAttachesParametersAndPreservesOtherFields() throws {
        struct CreatePost: Encodable, Sendable {
            let title: String
        }

        let endpoint = Endpoint.post("/posts")
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
    func headerCaseInsensitivelyReplacesValues() {
        let endpoint = Endpoint.get("/items")
            .header("X-Trace-ID", value: "abc")
            .header("x-trace-id", value: "def")

        // Headers collapse case-insensitively, so the second value wins.
        #expect(endpoint.headers.value(for: "X-Trace-ID") == "def")
    }

    @Test
    func acceptableStatusCodesOverrideIsCarriedThroughDecoding() {
        let endpoint = Endpoint.get("/maybe")
            .acceptableStatusCodes([200, 304])
            .decoding(EmptyResponse.self)

        #expect(endpoint.acceptableStatusCodes == [200, 304])
    }

    @Test
    func contentTypeBuilderUpdatesEndpointDefault() {
        let endpoint = Endpoint.post("/raw")
            .contentType(.textPlain)

        #expect(endpoint.contentType == .textPlain)
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

        let endpoint = Endpoint.post("/posts")
            .body(CreatePost(title: "hello"))
            .decoding(CreatedPost.self)

        _ = try await client.request(endpoint)

        let contentType = try #require(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.contains("application/json"))
    }

    @Test
    func contentTypeBuilderIsReflectedInRequestHeader() async throws {
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

        let endpoint = Endpoint.post("/login")
            .contentType(.formUrlEncoded)
            .body(Login(username: "test"))
            .decoding(LoginResponse.self)

        _ = try await client.request(endpoint)

        let contentType = try #require(mockSession.capturedRequest?.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.contains("application/x-www-form-urlencoded"))
    }

    @Test
    func headersBuilderReappliesEndpointContentType() {
        var headers = HTTPHeaders.default
        headers.add(name: "Content-Type", value: "text/plain")
        headers.add(name: "X-Custom", value: "kept")

        let endpoint = Endpoint.post("/posts")
            .headers(headers)

        #expect(endpoint.headers.value(for: "Content-Type") == "application/json; charset=UTF-8")
        #expect(endpoint.headers.value(for: "X-Custom") == "kept")
    }
}
