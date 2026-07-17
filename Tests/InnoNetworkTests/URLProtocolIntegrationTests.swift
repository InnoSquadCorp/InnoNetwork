import Foundation
import Network
import Testing

@testable import InnoNetwork

/// End-to-end integration tests that wire `DefaultNetworkClient` to a
/// real `URLSession` configured with a `URLProtocol` stub. The stub
/// scripts the wire-level response shape (status code, headers, body,
/// redirects) so we can exercise URLSession behavior — automatic
/// redirect following, conditional revalidation, header propagation
/// — that pure mock sessions cannot reproduce.
@Suite("URLProtocol Stub Integration Tests", .serialized)
struct URLProtocolIntegrationTests {

    init() {
        StubURLProtocol.reset()
    }

    @Test("Three-hop 302 redirect chain resolves to the final 200 payload")
    func threeHopRedirectChain() async throws {
        let baseURL = URL(string: "https://redirect-\(UUID().uuidString).example.com")!
        let hopOne = baseURL.appendingPathComponent("/a")
        let hopTwo = baseURL.appendingPathComponent("/b")
        let hopThree = baseURL.appendingPathComponent("/c")
        let final = baseURL.appendingPathComponent("/final")

        StubURLProtocol.register(
            url: hopOne,
            response: .redirect(statusCode: 302, location: hopTwo)
        )
        StubURLProtocol.register(
            url: hopTwo,
            response: .redirect(statusCode: 302, location: hopThree)
        )
        StubURLProtocol.register(
            url: hopThree,
            response: .redirect(statusCode: 302, location: final)
        )
        StubURLProtocol.register(
            url: final,
            response: .success(
                statusCode: 200,
                data: Data(#"{"message":"redirected"}"#.utf8),
                headers: ["Content-Type": "application/json"]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL),
            session: makeStubURLSession()
        )

        let response = try await client.request(RedirectEndpoint(path: "/a"))
        #expect(response.message == "redirected")

        let captured = StubURLProtocol.capturedRequestURLs()
        #expect(captured.contains(hopOne))
        #expect(captured.contains(hopTwo))
        #expect(captured.contains(hopThree))
        #expect(captured.contains(final))
    }

    @Test("Custom request header is propagated through URLProtocol to the server stub")
    func customHeaderPropagatedToServerStub() async throws {
        let baseURL = URL(string: "https://hdr-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/echo")
        StubURLProtocol.register(
            url: target,
            response: .success(
                statusCode: 200,
                data: Data(#"{"message":"ok"}"#.utf8),
                headers: ["Content-Type": "application/json"]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL),
            session: makeStubURLSession()
        )

        _ = try await client.request(HeaderEchoEndpoint(path: "/echo"))

        let captured = StubURLProtocol.capturedRequests()
        #expect(captured.count == 1)
        #expect(captured.first?.value(forHTTPHeaderField: "X-Test-Marker") == "marker-value")
    }

    @Test("Cross-origin redirects clear URLSession additional header values")
    func crossOriginRedirectClearsSessionHeaderValues() async throws {
        let baseURL = URL(string: "https://session-header-source-\(UUID().uuidString).example.com")!
        let source = baseURL.appendingPathComponent("/source")
        let target = URL(
            string: "https://session-header-target-\(UUID().uuidString).example.net/final"
        )!
        StubURLProtocol.register(
            url: source,
            response: .redirect(statusCode: 302, location: target)
        )
        StubURLProtocol.register(
            url: target,
            response: .success(
                statusCode: 200,
                data: Data(#"{"message":"redirected"}"#.utf8),
                headers: ["Content-Type": "application/json"]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL),
            session: makeStubURLSession(
                additionalHeaders: ["X-Session-Secret": "session-secret"]
            )
        )

        let response = try await client.request(RedirectEndpoint(path: "/source"))

        #expect(response.message == "redirected")
        let sourceRequest = try #require(
            StubURLProtocol.capturedRequests().first { $0.url == source }
        )
        let targetRequest = try #require(
            StubURLProtocol.capturedRequests().first { $0.url == target }
        )
        #expect(sourceRequest.value(forHTTPHeaderField: "X-Session-Secret") == "session-secret")
        #expect(targetRequest.value(forHTTPHeaderField: "X-Session-Secret") == "")
    }

    @Test("Same-origin redirects preserve URLSession additional header values")
    func sameOriginRedirectPreservesSessionHeaderValues() async throws {
        let baseURL = URL(string: "https://session-header-same-\(UUID().uuidString).example.com")!
        let source = baseURL.appendingPathComponent("/source")
        let target = baseURL.appendingPathComponent("/final")
        StubURLProtocol.register(
            url: source,
            response: .redirect(statusCode: 302, location: target)
        )
        StubURLProtocol.register(
            url: target,
            response: .success(
                statusCode: 200,
                data: Data(#"{"message":"redirected"}"#.utf8),
                headers: ["Content-Type": "application/json"]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL),
            session: makeStubURLSession(
                additionalHeaders: ["X-Session-Default": "session-default"]
            )
        )

        let response = try await client.request(RedirectEndpoint(path: "/source"))

        #expect(response.message == "redirected")
        let targetRequest = try #require(
            StubURLProtocol.capturedRequests().first { $0.url == target }
        )
        #expect(targetRequest.value(forHTTPHeaderField: "X-Session-Default") == "session-default")
    }

    // The two streaming-buffering tests below stay at the URLProtocol
    // integration level because `URLSession.AsyncBytes` is not externally
    // constructible — `MockURLSession.bytes(for:)` cannot synthesise a
    // value of that type without going through a real URLSession. A
    // future refactor that abstracts `URLSessionProtocol.bytes(for:)`
    // over a generic `AsyncSequence<UInt8, Error>` would let these
    // assertions move into `MockURLSession`.

    @Test("Streaming body buffering collects a 5 MiB response")
    func streamingBodyBufferingCollectsLargeResponse() async throws {
        let baseURL = URL(string: "https://large-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/large")
        let payload = Data(repeating: 0xA5, count: 5 * 1_024 * 1_024)
        StubURLProtocol.register(
            url: target,
            response: .success(
                statusCode: 200,
                data: payload,
                headers: [
                    "Content-Type": "application/octet-stream"
                ]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                responseBodyBufferingPolicy: .streaming(maxBytes: nil)
            ),
            session: makeStubURLSession()
        )

        let response = try await client.request(BinaryEndpoint(path: "/large"))
        #expect(response == payload)
    }

    @Test("Streaming body buffering rejects known 5 MiB responses above maxBytes")
    func streamingBodyBufferingRejectsKnownOversizedResponse() async throws {
        let baseURL = URL(string: "https://large-limit-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/large")
        let payload = Data(repeating: 0x5A, count: 5 * 1_024 * 1_024)
        StubURLProtocol.register(
            url: target,
            response: .success(
                statusCode: 200,
                data: payload,
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Content-Length": "\(payload.count)",
                ]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                responseBodyBufferingPolicy: .streaming(maxBytes: 1_024)
            ),
            session: makeStubURLSession()
        )

        do {
            _ = try await client.request(BinaryEndpoint(path: "/large"))
            Issue.record("Expected response-too-large NetworkError.underlying")
        } catch let error as NetworkError {
            switch error {
            case .underlying(let underlying, _)
            where underlying.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue:
                #expect(underlying.message.contains("1024"))
                #expect(underlying.message.contains("\(payload.count)"))
            default:
                Issue.record("Expected NetworkError.underlying with responseBodyLimitExceeded code, got \(error)")
            }
        }
    }

