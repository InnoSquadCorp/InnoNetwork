import Foundation
import HTTPTypes
import InnoNetworkOpenAPI
import OpenAPIRuntime
import Testing

@testable import InnoNetwork

private final class OpenAPIClientTransportURLProtocol: URLProtocol {
    enum ResponseSpec: Sendable {
        case http(statusCode: Int, headers: [String: String]?, chunks: [Data])
        case nonHTTP(data: Data)
    }

    nonisolated(unsafe) private static var responses: [String: ResponseSpec] = [:]
    private static let lock = NSLock()

    static func register(url: URL, response: ResponseSpec) {
        lock.lock()
        responses[url.absoluteString] = response
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        guard let response = Self.dequeue(url: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        switch response {
        case .http(let statusCode, let headers, let chunks):
            guard
                let httpResponse = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: headers
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        case .nonHTTP(let data):
            let response = URLResponse(
                url: url,
                mimeType: "application/octet-stream",
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func dequeue(url: URL) -> ResponseSpec? {
        lock.lock()
        defer { lock.unlock() }
        return responses.removeValue(forKey: url.absoluteString)
    }
}

private func makeOpenAPIClientTransportURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAPIClientTransportURLProtocol.self]
    return URLSession(configuration: configuration)
}

@Suite("InnoNetworkClientTransport")
struct InnoNetworkClientTransportTests {
    @Test("Constructs with default byte limits")
    func constructsWithDefaultByteLimits() {
        let transport = InnoNetworkClientTransport(session: URLSession(configuration: .ephemeral))

        #expect(transport.requestBodyByteLimit == 50 * 1024 * 1024)
        #expect(transport.responseBodyByteLimit == 50 * 1024 * 1024)
    }

    @Test("Custom byte limits are preserved")
    func customByteLimitsArePreserved() {
        let transport = InnoNetworkClientTransport(
            session: URLSession(configuration: .ephemeral),
            requestBodyByteLimit: 1024,
            responseBodyByteLimit: 2048
        )

        #expect(transport.requestBodyByteLimit == 1024)
        #expect(transport.responseBodyByteLimit == 2048)
    }

    @Test("Negative byte limits normalize to zero")
    func negativeByteLimitsNormalizeToZero() {
        let transport = InnoNetworkClientTransport(
            session: URLSession(configuration: .ephemeral),
            requestBodyByteLimit: -1,
            responseBodyByteLimit: -1
        )

        #expect(transport.requestBodyByteLimit == 0)
        #expect(transport.responseBodyByteLimit == 0)
    }

    @Test("Surfaces a typed error for an unresolvable request URL")
    func surfacesTypedErrorForUnresolvableURL() async throws {
        let transport = InnoNetworkClientTransport(session: URLSession(configuration: .ephemeral))
        let request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: nil)

        do {
            _ = try await transport.send(
                request,
                body: nil,
                baseURL: URL(string: "https://api.example.com")!,
                operationID: "test"
            )
            Issue.record("expected InnoNetworkClientTransportError.invalidRequestURL")
        } catch let error as InnoNetworkClientTransportError {
            guard case .invalidRequestURL = error else {
                Issue.record("expected .invalidRequestURL, got \(error)")
                return
            }
        }
    }

    @Test(
        "Rejects OpenAPI request targets that can override or traverse the configured origin",
        arguments: [
            "https://evil.example/users",
            "//evil.example/users",
            "/../admin",
            "/%2E%2E/admin",
            "/%25252525252E%25252525252E/admin",
            "/users#token=secret",
        ]
    )
    func rejectsOriginOverridesAndTraversal(path: String) async throws {
        let transport = InnoNetworkClientTransport(session: URLSession(configuration: .ephemeral))

        await #expect(throws: InnoNetworkClientTransportError.self) {
            _ = try await transport.send(
                HTTPRequest(method: .get, scheme: nil, authority: nil, path: path),
                body: nil,
                baseURL: URL(string: "https://api.example.com/v1")!,
                operationID: "rejected-target"
            )
        }
    }

