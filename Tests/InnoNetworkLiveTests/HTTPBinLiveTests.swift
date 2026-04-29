import Foundation
import InnoNetwork
import Testing

@Suite("HTTPBin Live Tests")
struct HTTPBinLiveTests {

    private struct HTTPBinResponse: Decodable, Sendable {
        let url: String
    }

    private struct HTTPBinGet: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = HTTPBinResponse

        var method: HTTPMethod { .get }
        var path: String { "/get" }
    }

    @Test("httpbin /get returns 200 with the expected URL echoed back", .liveOnly)
    func httpbinGetEchoesURL() async throws {
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://httpbin.org")!)
        )

        let response = try await client.request(HTTPBinGet())
        #expect(response.url.contains("/get"))
    }

    private struct HTTPBinPostBody: Encodable, Sendable {
        let title: String
        let body: String
    }

    private struct HTTPBinJSONResponse: Decodable, Sendable {
        // httpbin's /post endpoint echoes the request body under "json"
        struct EchoedBody: Decodable, Sendable {
            let title: String
            let body: String
        }
        let json: EchoedBody
    }

    private struct HTTPBinPost: APIDefinition {
        typealias Parameter = HTTPBinPostBody
        typealias APIResponse = HTTPBinJSONResponse

        let parameters: HTTPBinPostBody?

        var method: HTTPMethod { .post }
        var path: String { "/post" }
    }

    @Test("httpbin /post round-trips a JSON body", .liveOnly)
    func httpbinPostRoundTripsJSON() async throws {
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://httpbin.org")!)
        )

        let body = HTTPBinPostBody(title: "InnoNetwork", body: "live smoke")
        let response = try await client.request(HTTPBinPost(parameters: body))

        #expect(response.json.title == body.title)
        #expect(response.json.body == body.body)
    }

    private struct HTTPBin503: APIDefinition, HTTPEmptyResponseDecodable {
        typealias Parameter = EmptyParameter
        typealias APIResponse = HTTPBin503

        var method: HTTPMethod { .get }
        var path: String { "/status/503" }

        // 503 is OUTSIDE the default 200..<300 set, so we expect the executor
        // to throw NetworkError.statusCode(_) — this verifies live status-code
        // mapping end-to-end without depending on a flaky retry path.
        static func emptyResponseValue() -> HTTPBin503 { HTTPBin503() }
    }

    @Test("httpbin /status/503 surfaces NetworkError.statusCode", .liveOnly)
    func httpbin503Throws503() async throws {
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://httpbin.org")!)
        )

        do {
            _ = try await client.request(HTTPBin503())
            Issue.record("Expected NetworkError.statusCode(503)")
        } catch let error as NetworkError {
            switch error {
            case .statusCode(let response):
                #expect(response.statusCode == 503)
            default:
                Issue.record("Expected .statusCode, got \(error)")
            }
        }
    }
}