    @Test("HEAD accepts oversized representation metadata when no body arrives")
    func headSkipsOversizedContentLengthPreflight() async throws {
        let baseURL = URL(string: "https://head-metadata-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/metadata")
        StubURLProtocol.register(
            url: target,
            response: .success(
                statusCode: 200,
                data: Data(),
                headers: ["Content-Length": "9223372036854775807"]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                responseBodyBufferingPolicy: .streaming(maxBytes: 1)
            ),
            session: makeStubURLSession()
        )

        let response = try await client.request(
            BinaryEndpoint(path: "/metadata", method: .head)
        )
        #expect(response.isEmpty)
    }

    @Test("No-body preflight uses the method rewritten by redirect policy")
    func redirectedHeadSkipsOversizedContentLengthPreflight() async throws {
        let baseURL = URL(string: "https://redirect-head-\(UUID().uuidString).example.com")!
        let initial = baseURL.appendingPathComponent("/initial")
        let target = baseURL.appendingPathComponent("/metadata")
        StubURLProtocol.register(
            url: initial,
            response: .redirect(statusCode: 302, location: target)
        )
        StubURLProtocol.register(
            url: target,
            response: .success(
                statusCode: 200,
                data: Data(),
                headers: ["Content-Length": "9223372036854775807"]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                responseBodyBufferingPolicy: .streaming(maxBytes: 1),
                redirectPolicy: RewriteRedirectMethodPolicy(method: "HEAD")
            ),
            session: makeStubURLSession()
        )

        let response = try await client.request(
            BinaryEndpoint(path: "/initial", method: .get)
        )
        #expect(response.isEmpty)
        #expect(StubURLProtocol.capturedRequests().last?.httpMethod == "HEAD")
    }

