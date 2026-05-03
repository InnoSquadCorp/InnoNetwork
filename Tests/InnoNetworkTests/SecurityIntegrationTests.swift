import Foundation
import Testing

@testable import InnoNetwork

@Suite("Security integration scenarios")
struct SecurityIntegrationTests {
    @Test("Cross-origin redirect strips Authorization from a client-built request")
    func crossOriginRedirectStripsAuthorization() async throws {
        let session = MockURLSession()
        try session.setMockJSON(SecurityUser(id: 1, name: "secure"))
        let configuration = makeTestNetworkConfiguration(
            baseURL: "https://api.example.com",
            requestInterceptors: [
                SecurityHeaderInterceptor(field: "Authorization", value: "Bearer secret-token"),
                SecurityHeaderInterceptor(field: "X-Trace-ID", value: "trace-1"),
            ]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        _ = try await client.request(SecurityGetRequest())

        let original = try #require(session.capturedRequest)
        #expect(original.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")

        var redirected = URLRequest(url: URL(string: "https://attacker.example.org/users/1")!)
        redirected.allHTTPHeaderFields = original.allHTTPHeaderFields
        let response = HTTPURLResponse(
            url: original.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirected.url!.absoluteString]
        )!

        let result = try #require(
            configuration.redirectPolicy.redirect(
                request: redirected,
                response: response,
                originalRequest: original
            )
        )

        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(result.value(forHTTPHeaderField: "X-Trace-ID") == "trace-1")
    }

    @Test("Plain HTTP baseURL is rejected before transport dispatch")
    func plainHTTPBaseURLRejectedBeforeDispatch() async throws {
        let session = MockURLSession()
        try session.setMockJSON(SecurityUser(id: 1, name: "unused"))
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: URL(string: "http://api.example.com")!),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            _ = try await client.request(SecurityGetRequest())
        }
        #expect(session.capturedRequest == nil)
    }

    @Test("URL embedded credentials are rejected without leaking to errors or transport")
    func urlEmbeddedCredentialsRejectedAndRedacted() async throws {
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://alice:secret@api.example.com")!
            ),
            session: session
        )

        do {
            _ = try await client.request(SecurityGetRequest())
            Issue.record("Expected userinfo-bearing baseURL to throw.")
        } catch {
            let message = String(describing: error)
            #expect(!message.contains("alice"))
            #expect(!message.contains("secret"))
            #expect(!message.contains("alice:secret"))
        }
        #expect(session.capturedRequest == nil)
    }

    @Test("Quoted Cache-Control private directive invalidates stale cache and skips storage")
    func quotedCacheControlPrivateIsolatesCache() async throws {
        let cache = InMemoryResponseCache()
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://api.example.com/users/1",
            headers: ["Accept-Language": "en-US"]
        )
        let stale = try JSONEncoder().encode(SecurityUser(id: 1, name: "stale"))
        await cache.set(
            key,
            CachedResponse(
                data: stale,
                headers: ["ETag": "stale"],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )

        let fresh = SecurityUser(id: 1, name: "fresh-private")
        let session = MockURLSession()
        session.mockData = try JSONEncoder().encode(fresh)
        session.mockResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/users/1")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Cache-Control": "max-age=60, private=\"Set-Cookie, Authorization\""
            ]
        )!
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache,
                acceptLanguageProvider: { "en-US" }
            ),
            session: session
        )

        let user = try await client.request(SecurityGetRequest())

        #expect(user == fresh)
        #expect(session.capturedRequest != nil)
        #expect(await cache.get(key) == nil)
    }
}

private struct SecurityUser: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}

private struct SecurityGetRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = SecurityUser

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}

private struct SecurityHeaderInterceptor: RequestInterceptor {
    let field: String
    let value: String

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue(value, forHTTPHeaderField: field)
        return request
    }
}
