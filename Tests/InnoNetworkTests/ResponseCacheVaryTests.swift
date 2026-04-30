import Foundation
import Testing

@testable import InnoNetwork

@Suite("Response Cache Vary Handling")
struct ResponseCacheVaryTests {

    private func request(
        url: String = "https://api.example.com/users/1",
        headers: [String: String] = [:]
    ) -> URLRequest {
        var urlRequest = URLRequest(url: URL(string: url)!)
        for (name, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    // MARK: - evaluateVary

    @Test("No Vary header → noVary")
    func noVaryHeaderProducesNoVary() async {
        let evaluation = evaluateVary(
            responseHeaders: ["Content-Type": "application/json"],
            request: request()
        )
        #expect(evaluation == .noVary)
    }

    @Test("Empty Vary header value → noVary")
    func emptyVaryHeaderProducesNoVary() async {
        let evaluation = evaluateVary(
            responseHeaders: ["Vary": ""],
            request: request()
        )
        #expect(evaluation == .noVary)
    }

    @Test("Vary: * → wildcardSkipsCache")
    func wildcardVaryRefusesCache() async {
        let evaluation = evaluateVary(
            responseHeaders: ["Vary": "*"],
            request: request(headers: ["Accept-Language": "en-US"])
        )
        #expect(evaluation == .wildcardSkipsCache)
    }

    @Test("Vary list containing * still refuses cache")
    func mixedWildcardVaryRefusesCache() async {
        let evaluation = evaluateVary(
            responseHeaders: ["Vary": "Accept-Language, *"],
            request: request(headers: ["Accept-Language": "en-US"])
        )
        #expect(evaluation == .wildcardSkipsCache)
    }

    @Test("Vary: Accept-Language captures the request value snapshot")
    func singleHeaderVaryCapturesSnapshot() async {
        let evaluation = evaluateVary(
            responseHeaders: ["Vary": "Accept-Language"],
            request: request(headers: ["Accept-Language": "en-US"])
        )
        #expect(evaluation == .vary(["accept-language": "en-US"]))
    }

    @Test("Vary header values are matched case-insensitively against the request")
    func varyHeaderLookupIsCaseInsensitive() async {
        // URLRequest uppercases stored header names, so the snapshot lookup
        // must use case-insensitive header field semantics.
        let evaluation = evaluateVary(
            responseHeaders: ["Vary": "accept-language"],
            request: request(headers: ["Accept-Language": "en-US"])
        )
        #expect(evaluation == .vary(["accept-language": "en-US"]))
    }

    @Test("Multi-header Vary: list captures every named header")
    func multipleVaryHeadersAreCaptured() async {
        let evaluation = evaluateVary(
            responseHeaders: ["Vary": "Accept-Language, Accept-Encoding"],
            request: request(headers: [
                "Accept-Language": "en-US",
                "Accept-Encoding": "gzip",
            ])
        )
        #expect(
            evaluation
                == .vary([
                    "accept-language": "en-US",
                    "accept-encoding": "gzip",
                ])
        )
    }

    @Test("Missing request header for a varied name records nil")
    func missingRequestHeaderRecordsNil() async {
        let evaluation = evaluateVary(
            responseHeaders: ["Vary": "Accept-Language"],
            request: request()
        )
        #expect(evaluation == .vary(["accept-language": nil]))
    }

    @Test("Sensitive Vary headers store fingerprints instead of raw values")
    func sensitiveVaryHeadersStoreFingerprints() async throws {
        let token = "Bearer secret-token"
        let evaluation = evaluateVary(
            responseHeaders: ["Vary": "Authorization"],
            request: request(headers: ["Authorization": token])
        )
        guard case .vary(let snapshot) = evaluation else {
            Issue.record("Expected Vary snapshot for Authorization")
            return
        }

        let storedValue = try #require(snapshot["authorization"] ?? nil)
        #expect(storedValue != token)
        #expect(storedValue.hasPrefix("sha256:"))

        let cached = CachedResponse(data: Data(), varyHeaders: snapshot)
        #expect(
            cachedResponseMatchesVary(
                cached,
                request: request(headers: ["Authorization": token])
            )
        )
        #expect(
            !cachedResponseMatchesVary(
                cached,
                request: request(headers: ["Authorization": "Bearer other-token"])
            )
        )
    }

    // MARK: - cachedResponseMatchesVary

    @Test("nil varyHeaders always matches (no vary semantics)")
    func nilVarySnapshotAlwaysMatches() async {
        let cached = CachedResponse(data: Data(), varyHeaders: nil)
        #expect(cachedResponseMatchesVary(cached, request: request(headers: ["Accept-Language": "en-US"])))
        #expect(cachedResponseMatchesVary(cached, request: request()))
    }

    @Test("Matching snapshot accepts the lookup")
    func matchingSnapshotAccepts() async {
        let cached = CachedResponse(
            data: Data(),
            varyHeaders: ["accept-language": "en-US"]
        )
        #expect(
            cachedResponseMatchesVary(
                cached,
                request: request(headers: ["Accept-Language": "en-US"])
            )
        )
    }

    @Test("Mismatching snapshot rejects the lookup")
    func mismatchingSnapshotRejects() async {
        let cached = CachedResponse(
            data: Data(),
            varyHeaders: ["accept-language": "en-US"]
        )
        #expect(
            !cachedResponseMatchesVary(
                cached,
                request: request(headers: ["Accept-Language": "ko-KR"])
            )
        )
    }

    @Test("nil-stored value matches absence of the header on the request")
    func nilStoredValueMatchesAbsence() async {
        let cached = CachedResponse(
            data: Data(),
            varyHeaders: ["accept-language": nil]
        )
        // Cached when the request did NOT carry Accept-Language; the next
        // request also omits it → match.
        #expect(cachedResponseMatchesVary(cached, request: request()))
        // Different request now carries the header → mismatch.
        #expect(
            !cachedResponseMatchesVary(
                cached,
                request: request(headers: ["Accept-Language": "en-US"])
            )
        )
    }

    @Test("Multi-header snapshot rejects when any single header diverges")
    func multiHeaderSnapshotRejectsPartialMatch() async {
        let cached = CachedResponse(
            data: Data(),
            varyHeaders: [
                "accept-language": "en-US",
                "accept-encoding": "gzip",
            ]
        )
        #expect(
            !cachedResponseMatchesVary(
                cached,
                request: request(headers: [
                    "Accept-Language": "en-US",
                    "Accept-Encoding": "br",
                ])
            )
        )
    }
}
