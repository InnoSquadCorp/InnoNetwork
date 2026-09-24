import Foundation
import Testing

@testable import InnoNetwork

@Suite("Request cache freshness")
struct RequestCacheFreshnessTests {
    @Test(arguments: [
        ("max-age=10", true), ("max-age=9", false), ("max-age=0", false),
        ("min-fresh=10", true), ("min-fresh=11", false), ("no-cache", false),
        ("max-age=20, max-age=20", false), ("min-fresh=-1", false),
        ("max-age=1.5", false), ("max-age=\"10\"", true),
        ("extension=\"no-cache,max-age=0\"", true), ("", true),
    ])
    func constraints(control: String, reusable: Bool) {
        let now = Date(timeIntervalSince1970: 100)
        let cached = CachedResponse(
            data: Data(), headers: ["Cache-Control": "max-age=20"], storedAt: now.addingTimeInterval(-10))
        var request = URLRequest(url: URL(string: "https://example.test/item")!)
        request.setValue(control, forHTTPHeaderField: "Cache-Control")
        let policy = ResponseCachePolicy.requestFreshness(
            wrapping: .staleWhileRevalidate(maxAge: .seconds(60), staleWindow: .seconds(60)))
        #expect(policy.permitsRequestFreshness(request, cached: cached, now: now) == reusable)
        if reusable {
            guard case .returnCached = policy.prepare(cached: cached, request: request, now: now) else {
                Issue.record("Expected reusable entry")
                return
            }
        } else {
            guard case .revalidate = policy.prepare(cached: cached, request: request, now: now) else {
                Issue.record("Expected foreground validation")
                return
            }
        }
        #expect(
            ResponseCachePolicy.cacheFirst(maxAge: .seconds(60)).permitsRequestFreshness(
                request, cached: cached, now: now))
    }

    @Test("request constraints include stored Age and never widen response lifetime")
    func initialAgeAndStaleWindow() {
        let now = Date(timeIntervalSince1970: 100)
        let cached = CachedResponse(data: Data(), headers: ["Age": "20", "Cache-Control": "max-age=10"], storedAt: now)
        var request = URLRequest(url: URL(string: "https://example.test/item")!)
        request.setValue("max-age=100", forHTTPHeaderField: "Cache-Control")
        let policy = ResponseCachePolicy.requestFreshness(wrapping: .cacheFirst(maxAge: .seconds(100)))
        #expect(!policy.permitsRequestFreshness(request, cached: cached, now: now))
    }
}