    @Test("Successful CONNECT no-body preflight uses the redirect-rewritten method")
    func redirectedConnectSkipsOversizedContentLengthPreflight() async throws {
        let baseURL = URL(string: "https://redirect-connect-\(UUID().uuidString).example.com")!
        let initial = baseURL.appendingPathComponent("/initial")
        let target = baseURL.appendingPathComponent("/tunnel")
        StubURLProtocol.register(
            url: initial,
            response: .redirect(statusCode: 302, location: target)
        )
        StubURLProtocol.register(
            url: target,
            response: .success(
                statusCode: 200,
                data: Data(),
                headers: ["Content-Length": "9223372036854775807"]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                responseBodyBufferingPolicy: .streaming(maxBytes: 1),
                redirectPolicy: RewriteRedirectMethodPolicy(method: "CONNECT")
            ),
            session: makeStubURLSession()
        )

        let response = try await client.request(
            BinaryEndpoint(path: "/initial", method: .get)
        )
        #expect(response.isEmpty)
        #expect(StubURLProtocol.capturedRequests().last?.httpMethod == "CONNECT")
    }

    @Test("Unknown-length streamed bytes remain bounded after metadata preflight changes")
    func unknownLengthInlineResponseStillEnforcesStreamedLimit() async throws {
        let baseURL = URL(string: "https://inline-unknown-over-limit-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/large")
        let limit: Int64 = 1_024
        let payload = Data(repeating: 0x5B, count: Int(limit + 1))
        StubURLProtocol.register(
            url: target,
            response: .unfinished(
                statusCode: 200,
                data: payload,
                headers: ["Content-Type": "application/octet-stream"]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                responseBodyBufferingPolicy: .streaming(maxBytes: limit)
            ),
            session: makeStubURLSession()
        )

        await expectResponseBodyLimit(limit: limit, observed: limit + 1) {
            _ = try await client.request(BinaryEndpoint(path: "/large"))
        }
        #expect(await waitForURLProtocolStopLoading(target))
    }

    @Test("Bounded file upload allows a response exactly at the known Content-Length limit")
    func boundedFileUploadAllowsKnownResponseAtLimit() async throws {
        let baseURL = URL(string: "https://upload-known-at-limit-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/upload")
        let limit: Int64 = 1_024
        let payload = Data(repeating: 0xA1, count: Int(limit))
        StubURLProtocol.register(
            url: target,
            response: .success(
                statusCode: 200,
                data: payload,
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Content-Length": "\(payload.count)",
                ]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                responseBodyBufferingPolicy: .streaming(maxBytes: limit)
            ),
            session: makeStubURLSession()
        )

