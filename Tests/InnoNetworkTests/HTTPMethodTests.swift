import Foundation
import Testing

@testable import InnoNetwork

@Suite("HTTP method tokens")
struct HTTPMethodTests {
    @Test("standard methods preserve their wire values")
    func standardMethods() {
        let methods: [(HTTPMethod, String)] = [
            (.get, "GET"),
            (.head, "HEAD"),
            (.post, "POST"),
            (.put, "PUT"),
            (.patch, "PATCH"),
            (.delete, "DELETE"),
            (.connect, "CONNECT"),
            (.options, "OPTIONS"),
            (.trace, "TRACE"),
        ]

        for (method, rawValue) in methods {
            #expect(method.rawValue == rawValue)
            #expect(HTTPMethod(rawValue: rawValue) == method)
        }
    }

    @Test("custom extension methods accept every RFC token character")
    func customMethodTokenCharacters() throws {
        let rawValue = "AZaz09!#$%&'*+-.^_`|~"
        let method = try #require(HTTPMethod(rawValue: rawValue))

        #expect(method.rawValue == rawValue)
    }

    @Test("custom extension methods remain case-sensitive")
    func customMethodsAreCaseSensitive() throws {
        let uppercase = try #require(HTTPMethod(rawValue: "PURGE"))
        let lowercase = try #require(HTTPMethod(rawValue: "purge"))

        #expect(uppercase != lowercase)
        #expect(uppercase.rawValue == "PURGE")
        #expect(lowercase.rawValue == "purge")
    }

    @Test(
        "invalid HTTP method tokens are rejected without trapping",
        arguments: [
            "",
            "GET POST",
            "GET\tPOST",
            "GET\nPOST",
            "G\u{0000}ET",
            "G\u{001F}ET",
            "G\u{007F}ET",
            "GET(",
            "GET)",
            "GET<",
            "GET>",
            "GET@",
            "GET,",
            "GET;",
            "GET:",
            "GET\\",
            "GET\"",
            "GET/",
            "GET[",
            "GET]",
            "GET?",
            "GET=",
            "GET{",
            "GET}",
            "메서드",
        ]
    )
    func invalidTokens(rawValue: String) {
        #expect(HTTPMethod(rawValue: rawValue) == nil)
    }

    @Test("GET and HEAD use query transport and forbid request bodies")
    func queryTransportSemantics() {
        for method in [HTTPMethod.get, .head] {
            #expect(method.defaultsToQueryTransport)
            #expect(method.forbidsRequestBody)
        }
    }

    @Test("TRACE forbids request bodies without defaulting to query transport")
    func traceSemantics() {
        #expect(!HTTPMethod.trace.defaultsToQueryTransport)
        #expect(HTTPMethod.trace.forbidsRequestBody)
    }

    @Test("other standard and custom methods allow body transports")
    func bodyTransportSemantics() throws {
        let custom = try #require(HTTPMethod(rawValue: "PURGE"))
        let methods: [HTTPMethod] = [
            .post,
            .put,
            .patch,
            .delete,
            .connect,
            .options,
            custom,
        ]

        for method in methods {
            #expect(!method.defaultsToQueryTransport)
            #expect(!method.forbidsRequestBody)
        }
    }

    @Test("Idempotency policy preserves custom method case sensitivity")
    func idempotencyPolicyPreservesCustomMethodCase() throws {
        let purge = try #require(HTTPMethod(rawValue: "PURGE"))
        let policy = IdempotencyKeyPolicy(methods: [purge]) { _ in "stable-key" }
        var matching = URLRequest(url: URL(string: "https://api.example.com/cache")!)
        matching.httpMethod = "PURGE"
        var differentlyCased = matching
        differentlyCased.httpMethod = "purge"

        policy.apply(to: &matching, requestID: UUID())
        policy.apply(to: &differentlyCased, requestID: UUID())

        #expect(matching.value(forHTTPHeaderField: "Idempotency-Key") == "stable-key")
        #expect(differentlyCased.value(forHTTPHeaderField: "Idempotency-Key") == nil)
    }
}
