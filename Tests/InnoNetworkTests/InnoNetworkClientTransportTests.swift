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
            guard let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            ) else {
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