        let response = try await client.upload(StreamingUploadEndpoint(path: "/upload"))
        #expect(response == payload)
        let capturedRequest = try #require(StubURLProtocol.capturedRequests().first)
        #expect(capturedRequest.httpMethod == HTTPMethod.post.rawValue)
        #expect(capturedRequest.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
        #expect(capturedRequest.httpBodyStream != nil)
    }

    @Test("Bounded file upload rejects a mismatched signed Content-Length before transport")
    func boundedFileUploadRejectsMismatchedSignedContentLength() async throws {
        let baseURL = URL(string: "https://upload-framing-length-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/upload")
        StubURLProtocol.register(
            url: target,
            response: .success(statusCode: 200, data: Data("unused".utf8), headers: [:])
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                requestSigners: [UploadFramingSigner(headers: ["Content-Length": "1"])],
                responseBodyBufferingPolicy: .streaming(maxBytes: 1_024)
            ),
            session: makeStubURLSession()
        )

        await expectUploadFramingFailure(containing: "Content-Length") {
            _ = try await client.upload(StreamingUploadEndpoint(path: "/upload"))
        }
        #expect(StubURLProtocol.capturedRequests().isEmpty)
    }

    @Test("Bounded file upload rejects non-ABNF signed Content-Length before transport")
    func boundedFileUploadRejectsNonDecimalSignedContentLength() async throws {
        let baseURL = URL(string: "https://upload-framing-abnf-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/upload")
        let endpoint = StreamingUploadEndpoint(path: "/upload")
        let exactSize = try endpoint.multipartFormData.encode().count
        StubURLProtocol.register(
            url: target,
            response: .success(statusCode: 200, data: Data("unused".utf8), headers: [:])
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                requestSigners: [
                    UploadFramingSigner(headers: ["Content-Length": "+\(exactSize)"])
                ],
                responseBodyBufferingPolicy: .streaming(maxBytes: 1_024)
            ),
            session: makeStubURLSession()
        )

        await expectUploadFramingFailure(containing: "Content-Length") {
            _ = try await client.upload(endpoint)
        }
        #expect(StubURLProtocol.capturedRequests().isEmpty)
    }

    @Test("Bounded file upload rejects signed Transfer-Encoding before transport")
    func boundedFileUploadRejectsSignedTransferEncoding() async throws {
        let baseURL = URL(string: "https://upload-framing-transfer-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/upload")
        StubURLProtocol.register(
            url: target,
            response: .success(statusCode: 200, data: Data("unused".utf8), headers: [:])
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                requestSigners: [UploadFramingSigner(headers: ["Transfer-Encoding": "chunked"])],
                responseBodyBufferingPolicy: .streaming(maxBytes: 1_024)
            ),
            session: makeStubURLSession()
        )

        await expectUploadFramingFailure(containing: "Transfer-Encoding") {
            _ = try await client.upload(StreamingUploadEndpoint(path: "/upload"))
        }
        #expect(StubURLProtocol.capturedRequests().isEmpty)
    }

    @Test("Bounded file upload accepts an exact signed Content-Length")
    func boundedFileUploadAcceptsExactSignedContentLength() async throws {
        let baseURL = URL(string: "https://upload-framing-exact-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/upload")
        let endpoint = StreamingUploadEndpoint(path: "/upload")
        let expectedBody = try endpoint.multipartFormData.encode()
        StubURLProtocol.register(
            url: target,
            response: .success(statusCode: 200, data: Data("ok".utf8), headers: [:])
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                requestSigners: [
                    UploadFramingSigner(
                        headers: ["Content-Length": String(expectedBody.count)]
                    )
                ],
                responseBodyBufferingPolicy: .streaming(maxBytes: 1_024)
            ),
            session: makeStubURLSession()
        )

        let response = try await client.upload(endpoint)

        #expect(response == Data("ok".utf8))
        let capturedRequest = try #require(StubURLProtocol.capturedRequests().first)
        #expect(
            capturedRequest.value(forHTTPHeaderField: "Content-Length")
                == String(expectedBody.count)
        )
        #expect(StubURLProtocol.capturedBodies(for: target) == [expectedBody])
    }

    @Test("Bounded file upload rejects a known Content-Length above the limit")
    func boundedFileUploadRejectsKnownResponseAboveLimit() async throws {
        let baseURL = URL(string: "https://upload-known-over-limit-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/upload")
        let limit: Int64 = 1_024
        let payload = Data(repeating: 0xA2, count: Int(limit + 1))
        StubURLProtocol.register(
            url: target,
            response: .unfinished(
                statusCode: 200,
                data: payload,
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Content-Length": "\(payload.count)",
                ]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                responseBodyBufferingPolicy: .streaming(maxBytes: limit)
            ),
            session: makeStubURLSession()
        )

        await expectResponseBodyLimit(limit: limit, observed: Int64(payload.count)) {
            _ = try await client.upload(StreamingUploadEndpoint(path: "/upload"))
        }
        #expect(await waitForURLProtocolStopLoading(target))
    }

    @Test("Bounded file upload rejects an unknown-length response at limit plus one")
    func boundedFileUploadRejectsUnknownResponseAtLimitPlusOne() async throws {
        let baseURL = URL(string: "https://upload-unknown-over-limit-\(UUID().uuidString).example.com")!
        let target = baseURL.appendingPathComponent("/upload")
        let limit: Int64 = 1_024
        let payload = Data(repeating: 0xA3, count: Int(limit + 1))
        StubURLProtocol.register(
            url: target,
            response: .unfinished(
                statusCode: 200,
                data: payload,
                headers: ["Content-Type": "application/octet-stream"]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                responseBodyBufferingPolicy: .streaming(maxBytes: limit)
            ),
            session: makeStubURLSession()
        )

        await expectResponseBodyLimit(limit: limit, observed: limit + 1) {
            _ = try await client.upload(StreamingUploadEndpoint(path: "/upload"))
        }
        #expect(await waitForURLProtocolStopLoading(target))
        #expect(StubURLProtocol.deliveredExpectedContentLength(for: target) == -1)
    }

    @Test("Bounded file upload preserves a same-origin 307 replay")
    func boundedFileUploadPreservesSameOriginRedirectReplay() async throws {
        let server = try RedirectReplayHTTPServer()
        defer { server.stop() }

        let endpoint = StreamingUploadEndpoint(path: "/upload")
        let expectedRequestBody = try endpoint.multipartFormData.encode()
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: server.baseURL,
                responseBodyBufferingPolicy: .streaming(maxBytes: 1_024),
                allowsInsecureHTTP: true
            ),
            session: URLSession(configuration: .ephemeral)
        )

        let response = try await client.upload(endpoint)
        #expect(response == Data("accepted".utf8))
        let captured = server.capturedRequests()
        #expect(captured.map(\.path) == ["/upload", "/accepted"])
        #expect(captured.map(\.method) == [HTTPMethod.post.rawValue, HTTPMethod.post.rawValue])
        #expect(captured.map(\.body) == [expectedRequestBody, expectedRequestBody])
        #expect(
            captured.map { $0.headers["content-length"] } == Array(repeating: "\(expectedRequestBody.count)", count: 2))
        #expect(captured.allSatisfy { $0.headers["transfer-encoding"] == nil })
    }

    @Test("Custom redirect target is re-admitted and surfaces a typed failure")
    func customRedirectTargetIsReadmitted() async throws {
        let baseURL = URL(string: "https://redirect-admission-\(UUID().uuidString).example.com")!
        let source = baseURL.appendingPathComponent("/source")
        let target = URL(string: "https://user:password@target.example.com/private")!
        StubURLProtocol.register(
            url: source,
            response: .redirect(statusCode: 302, location: target)
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                redirectPolicy: PassThroughRedirectPolicy()
            ),
            session: makeStubURLSession()
        )

        await expectRedirectAdmissionFailure {
            _ = try await client.request(RedirectEndpoint(path: "/source"))
        }

        let captured = StubURLProtocol.capturedRequestURLs()
        #expect(captured.contains(source))
        #expect(!captured.contains(target))
    }

    @Test("Global HTTP admission rejects downgrade even when redirect policy allows it")
    func globalAdmissionRejectsPolicyAllowedDowngrade() async throws {
        let baseURL = URL(string: "https://redirect-downgrade-\(UUID().uuidString).example.com")!
        let source = baseURL.appendingPathComponent("/source")
        let target = URL(string: "http://redirect-target-\(UUID().uuidString).example.com/final")!
        StubURLProtocol.register(
            url: source,
            response: .redirect(statusCode: 302, location: target)
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                redirectPolicy: DefaultRedirectPolicy(allowsHTTPSDowngrade: true)
            ),
            session: makeStubURLSession()
        )

        await expectRedirectAdmissionFailure {
            _ = try await client.request(RedirectEndpoint(path: "/source"))
        }

        let captured = StubURLProtocol.capturedRequestURLs()
        #expect(captured.contains(source))
        #expect(!captured.contains(target))
    }

    @Test("Explicit insecure-HTTP opt-in is preserved through redirect context")
    func explicitInsecureHTTPOptInAllowsPolicyApprovedDowngrade() async throws {
        let baseURL = URL(string: "https://redirect-http-opt-in-\(UUID().uuidString).example.com")!
        let source = baseURL.appendingPathComponent("/source")
        let target = URL(string: "http://redirect-http-target-\(UUID().uuidString).example.com/final")!
        StubURLProtocol.register(
            url: source,
            response: .redirect(statusCode: 302, location: target)
        )
        StubURLProtocol.register(
            url: target,
            response: .success(
                statusCode: 200,
                data: Data(#"{"message":"redirected-over-opted-in-http"}"#.utf8),
                headers: ["Content-Type": "application/json"]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                redirectPolicy: DefaultRedirectPolicy(allowsHTTPSDowngrade: true),
                allowsInsecureHTTP: true
            ),
            session: makeStubURLSession()
        )

        let response = try await client.request(RedirectEndpoint(path: "/source"))

        #expect(response.message == "redirected-over-opted-in-http")
        let captured = StubURLProtocol.capturedRequestURLs()
        #expect(captured.contains(source))
        #expect(captured.contains(target))
    }
}


