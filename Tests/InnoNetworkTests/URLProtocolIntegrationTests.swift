import Foundation
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
                    "Content-Type": "application/octet-stream",
                ]
            )
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                responseBodyBufferingPolicy: .streaming()
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
            Issue.record("Expected NetworkError.responseTooLarge")
        } catch let error as NetworkError {
            switch error {
            case .responseTooLarge(let limit, let observed):
                #expect(limit == 1_024)
                #expect(observed == Int64(payload.count))
            default:
                Issue.record("Expected NetworkError.responseTooLarge, got \(error)")
            }
        }
    }
}

private struct RedirectMessage: Decodable, Sendable {
    let message: String
}

private struct RedirectEndpoint: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = RedirectMessage

    let path: String
    var method: HTTPMethod { .get }
}

private struct HeaderEchoEndpoint: APIDefinition {
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
    typealias Parameter = EmptyParameter
    typealias APIResponse = Data

    let path: String
    var method: HTTPMethod { .get }

    var transport: TransportPolicy<Data> {
        .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
    }
}

private func makeStubURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
}

/// URLProtocol stub that scripts a single response per absolute URL,
/// supporting both 2xx success bodies and 3xx redirects with a
/// `Location` header. Captures the URLs of every request the URL
/// loader dispatches through the protocol so tests can assert on the
/// redirect chain.
private final class StubURLProtocol: URLProtocol {
    enum ResponseSpec: Sendable {
        case success(statusCode: Int, data: Data, headers: [String: String])
        case redirect(statusCode: Int, location: URL)
    }

    nonisolated(unsafe) private static var responses: [String: ResponseSpec] = [:]
    nonisolated(unsafe) private static var capturedStorage: [URLRequest] = []
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

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses.removeAll()
        capturedStorage.removeAll()
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
        Self.capturedStorage.append(request)
        let spec = Self.responses[url.absoluteString]
        Self.lock.unlock()

        switch spec {
        case .success(let statusCode, let data, let headers):
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
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
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
}
