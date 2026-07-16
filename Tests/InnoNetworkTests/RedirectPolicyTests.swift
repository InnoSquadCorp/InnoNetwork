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
            policy.redirect(request: redirect, response: response, originalRequest: original)
        )

        #expect(result.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(result.value(forHTTPHeaderField: "Cookie") == "session=abc")
    }

    @Test("Cross-host redirect strips built-in auth, API, and security-token headers")
    func crossHostStripsCredentials() async throws {
        let policy = DefaultRedirectPolicy()

        var original = URLRequest(url: URL(string: "https://api.example.com/login")!)
        original.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")

        var redirect = URLRequest(url: URL(string: "https://attacker.example.org/steal")!)
        redirect.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        redirect.setValue("session=abc", forHTTPHeaderField: "Cookie")
        redirect.setValue("Basic xyz", forHTTPHeaderField: "Proxy-Authorization")
        redirect.setValue("api-secret", forHTTPHeaderField: "X-API-Key")
        redirect.setValue("auth-secret", forHTTPHeaderField: "X-Auth-Token")
        redirect.setValue("aws-session-secret", forHTTPHeaderField: "X-Amz-Security-Token")
        redirect.setValue("csrf-secret", forHTTPHeaderField: "X-CSRF-Token")
        redirect.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = HTTPURLResponse(
            url: original.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            policy.redirect(request: redirect, response: response, originalRequest: original)
        )

        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(result.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(result.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        #expect(result.value(forHTTPHeaderField: "X-API-Key") == nil)
        #expect(result.value(forHTTPHeaderField: "X-Auth-Token") == nil)
        #expect(result.value(forHTTPHeaderField: "X-Amz-Security-Token") == nil)
        #expect(result.value(forHTTPHeaderField: "X-CSRF-Token") == nil)
        #expect(result.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("HTTPS→HTTP redirect is rejected by default")
    func rejectsHTTPSDowngradeByDefault() async {
        let policy = DefaultRedirectPolicy()

        var original = URLRequest(url: URL(string: "https://api.example.com/me")!)
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        var redirect = URLRequest(url: URL(string: "http://api.example.com/me")!)
        redirect.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let response = HTTPURLResponse(
            url: original.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        #expect(
            policy.redirect(request: redirect, response: response, originalRequest: original) == nil
        )
    }

    @Test("Explicit HTTPS downgrade opt-in still strips sensitive headers")
    func allowsOptedInHTTPSDowngradeWithoutCredentials() async throws {
        let policy = DefaultRedirectPolicy(allowsHTTPSDowngrade: true)

        let original = URLRequest(url: URL(string: "https://api.example.com/me")!)
        var redirect = URLRequest(url: URL(string: "http://api.example.com/me")!)
        redirect.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        redirect.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = HTTPURLResponse(
            url: original.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            policy.redirect(request: redirect, response: response, originalRequest: original)
        )
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(result.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("Downgrade detection uses the current redirect hop")
    func rejectsHTTPSDowngradeAfterInitialHTTPHop() async {
        let policy = DefaultRedirectPolicy()

        let original = URLRequest(url: URL(string: "http://bootstrap.example.com/start")!)
        let currentURL = URL(string: "https://api.example.com/me")!
        let redirect = URLRequest(url: URL(string: "http://api.example.com/me")!)
        let response = HTTPURLResponse(
            url: currentURL, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        #expect(
            policy.redirect(request: redirect, response: response, originalRequest: original) == nil
        )
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
            policy.redirect(request: redirect, response: response, originalRequest: original)
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
            policy.redirect(request: redirect, response: response, originalRequest: original)
        )
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(result.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test("Application-specific sensitive headers are additive and case-insensitive")
    func stripsAdditionalSensitiveHeaders() async throws {
        let policy = DefaultRedirectPolicy(
            additionalSensitiveHeaders: ["  X-Tenant-Secret  ", "X-Signed-Identity"]
        )

        let original = URLRequest(url: URL(string: "https://a.example.com/")!)
        var redirect = URLRequest(url: URL(string: "https://b.example.com/")!)
        redirect.setValue("tenant-secret", forHTTPHeaderField: "x-tenant-secret")
        redirect.setValue("identity-secret", forHTTPHeaderField: "X-SIGNED-IDENTITY")
        redirect.setValue("trace-1", forHTTPHeaderField: "X-Trace-ID")

        let response = HTTPURLResponse(
            url: original.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            policy.redirect(request: redirect, response: response, originalRequest: original)
        )
        #expect(policy.additionalSensitiveHeaders == ["x-tenant-secret", "x-signed-identity"])
        #expect(result.value(forHTTPHeaderField: "X-Tenant-Secret") == nil)
        #expect(result.value(forHTTPHeaderField: "X-Signed-Identity") == nil)
        #expect(result.value(forHTTPHeaderField: "X-Trace-ID") == "trace-1")
    }

    @Test("Cross-origin 307/308 rejects unsafe-method replay", arguments: [307, 308])
    func rejectsCrossOriginUnsafeMethodReplay(statusCode: Int) async {
        let policy = DefaultRedirectPolicy()

        var original = URLRequest(url: URL(string: "https://api.example.com/payments")!)
        original.httpMethod = "POST"
        original.httpBody = Data(#"{"amount":100}"#.utf8)
        var redirect = URLRequest(url: URL(string: "https://payments.example.net/submit")!)
        redirect.httpMethod = "POST"
        redirect.httpBody = original.httpBody

        let response = HTTPURLResponse(
            url: original.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        #expect(
            policy.redirect(request: redirect, response: response, originalRequest: original) == nil
        )
    }

    @Test("Cross-origin 307/308 treats lowercase custom methods as unsafe")
    func rejectsDifferentlyCasedSafeMethodTokens() {
        let policy = DefaultRedirectPolicy()

        for method in ["options", "trace"] {
            for statusCode in [307, 308] {
                var original = URLRequest(url: URL(string: "https://api.example.com/source")!)
                original.httpMethod = method
                var redirect = URLRequest(url: URL(string: "https://cdn.example.net/target")!)
                redirect.httpMethod = method
                let response = HTTPURLResponse(
                    url: original.url!,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": redirect.url!.absoluteString]
                )!

                #expect(
                    policy.redirect(request: redirect, response: response, originalRequest: original) == nil
                )
            }
        }
    }

    @Test("Cross-origin 307 for a safe method remains followable")
    func allowsCrossOriginSafeMethodRedirect() async throws {
        let policy = DefaultRedirectPolicy()

        let original = URLRequest(url: URL(string: "https://api.example.com/catalog")!)
        var redirect = URLRequest(url: URL(string: "https://cdn.example.net/catalog")!)
        redirect.httpMethod = "GET"
        redirect.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let response = HTTPURLResponse(
            url: original.url!, statusCode: 307, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            policy.redirect(request: redirect, response: response, originalRequest: original)
        )
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Same-origin 307 preserves an unsafe method and body")
    func allowsSameOriginUnsafeMethodRedirect() async throws {
        let policy = DefaultRedirectPolicy()

        var original = URLRequest(url: URL(string: "https://api.example.com/payments")!)
        original.httpMethod = "POST"
        var redirect = URLRequest(url: URL(string: "https://api.example.com/v2/payments")!)
        redirect.httpMethod = "POST"
        redirect.httpBody = Data(#"{"amount":100}"#.utf8)

        let response = HTTPURLResponse(
            url: original.url!, statusCode: 307, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            policy.redirect(request: redirect, response: response, originalRequest: original)
        )
        #expect(result.httpMethod == "POST")
        #expect(result.httpBody == redirect.httpBody)
    }

    @Test("Explicit unsafe-method opt-in still strips cross-origin credentials")
    func allowsOptedInCrossOriginUnsafeMethodWithoutCredentials() async throws {
        let policy = DefaultRedirectPolicy(allowsCrossOriginUnsafeMethodRedirects: true)

        var original = URLRequest(url: URL(string: "https://api.example.com/payments")!)
        original.httpMethod = "PATCH"
        var redirect = URLRequest(url: URL(string: "https://payments.example.net/submit")!)
        redirect.httpMethod = "PATCH"
        redirect.httpBody = Data(#"{"state":"confirmed"}"#.utf8)
        redirect.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let response = HTTPURLResponse(
            url: original.url!, statusCode: 308, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.url!.absoluteString]
        )!

        let result = try #require(
            policy.redirect(request: redirect, response: response, originalRequest: original)
        )
        #expect(result.httpMethod == "PATCH")
        #expect(result.httpBody == redirect.httpBody)
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
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

        let result = policy.redirect(
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
            policy.redirect(request: redirect, response: response, originalRequest: original)
        )
        #expect(result.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }
}