private struct PassThroughRedirectPolicy: RedirectPolicy {
    func redirect(
        request: URLRequest,
        response: HTTPURLResponse,
        originalRequest: URLRequest
    ) -> URLRequest? {
        _ = (response, originalRequest)
        return request
    }
}


private struct RewriteRedirectMethodPolicy: RedirectPolicy {
    let method: String

    func redirect(
        request: URLRequest,
        response: HTTPURLResponse,
        originalRequest: URLRequest
    ) -> URLRequest? {
        _ = (response, originalRequest)
        var rewritten = request
        rewritten.httpMethod = method
        return rewritten
    }
}


private func expectRedirectAdmissionFailure(
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected redirect URL admission to fail")
    } catch let error as NetworkError {
        guard case .configuration(let reason) = error else {
            Issue.record("Expected NetworkError.configuration, got \(error)")
            return
        }
        switch reason {
        case .invalidBaseURL, .invalidRequest:
            break
        case .offline:
            Issue.record("Expected redirect URL admission failure, got \(reason)")
        }
    } catch {
        Issue.record("Expected NetworkError.configuration, got \(error)")
    }
}

private func expectResponseBodyLimit(
    limit: Int64,
    observed: Int64,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected response-too-large NetworkError.underlying")
    } catch let error as NetworkError {
        guard case .underlying(let underlying, _) = error,
            underlying.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue
        else {
            Issue.record("Expected responseBodyLimitExceeded, got \(error)")
            return
        }
        #expect(underlying.message.contains("\(observed)"))
        #expect(underlying.message.contains("\(limit)"))
    } catch {
        Issue.record("Expected NetworkError.underlying, got \(error)")
    }
}