    @Test("Combines the base path with a relative OpenAPI path and preserves query order")
    func combinesBasePathAndRelativeTarget() async throws {
        let baseURL = URL(string: "https://api.example.com/root")!
        let expectedURL = URL(string: "https://api.example.com/root/users?b=2&a=1")!
        OpenAPIClientTransportURLProtocol.register(
            url: expectedURL,
            response: .http(statusCode: 204, headers: nil, chunks: [])
        )
        let transport = InnoNetworkClientTransport(session: makeOpenAPIClientTransportURLSession())

        let (response, body) = try await transport.send(
            HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/users?b=2&a=1"),
            body: nil,
            baseURL: baseURL,
            operationID: "combined-target"
        )

        #expect(response.status.code == 204)
        #expect(body == nil)
    }

    @Test("Plain HTTP OpenAPI base URLs require explicit opt-in")
    func plainHTTPRequiresExplicitOptIn() async throws {
        let baseURL = URL(string: "http://127.0.0.1:8080")!
        let expectedURL = baseURL.appendingPathComponent("health")
        let request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/health")
        let defaultTransport = InnoNetworkClientTransport(session: URLSession(configuration: .ephemeral))

        await #expect(throws: InnoNetworkClientTransportError.self) {
            _ = try await defaultTransport.send(
                request,
                body: nil,
                baseURL: baseURL,
                operationID: "http-rejected"
            )
        }

