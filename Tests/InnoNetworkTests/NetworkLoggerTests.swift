import Foundation
import Testing

@testable import InnoNetwork

@Suite("Network Logger Tests")
struct NetworkLoggerTests {
    @Test("Sensitive headers are redacted by default")
    func sensitiveHeadersAreRedacted() {
        let logger = DefaultNetworkLogger()
        let sanitizedHeaders = logger.sanitize(headers: [
            "Authorization": "Bearer token",
            "X-API-Key": "secret-key",
            "Content-Type": "application/json",
        ])

        #expect(sanitizedHeaders["Authorization"] == "<redacted>")
        #expect(sanitizedHeaders["X-API-Key"] == "<redacted>")
        #expect(sanitizedHeaders["Content-Type"] == "application/json")
    }

    @Test("Secure default redacts body and verbose mode keeps body")
    func bodyLoggingOptions() {
        let secureLogger = DefaultNetworkLogger(options: .secureDefault)
        let verboseLogger = DefaultNetworkLogger(options: .verbose)

        #expect(secureLogger.sanitize(body: "{\"token\":\"abc\"}") == "<redacted>")
        #expect(verboseLogger.sanitize(body: "{\"token\":\"abc\"}") == "{\"token\":\"abc\"}")
    }

    @Test("Secure default redacts URL query values")
    func secureDefaultRedactsURLQueryValues() throws {
        let logger = DefaultNetworkLogger()
        let url = try #require(URL(string: "https://example.com/search?token=secret&email=a@example.com&flag"))

        let sanitized = logger.sanitize(url: url)
        let queryItems = try #require(URLComponents(string: sanitized)?.queryItems)

        #expect(queryItems.contains { $0.name == "token" && $0.value == "<redacted>" })
        #expect(queryItems.contains { $0.name == "email" && $0.value == "<redacted>" })
        #expect(queryItems.contains { $0.name == "flag" && $0.value == nil })
        #expect(!sanitized.contains("secret"))
        #expect(!sanitized.contains("a@example.com"))
    }

    @Test("Verbose mode keeps URL query values")
    func verboseModeKeepsURLQueryValues() throws {
        let logger = DefaultNetworkLogger(options: .verbose)
        let url = try #require(URL(string: "https://example.com/search?token=secret&email=a@example.com"))

        #expect(logger.sanitize(url: url) == url.absoluteString)
    }

    @Test("Cookie values are redacted by default")
    func cookiesAreRedacted() throws {
        let logger = DefaultNetworkLogger()
        let cookie = try #require(
            HTTPCookie(properties: [
                .name: "session",
                .value: "sensitive",
                .domain: "example.com",
                .path: "/",
            ])
        )

        let sanitizedCookies = logger.sanitize(cookies: [cookie])
        #expect(sanitizedCookies.contains("session=<redacted>"))
        #expect(!sanitizedCookies.contains("sensitive"))
    }

    @Test("Logger accepts a non-shared cookie storage at init")
    func loggerHonorsInjectedCookieStorage() throws {
        // Use a uniquely-named storage so the test cannot accidentally read
        // or pollute HTTPCookieStorage.shared, which other tests or the
        // host process may rely on.
        let storage = HTTPCookieStorage.sharedCookieStorage(
            forGroupContainerIdentifier: "InnoNetworkLoggerTests.\(UUID().uuidString)"
        )
        let cookie = try #require(
            HTTPCookie(properties: [
                .name: "isolated",
                .value: "scoped",
                .domain: "example.com",
                .path: "/",
            ])
        )
        storage.setCookie(cookie)

        // Constructor accepts the injected storage and redacts the value.
        // The sanitized format is `name=<redacted>` so we look for the name
        // from the injected storage rather than the raw value.
        let logger = DefaultNetworkLogger(
            options: NetworkLoggingOptions(includeCookies: true, redactSensitiveData: true),
            cookieStorage: storage
        )
        let sanitized = logger.sanitize(cookies: storage.cookies ?? [])
        #expect(sanitized.contains("isolated=<redacted>"))

        // Verify the shared singleton was not polluted by the injected setCookie.
        let sharedCookies = HTTPCookieStorage.shared.cookies ?? []
        #expect(!sharedCookies.contains(where: { $0.name == "isolated" }))
    }
}