private func expectUploadFramingFailure(
    containing expectedMessageFragment: String,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected invalid file-upload framing configuration")
    } catch let error as NetworkError {
        guard case .configuration(reason: .invalidRequest(let message)) = error else {
            Issue.record("Expected invalid-request configuration, got \(error)")
            return
        }
        #expect(message.contains(expectedMessageFragment))
    } catch {
        Issue.record("Expected NetworkError.configuration, got \(error)")
    }
}

private struct RedirectMessage: Decodable, Sendable {
    let message: String
}

private struct RedirectEndpoint: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias Parameter = EmptyParameter
    typealias APIResponse = RedirectMessage

    let path: String
    var method: HTTPMethod { .get }
}

private struct HeaderEchoEndpoint: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias Parameter = EmptyParameter
    typealias APIResponse = RedirectMessage

    let path: String
    var method: HTTPMethod { .get }
    var headers: HTTPHeaders {
        var headers = HTTPHeaders.default
        headers.add(HTTPHeader(name: "X-Test-Marker", value: "marker-value"))
        return headers
    }
}

private struct BinaryEndpoint: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias Parameter = EmptyParameter
    typealias APIResponse = Data

    let path: String
    let method: HTTPMethod

    init(path: String, method: HTTPMethod = .get) {
        self.path = path
        self.method = method
    }

    var transport: TransportPolicy<Data> {
        .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
    }
}

