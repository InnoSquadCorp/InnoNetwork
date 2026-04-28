import Foundation
import Testing

@testable import InnoNetwork

@Suite("NetworkError Redaction Tests")
struct NetworkErrorRedactionTests {

    private struct UserOnlyResponse: Decodable, Sendable {
        let id: Int
    }

    private struct GetUser: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = UserOnlyResponse
        var method: HTTPMethod { .get }
        var path: String { "/users/1" }
    }

    // The decoder fails on this body so the executor produces
    // NetworkError.objectMapping(_, response). The body deliberately resembles
    // PII so the redaction expectation is meaningful — if it leaked, it would
    // show up in error logs.
    private static let pii = "{\"email\":\"alice@example.com\",\"ssn\":\"123-45-6789\"}"

    @Test("Default config redacts NetworkError.objectMapping payload bytes")
    func defaultRedactsObjectMapping() async {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data(Self.pii.utf8))

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        do {
            _ = try await client.request(GetUser())
            Issue.record("Expected NetworkError.objectMapping")
        } catch let error as NetworkError {
            switch error {
            case .objectMapping(_, let response):
                #expect(response.data.isEmpty, "Failure payload must be redacted by default")
                // Status, headers, and request must remain intact.
                #expect(response.statusCode == 200)
                #expect(response.response != nil)
            default:
                Issue.record("Expected .objectMapping, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("captureFailurePayload=true preserves NetworkError.objectMapping payload bytes")
    func captureKeepsPayload() async {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data(Self.pii.utf8))

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                captureFailurePayload: true
            ),
            session: mockSession
        )

        do {
            _ = try await client.request(GetUser())
            Issue.record("Expected NetworkError.objectMapping")
        } catch let error as NetworkError {
            switch error {
            case .objectMapping(_, let response):
                #expect(String(data: response.data, encoding: .utf8) == Self.pii)
            default:
                Issue.record("Expected .objectMapping, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("statusCode failure also redacts payload by default")
    func statusCodeIsRedacted() async {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(
            statusCode: 500,
            data: Data("{\"email\":\"leak@example.com\"}".utf8)
        )

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        do {
            _ = try await client.request(GetUser())
            Issue.record("Expected NetworkError.statusCode")
        } catch let error as NetworkError {
            switch error {
            case .statusCode(let response):
                #expect(response.data.isEmpty)
                #expect(response.statusCode == 500)
            default:
                Issue.record("Expected .statusCode, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("redactingFailurePayload() is idempotent and pure")
    func redactingIsIdempotent() {
        let url = URL(string: "https://example.com")!
        let httpResponse = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
        let response = Response(
            statusCode: 500,
            data: Data("payload".utf8),
            request: URLRequest(url: url),
            response: httpResponse
        )
        let original = NetworkError.statusCode(response)
        let redactedOnce = original.redactingFailurePayload()
        let redactedTwice = redactedOnce.redactingFailurePayload()

        switch (redactedOnce, redactedTwice) {
        case (.statusCode(let r1), .statusCode(let r2)):
            #expect(r1.data.isEmpty)
            #expect(r2.data.isEmpty)
            #expect(r1.statusCode == r2.statusCode)
        default:
            Issue.record("Expected .statusCode case to be preserved")
        }
    }

    @Test("Cases without an attached payload are unchanged by redaction")
    func nonPayloadCasesPassThrough() {
        let cases: [NetworkError] = [
            .invalidBaseURL("https://example.com"),
            .invalidRequestConfiguration("missing"),
            .cancelled,
            .undefined,
            .timeout(reason: .requestTimeout, underlying: nil),
        ]
        for original in cases {
            let redacted = original.redactingFailurePayload()
            // Equality on enum case identifier is enough — the cases above
            // carry no Response, so structural equality of associated values
            // is preserved.
            #expect("\(redacted)" == "\(original)", "Case \(original) should pass through redaction unchanged")
        }
    }
}