        OpenAPIClientTransportURLProtocol.register(
            url: expectedURL,
            response: .http(statusCode: 204, headers: nil, chunks: [])
        )
        let optedInTransport = InnoNetworkClientTransport(
            session: makeOpenAPIClientTransportURLSession(),
            allowsInsecureHTTP: true
        )
        let (response, _) = try await optedInTransport.send(
            request,
            body: nil,
            baseURL: baseURL,
            operationID: "http-opted-in"
        )
        #expect(response.status.code == 204)
    }

    @Test("Streams response body through HTTPBody")
    func streamsResponseBodyThroughHTTPBody() async throws {
        let baseURL = URL(string: "https://api.example.com")!
        let streamURL = baseURL.appendingPathComponent("stream")
        OpenAPIClientTransportURLProtocol.register(
            url: streamURL,
            response: .http(
                statusCode: 200,
                headers: nil,
                chunks: [Data("hel".utf8), Data("lo".utf8)]
            )
        )
        let transport = InnoNetworkClientTransport(session: makeOpenAPIClientTransportURLSession())

        let (response, responseBody) = try await transport.send(
            HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/stream"),
            body: nil,
            baseURL: baseURL,
            operationID: "stream"
        )

        #expect(response.status.code == 200)
        let body = try #require(responseBody)
        let bytes = try await Array(collecting: body, upTo: 64)
        #expect(String(decoding: bytes, as: UTF8.self) == "hello")
    }

    @Test("Response byte limit can fail while generated client consumes streamed body")
    func responseByteLimitCanFailDuringBodyConsumption() async throws {
        let baseURL = URL(string: "https://api.example.com")!
        let streamURL = baseURL.appendingPathComponent("limited")
        OpenAPIClientTransportURLProtocol.register(
            url: streamURL,
            response: .http(
                statusCode: 200,
                headers: nil,
                chunks: [Data("1234".utf8)]
            )
        )
        let transport = InnoNetworkClientTransport(
            session: makeOpenAPIClientTransportURLSession(),
            responseBodyByteLimit: 3
        )

        let (_, responseBody) = try await transport.send(
            HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/limited"),
            body: nil,
            baseURL: baseURL,
            operationID: "limited"
        )

        let body = try #require(responseBody)
        do {
            _ = try await Array(collecting: body, upTo: 64)
            Issue.record("expected responseBodyTooLarge while consuming streamed body")
        } catch let error as InnoNetworkClientTransportError {
            guard case .responseBodyTooLarge(let limit, let received) = error else {
                Issue.record("expected .responseBodyTooLarge, got \(error)")
                return
            }
            #expect(limit == 3)
            #expect(received == 4)
        }
    }

    @Test("Response byte limit fails before returning body when Content-Length is too large")
    func responseByteLimitFailsBeforeBodyWhenContentLengthTooLarge() async throws {
        let baseURL = URL(string: "https://api.example.com")!
        let streamURL = baseURL.appendingPathComponent("content-length")
        OpenAPIClientTransportURLProtocol.register(
            url: streamURL,
            response: .http(
                statusCode: 200,
                headers: ["Content-Length": "4"],
                chunks: [Data("1234".utf8)]
            )
        )
        let transport = InnoNetworkClientTransport(
            session: makeOpenAPIClientTransportURLSession(),
            responseBodyByteLimit: 3
        )

        do {
            _ = try await transport.send(
                HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/content-length"),
                body: nil,
                baseURL: baseURL,
                operationID: "content-length"
            )
            Issue.record("expected responseBodyTooLarge before body is returned")
        } catch let error as InnoNetworkClientTransportError {
            guard case .responseBodyTooLarge(let limit, let received) = error else {
                Issue.record("expected .responseBodyTooLarge, got \(error)")
                return
            }
            #expect(limit == 3)
            #expect(received == 4)
        }
    }

    @Test("No-body statuses skip oversized Content-Length precheck", arguments: [204, 205, 304])
    func noBodyStatusesSkipOversizedContentLengthPrecheck(statusCode: Int) async throws {
        let baseURL = URL(string: "https://api.example.com")!
        let streamURL = baseURL.appendingPathComponent("no-body-\(statusCode)")
        OpenAPIClientTransportURLProtocol.register(
            url: streamURL,
            response: .http(
                statusCode: statusCode,
                headers: ["Content-Length": "4096"],
                chunks: []
            )
        )
        let transport = InnoNetworkClientTransport(
            session: makeOpenAPIClientTransportURLSession(),
            responseBodyByteLimit: 1
        )

        let (response, responseBody) = try await transport.send(
            HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/no-body-\(statusCode)"),
            body: nil,
            baseURL: baseURL,
            operationID: "no-body-\(statusCode)"
        )

        #expect(response.status.code == statusCode)
        #expect(responseBody == nil)
    }

    @Test("HEAD skips oversized Content-Length precheck and returns no body")
    func headReturnsNoBody() async throws {
        let baseURL = URL(string: "https://api.example.com")!
        let streamURL = baseURL.appendingPathComponent("head")
        OpenAPIClientTransportURLProtocol.register(
            url: streamURL,
            response: .http(
                statusCode: 200,
                headers: ["Content-Length": "4096"],
                chunks: []
            )
        )
        let transport = InnoNetworkClientTransport(
            session: makeOpenAPIClientTransportURLSession(),
            responseBodyByteLimit: 1
        )

        let (response, responseBody) = try await transport.send(
            HTTPRequest(method: .head, scheme: nil, authority: nil, path: "/head"),
            body: nil,
            baseURL: baseURL,
            operationID: "head"
        )

        #expect(response.status.code == 200)
        #expect(responseBody == nil)
    }

    @Test("Informational responses are classified as no-body", arguments: [100, 101, 150, 199])
    func informationalResponsesAreNoBody(statusCode: Int) {
        #expect(
            InnoNetworkClientTransport.responseMustNotCarryBody(
                requestMethod: "GET",
                statusCode: statusCode
            )
        )
    }

    @Test("Surfaces typed error for a non-HTTP response")
    func surfacesTypedErrorForNonHTTPResponse() async throws {
        let baseURL = URL(string: "https://api.example.com")!
        let streamURL = baseURL.appendingPathComponent("non-http")
        OpenAPIClientTransportURLProtocol.register(
            url: streamURL,
            response: .nonHTTP(data: Data("body".utf8))
        )
        let transport = InnoNetworkClientTransport(session: makeOpenAPIClientTransportURLSession())

        do {
            _ = try await transport.send(
                HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/non-http"),
                body: nil,
                baseURL: baseURL,
                operationID: "non-http"
            )
            Issue.record("expected InnoNetworkClientTransportError.nonHTTPResponse")
        } catch let error as InnoNetworkClientTransportError {
            guard case .nonHTTPResponse = error else {
                Issue.record("expected .nonHTTPResponse, got \(error)")
                return
            }
        }
    }
}
