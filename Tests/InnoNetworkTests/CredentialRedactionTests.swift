import Foundation
import Testing
@testable import InnoNetwork

@Suite("URL credential redaction — userinfo never leaks to logs or errors")
struct CredentialRedactionTests {
    @Test("NetworkLogger sanitize strips user:password from URLs")
    func loggerStripsUserinfo() {
        let logger = DefaultNetworkLogger(options: .secureDefault)

        let url = URL(string: "https://alice:s3cret@api.example.com/v1/me?token=abc")!
        let sanitized = logger.sanitize(url: url)

        #expect(!sanitized.contains("alice"))
        #expect(!sanitized.contains("s3cret"))
        #expect(sanitized.contains("api.example.com"))
        #expect(sanitized.contains("token=%3Credacted%3E") || sanitized.contains("token=<redacted>"))
    }

    @Test("Response.redactingData strips userinfo from request URL")
    func responseRedactingDataStripsUserinfo() {
        let url = URL(string: "https://alice:secret@api.example.com/users/1")!
        var request = URLRequest(url: url)
        request.setValue("Bearer xyz", forHTTPHeaderField: "Authorization")

        let httpResponse = HTTPURLResponse(
            url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil
        )!

        let response = Response(
            statusCode: 500,
            data: Data("body".utf8),
            request: request,
            response: httpResponse
        )

        let redacted = response.redactingData()
        let resultURLString = redacted.request?.url?.absoluteString ?? ""

        #expect(!resultURLString.contains("alice"))
        #expect(!resultURLString.contains("secret"))
        #expect(resultURLString.contains("api.example.com"))
        #expect(redacted.data.isEmpty)
    }

    @Test("Base URL with userinfo is rejected by EndpointPathBuilder")
    func baseURLUserinfoRejected() {
        #expect(throws: NetworkError.self) {
            _ = try EndpointPathBuilder.makeURL(
                baseURL: URL(string: "https://alice:secret@api.example.com")!,
                endpointPath: "/users/1"
            )
        }
    }

    @Test("Base URL with fragment is rejected by EndpointPathBuilder")
    func baseURLFragmentRejected() {
        #expect(throws: NetworkError.self) {
            _ = try EndpointPathBuilder.makeURL(
                baseURL: URL(string: "https://api.example.com#section")!,
                endpointPath: "/users/1"
            )
        }
    }

    @Test("Base URL without userinfo or fragment passes through")
    func baseURLCleanAccepted() throws {
        let url = try EndpointPathBuilder.makeURL(
            baseURL: URL(string: "https://api.example.com")!,
            endpointPath: "/users/1"
        )
        #expect(url.absoluteString == "https://api.example.com/users/1")
    }
}
