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

    private struct RedactionStream: StreamingAPIDefinition {
        typealias Output = String

        var method: HTTPMethod { .get }
        var path: String { "/stream" }

        func decode(line: String) throws -> String? {
            guard !line.isEmpty else { return nil }
            guard line != "malformed" else { throw StreamDecodeError(line: line) }
            return line
        }
    }

    private struct StreamDecodeError: LocalizedError {
        let line: String

        var errorDescription: String? {
            "Malformed redaction stream line: \(line)"
        }
    }

    private final class RedactionStreamingURLProtocol: URLProtocol {
        private struct Spec {
            let data: Data
            let headers: [String: String]
        }

        nonisolated(unsafe) private static var responses: [String: Spec] = [:]
        private static let lock = NSLock()

        static func register(url: URL, data: Data, headers: [String: String] = ["X-Trace": "kept"]) {
            lock.lock()
            defer { lock.unlock() }
            responses[url.absoluteString] = Spec(data: data, headers: headers)
        }

        static func reset() {
            lock.lock()
            defer { lock.unlock() }
            responses.removeAll()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            Self.lock.lock()
            let spec = Self.responses[url.absoluteString]
            Self.lock.unlock()

            guard let spec,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: spec.headers
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: spec.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    // The decoder fails on this body so the executor produces
    // NetworkError.decoding(stage: .responseBody, ...). The body deliberately
    // resembles PII so the redaction expectation is meaningful — if it leaked,
    // it would show up in error logs.
    private static let pii = "{\"email\":\"alice@example.com\",\"ssn\":\"123-45-6789\"}"
    private static let malformedFrame = "malformed"

    @Test("Default config redacts NetworkError.decoding payload bytes")
    func defaultRedactsDecoding() async {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data(Self.pii.utf8))

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        do {
            _ = try await client.request(GetUser())
            Issue.record("Expected NetworkError.decoding")
        } catch let error as NetworkError {
            switch error {
            case .decoding(let stage, _, let response):
                #expect(stage == .responseBody)
                #expect(response.data.isEmpty, "Failure payload must be redacted by default")
                // Status, headers, and request must remain intact.
                #expect(response.statusCode == 200)
                #expect(response.response != nil)
            default:
                Issue.record("Expected .decoding, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("captureFailurePayload=true preserves NetworkError.decoding payload bytes")
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
            Issue.record("Expected NetworkError.decoding")
        } catch let error as NetworkError {
            switch error {
            case .decoding(_, _, let response):
                #expect(String(data: response.data, encoding: .utf8) == Self.pii)
            default:
                Issue.record("Expected .decoding, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Default config redacts streamFrame decoding payload bytes")
    func defaultRedactsStreamFrameDecoding() async {
        await assertStreamFramePayload(captureFailurePayload: false, expectedPayload: Data())
    }

    @Test("captureFailurePayload=true preserves streamFrame decoding payload bytes")
    func captureKeepsStreamFramePayload() async {
        await assertStreamFramePayload(
            captureFailurePayload: true,
            expectedPayload: Data(Self.malformedFrame.utf8)
        )
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

    private func assertStreamFramePayload(captureFailurePayload: Bool, expectedPayload: Data) async {
        let baseURL = URL(string: "https://redaction-\(UUID().uuidString).example.com")!
        let definition = RedactionStream()
        let streamURL = baseURL.appendingPathComponent("stream")
        RedactionStreamingURLProtocol.register(
            url: streamURL,
            data: Data("ok\n\(Self.malformedFrame)\n".utf8)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedactionStreamingURLProtocol.self]
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                timeout: 5,
                captureFailurePayload: captureFailurePayload
            ),
            session: URLSession(configuration: configuration)
        )

        var collected: [String] = []
        do {
            for try await line in client.stream(definition) {
                collected.append(line)
            }
            Issue.record("Expected NetworkError.decoding(stage: .streamFrame)")
        } catch let error as NetworkError {
            switch error {
            case .decoding(let stage, _, let response):
                #expect(stage == .streamFrame)
                #expect(response.data == expectedPayload)
                #expect(response.statusCode == 200)
                #expect(response.response?.value(forHTTPHeaderField: "X-Trace") == "kept")
            default:
                Issue.record("Expected .decoding(stage: .streamFrame), got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(collected == ["ok"])
    }
}
