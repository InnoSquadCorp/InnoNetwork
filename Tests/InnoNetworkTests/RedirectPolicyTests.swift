import Foundation
import Testing

@testable import InnoNetwork

@Suite("Redirect policy — RFC 9110 §15.4.4 cross-origin sensitive header strip")
struct RedirectPolicyTests {
    @Test("Same-origin redirect preserves Authorization header")
    func sameOriginPreservesAuthorization() async throws {
        let policy = DefaultRedirectPolicy()

        var original = URLRequest(url: URL(string: "https://api.example.com/login")!)
        original.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        original.setValue("session=abc", forHTTPHeaderField: "Cookie")

        var redirect = URLRequest(url: URL(string: "https://api.example.com/v2/login")!)
        redirect.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        redirect.setValue("session=abc", forHTTPHeaderField: "Cookie")

        let response = HTTPURLResponse(
            url: original.url!,
            statusCode: 301,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            await policy.redirect(request: redirect, response: response, originalRequest: original)
        )

        #expect(result.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(result.value(forHTTPHeaderField: "Cookie") == "session=abc")
    }

    @Test("Cross-host redirect strips Authorization, Cookie, Proxy-Authorization")
    func crossHostStripsCredentials() async throws {
        let policy = DefaultRedirectPolicy()

        var original = URLRequest(url: URL(string: "https://api.example.com/login")!)
        original.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")

        var redirect = URLRequest(url: URL(string: "https://attacker.example.org/steal")!)
        redirect.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        redirect.setValue("session=abc", forHTTPHeaderField: "Cookie")
        redirect.setValue("Basic xyz", forHTTPHeaderField: "Proxy-Authorization")
        redirect.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = HTTPURLResponse(
            url: original.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            await policy.redirect(request: redirect, response: response, originalRequest: original)
        )

        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(result.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(result.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        #expect(result.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("Cross-scheme HTTPS→HTTP redirect strips credentials")
    func schemeChangeStripsCredentials() async throws {
        let policy = DefaultRedirectPolicy()

        var original = URLRequest(url: URL(string: "https://api.example.com/me")!)
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        var redirect = URLRequest(url: URL(string: "http://api.example.com/me")!)
        redirect.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let response = HTTPURLResponse(
            url: original.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            await policy.redirect(request: redirect, response: response, originalRequest: original)
        )
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Cross-port redirect on same host strips credentials")
    func crossPortStripsCredentials() async throws {
        let policy = DefaultRedirectPolicy()

        var original = URLRequest(url: URL(string: "https://api.example.com/me")!)
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        var redirect = URLRequest(url: URL(string: "https://api.example.com:8443/me")!)
        redirect.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let response = HTTPURLResponse(
            url: original.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            await policy.redirect(request: redirect, response: response, originalRequest: original)
        )
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Header name casing variants all stripped on cross-origin")
    func caseInsensitiveStrip() async throws {
        let policy = DefaultRedirectPolicy()

        let original = URLRequest(url: URL(string: "https://a.example.com/")!)
        var redirect = URLRequest(url: URL(string: "https://b.example.com/")!)
        redirect.setValue("Bearer token", forHTTPHeaderField: "authorization")
        redirect.setValue("c=1", forHTTPHeaderField: "COOKIE")

        let response = HTTPURLResponse(
            url: original.url!, statusCode: 307, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            await policy.redirect(request: redirect, response: response, originalRequest: original)
        )
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(result.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test("Non-HTTP redirect target rejected")
    func rejectsNonHTTPSchemes() async {
        let policy = DefaultRedirectPolicy()

        let original = URLRequest(url: URL(string: "https://api.example.com/")!)
        let redirect = URLRequest(url: URL(string: "file:///etc/passwd")!)

        let response = HTTPURLResponse(
            url: original.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = await policy.redirect(
            request: redirect, response: response, originalRequest: original
        )
        #expect(result == nil)
    }

    @Test("Same-origin port equivalence: explicit default port matches implicit")
    func defaultPortEquivalence() async throws {
        let policy = DefaultRedirectPolicy()

        let original = URLRequest(url: URL(string: "https://api.example.com/login")!)
        var redirect = URLRequest(url: URL(string: "https://api.example.com:443/login")!)
        redirect.setValue("Bearer token", forHTTPHeaderField: "Authorization")

        let response = HTTPURLResponse(
            url: original.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            await policy.redirect(request: redirect, response: response, originalRequest: original)
        )
        #expect(result.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }
}