private struct StreamingUploadEndpoint: MultipartAPIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias APIResponse = Data

    let path: String
    var method: HTTPMethod { .post }
    var uploadStrategy: MultipartUploadStrategy { .alwaysStream }
    var multipartFormData: MultipartFormData {
        var formData = MultipartFormData(boundary: "bounded-upload-test")
        formData.append("body", name: "value")
        return formData
    }

    var transport: TransportPolicy<Data> {
        .custom(encoding: .none) { data, _ in data }
    }
}

private struct UploadFramingSigner: RequestSigner {
    let headers: HTTPHeaders

    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        _ = (request, body)
        return headers
    }
}

private func makeStubURLSession(
    additionalHeaders: [String: String] = [:]
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpAdditionalHeaders = additionalHeaders
    return URLSession(configuration: configuration)
}

private func waitForURLProtocolStopLoading(_ url: URL) async -> Bool {
    for _ in 0..<100 {
        if StubURLProtocol.stopLoadingCount(for: url) > 0 {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return StubURLProtocol.stopLoadingCount(for: url) > 0
}

private struct CapturedHTTPRequest: Sendable, Equatable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

/// Minimal loopback server used where URLProtocol cannot faithfully model
/// URLSession's streamed-body replay. It accepts exactly the two requests in
/// a same-origin 307 exchange and records their decoded wire bodies.
private final class RedirectReplayHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "innonetwork.redirect-replay-http-server")
    private var requests: [CapturedHTTPRequest] = []
    private var portValue: UInt16 = 0

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(portValue)")!
    }

    init() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success,
            let port = listener.port
        else {
            throw URLError(.cannotConnectToHost)
        }
        portValue = port.rawValue
    }

    func stop() {
        listener.cancel()
    }

    func capturedRequests() -> [CapturedHTTPRequest] {
        queue.sync { requests }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var accumulated = accumulated
            if let data {
                accumulated.append(data)
            }
            if let request = Self.parseRequest(accumulated) {
                requests.append(request)
                respond(to: request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, accumulated: accumulated)
            }
        }
    }

    private func respond(to request: CapturedHTTPRequest, on connection: NWConnection) {
        let response: Data
        switch request.path {
        case "/upload":
            response = Data(
                ("HTTP/1.1 307 Temporary Redirect\r\n"
                    + "Location: \(baseURL.appendingPathComponent("accepted").absoluteString)\r\n"
                    + "Content-Length: 0\r\n"
                    + "Connection: close\r\n"
                    + "\r\n").utf8
            )
        case "/accepted":
            response = Data(
                ("HTTP/1.1 200 OK\r\n"
                    + "Content-Type: application/octet-stream\r\n"
                    + "Content-Length: 8\r\n"
                    + "Connection: close\r\n"
                    + "\r\n"
                    + "accepted").utf8
            )
        default:
            response = Data(
                ("HTTP/1.1 404 Not Found\r\n"
                    + "Content-Length: 0\r\n"
                    + "Connection: close\r\n"
                    + "\r\n").utf8
            )
        }
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private static func parseRequest(_ data: Data) -> CapturedHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
            let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else {
            return nil
        }

        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let wireBody = Data(data[headerRange.upperBound...])
        let body: Data
        if let contentLength = headers["content-length"].flatMap(Int.init) {
            guard wireBody.count >= contentLength else { return nil }
            body = Data(wireBody.prefix(contentLength))
        } else if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = decodeChunkedBody(wireBody) else { return nil }
            body = decoded
        } else {
            body = Data()
        }

        return CapturedHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        let lineSeparator = Data("\r\n".utf8)
        var cursor = data.startIndex
        var decoded = Data()

        while true {
            guard let lineRange = data.range(of: lineSeparator, in: cursor..<data.endIndex),
                let sizeLine = String(data: data[cursor..<lineRange.lowerBound], encoding: .ascii),
                let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first,
                let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16)
            else {
                return nil
            }
            cursor = lineRange.upperBound

            if size == 0 {
                guard data.distance(from: cursor, to: data.endIndex) >= lineSeparator.count else {
                    return nil
                }
                return decoded
            }

            guard data.distance(from: cursor, to: data.endIndex) >= size + lineSeparator.count else {
                return nil
            }
            let chunkEnd = data.index(cursor, offsetBy: size)
            decoded.append(contentsOf: data[cursor..<chunkEnd])
            guard data[chunkEnd..<data.index(chunkEnd, offsetBy: lineSeparator.count)] == lineSeparator else {
                return nil
            }
            cursor = data.index(chunkEnd, offsetBy: lineSeparator.count)
        }
    }
}

