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
            "Content-Type": "application/json"
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

    @Test("Cookie values are redacted by default")
    func cookiesAreRedacted() throws {
        let logger = DefaultNetworkLogger()
        let cookie = try #require(
            HTTPCookie(properties: [
                .name: "session",
                .value: "sensitive",
                .domain: "example.com",
                .path: "/"
            ])
        )

        let sanitizedCookies = logger.sanitize(cookies: [cookie])
        #expect(sanitizedCookies.contains("session=<redacted>"))
        #expect(!sanitizedCookies.contains("sensitive"))
    }
}
