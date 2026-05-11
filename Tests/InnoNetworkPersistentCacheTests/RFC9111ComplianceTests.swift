import Foundation
import InnoNetwork
import Testing

@Suite("RFC 9111 Compliant Cache Policy Tests")
struct RFC9111ComplianceTests {

    // MARK: - no-store

    @Test("no-store on cached entry forces network revalidation through adapter")
    func noStoreSuppressesCacheReads() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "no-store"],
            storedAt: storedAt
        )
        let inner = ResponseCachePolicy.cacheFirst(maxAge: .seconds(60))
        let adapter = ResponseCachePolicy.rfc9111Compliant(wrapping: inner)

        // Inner policy would happily serve a fresh entry.
        switch inner.prepare(cached: cached, now: storedAt) {
        case .returnCached:
            break
        default:
            Issue.record("inner policy should serve a fresh entry without no-store enforcement")
        }

        // Adapter must refuse the read despite the entry being inside maxAge.
        switch adapter.prepare(cached: cached, now: storedAt) {
        case .revalidate(let attached):
            #expect(attached == nil, "no-store entry must be treated as absent")
        default:
            Issue.record("adapter should force revalidation for no-store cached entry")
        }
    }

    // MARK: - must-revalidate

    @Test("must-revalidate disables stale-while-revalidate stale window")
    func mustRevalidateBlocksStaleWindow() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "must-revalidate"],
            storedAt: storedAt
        )
        let inner = ResponseCachePolicy.staleWhileRevalidate(maxAge: .seconds(10), staleWindow: .seconds(60))
        let adapter = ResponseCachePolicy.rfc9111Compliant(wrapping: inner)

        // 30 seconds past storedAt → inside the inner stale window (10+60 = 70s).
        let now = storedAt.addingTimeInterval(30)

        switch inner.prepare(cached: cached, now: now) {
        case .returnStaleAndRevalidate:
            break
        default:
            Issue.record("inner policy should hit the stale window without must-revalidate enforcement")
        }

        switch adapter.prepare(cached: cached, now: now) {
        case .revalidate(let attached):
            #expect(attached == cached, "must-revalidate must force a conditional revalidation, not bypass")
        default:
            Issue.record("adapter should force revalidation when must-revalidate is set on a stale entry")
        }
    }

    @Test("must-revalidate does not affect fresh entries")
    func mustRevalidateLeavesFreshEntriesAlone() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "must-revalidate"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .staleWhileRevalidate(maxAge: .seconds(60), staleWindow: .seconds(60))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(5)) {
        case .returnCached:
            break
        default:
            Issue.record("must-revalidate should not block reads while entry is still fresh")
        }
    }

    // MARK: - max-age override

    @Test("Server max-age narrows inner freshness window")
    func serverMaxAgeNarrowsFreshness() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "max-age=5"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )

        // 3 seconds in → inside server max-age (5s)  →  fresh.
        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(3)) {
        case .returnCached:
            break
        default:
            Issue.record("entry should be fresh within the server max-age window")
        }

        // 10 seconds in → past server max-age (5s) but inside inner maxAge (60s).
        // Adapter must use the narrower server value.
        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(10)) {
        case .revalidate(let attached):
            #expect(attached == cached, "expired entry must be revalidated with the cached representation attached")
        default:
            Issue.record("adapter should revalidate past the server max-age window")
        }
    }

    @Test("Server max-age cannot extend caller's freshness window")
    func serverMaxAgeCannotExtendCallerWindow() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "max-age=600"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(10))
        )

        // 20 seconds in → past caller's 10s ceiling, inside server's 600s.
        // The caller's ceiling must remain enforced.
        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(20)) {
        case .revalidate:
            break
        default:
            Issue.record("server cannot extend the caller's freshness ceiling")
        }
    }

    // MARK: - Pass-through

    @Test("Adapter without directives matches inner policy behaviour")
    func transparentWithoutDirectives() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Content-Type": "application/json"],
            storedAt: storedAt
        )
        let inner = ResponseCachePolicy.cacheFirst(maxAge: .seconds(30))
        let adapter = ResponseCachePolicy.rfc9111Compliant(wrapping: inner)

        let now = storedAt.addingTimeInterval(10)
        let innerResult = inner.prepare(cached: cached, now: now)
        let adapterResult = adapter.prepare(cached: cached, now: now)

        switch (innerResult, adapterResult) {
        case (.returnCached, .returnCached):
            break
        default:
            Issue.record("adapter must behave identically when no governed directives are present")
        }
    }

    @Test("Adapter inherits inner policy capabilities")
    func adapterCapabilitiesMatchInner() {
        let inner = ResponseCachePolicy.cacheFirst(maxAge: .seconds(60))
        let adapter = ResponseCachePolicy.rfc9111Compliant(wrapping: inner)
        #expect(adapter.isEnabled == inner.isEnabled)
        #expect(adapter.allowsCacheRead == inner.allowsCacheRead)
        #expect(adapter.allowsCacheWrite == inner.allowsCacheWrite)
        #expect(adapter.allowsConditionalRevalidation == inner.allowsConditionalRevalidation)

        let disabledAdapter = ResponseCachePolicy.rfc9111Compliant(wrapping: .disabled)
        #expect(!disabledAdapter.isEnabled)
        #expect(!disabledAdapter.allowsCacheRead)
        #expect(!disabledAdapter.allowsCacheWrite)
    }

    // MARK: - Edge cases

    @Test("max-age with malformed value falls back to inner freshness")
    func malformedMaxAgeIsIgnored() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "max-age=not-a-number"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(30)) {
        case .returnCached:
            break
        default:
            Issue.record("malformed max-age should not collapse the inner freshness window")
        }
    }

    @Test("Multiple Cache-Control directives are honoured together")
    func combinedDirectives() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "max-age=5, must-revalidate"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .staleWhileRevalidate(maxAge: .seconds(60), staleWindow: .seconds(60))
        )

        // Past server max-age (5s) — must-revalidate forbids the stale window.
        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(10)) {
        case .revalidate:
            break
        default:
            Issue.record("max-age + must-revalidate should force revalidation past the server window")
        }
    }
}
