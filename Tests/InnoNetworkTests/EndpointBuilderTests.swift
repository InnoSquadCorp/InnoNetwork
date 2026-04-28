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
}