/// URLProtocol stub that scripts a single response per absolute URL,
/// supporting both 2xx success bodies and 3xx redirects with a
/// `Location` header. Captures the URLs of every request the URL
/// loader dispatches through the protocol so tests can assert on the
/// redirect chain.
private final class StubURLProtocol: URLProtocol {
    enum ResponseSpec: Sendable {
        case success(statusCode: Int, data: Data, headers: [String: String])
        /// Sends headers and the scripted bytes but deliberately never emits
        /// `urlProtocolDidFinishLoading`. The client must cancel the task to
        /// make `stopLoading()` observable.
        case unfinished(statusCode: Int, data: Data, headers: [String: String])
        case redirect(statusCode: Int, location: URL)
    }

    nonisolated(unsafe) private static var responses: [String: ResponseSpec] = [:]
    nonisolated(unsafe) private static var capturedStorage: [URLRequest] = []
    nonisolated(unsafe) private static var capturedBodyStorage: [String: [Data]] = [:]
    nonisolated(unsafe) private static var deliveredExpectedContentLengths: [String: Int64] = [:]
    nonisolated(unsafe) private static var stopLoadingCounts: [String: Int] = [:]
    private static let lock = NSLock()

    static func register(url: URL, response: ResponseSpec) {
        lock.lock()
        responses[url.absoluteString] = response
        lock.unlock()
    }

    static func capturedRequestURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return capturedStorage.compactMap(\.url)
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedStorage
    }

    static func capturedBodies(for url: URL) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodyStorage[url.absoluteString, default: []]
    }

    static func deliveredExpectedContentLength(for url: URL) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return deliveredExpectedContentLengths[url.absoluteString]
    }

    static func stopLoadingCount(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stopLoadingCounts[url.absoluteString, default: 0]
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses.removeAll()
        capturedStorage.removeAll()
        capturedBodyStorage.removeAll()
        deliveredExpectedContentLengths.removeAll()
        stopLoadingCounts.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.stopLoadingCounts[url.absoluteString, default: 0] += 1
        Self.lock.unlock()
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body = Self.readBody(from: request)
        Self.lock.lock()
        Self.capturedStorage.append(request)
        if let body {
            Self.capturedBodyStorage[url.absoluteString, default: []].append(body)
        }
        let spec = Self.responses[url.absoluteString]
        Self.lock.unlock()

        switch spec {
        case .success(let statusCode, let data, let headers),
            .unfinished(let statusCode, let data, let headers):
            guard
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            Self.lock.lock()
            Self.deliveredExpectedContentLengths[url.absoluteString] = response.expectedContentLength
            Self.lock.unlock()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            if case .success = spec {
                client?.urlProtocolDidFinishLoading(self)
            }
        case .redirect(let statusCode, let location):
            guard
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": location.absoluteString]
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            var nextRequest = URLRequest(url: location)
            nextRequest.httpMethod = request.httpMethod
            client?.urlProtocol(
                self,
                wasRedirectedTo: nextRequest,
                redirectResponse: response
            )
            // Per URLProtocol contract, terminate this load after emitting
            // the redirect; URLSession dispatches a new request for the
            // target URL through the same protocol class.
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        case .none:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                body.append(buffer, count: count)
            } else {
                break
            }
        }
        return body
    }
}
