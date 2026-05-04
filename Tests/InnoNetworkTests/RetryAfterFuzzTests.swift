import Foundation
import Testing

@testable import InnoNetwork

/// Property-based fuzz coverage over `ExponentialBackoffRetryPolicy.parseRetryAfter`
/// and the `shouldRetry(error:retryIndex:request:response:)` contextual
/// overload that drives `Retry-After`-aware scheduling.
///
/// Asserts the invariants the retry coordinator relies on:
///
/// 1. Non-negative integer delta-seconds round-trip exactly.
/// 2. Negative deltas, malformed strings, and HTTP-dates in the past
///    all produce `nil` so the coordinator falls back to its own
///    jittered backoff.
/// 3. HTTP-dates in the future produce a non-negative `TimeInterval`
///    consistent with `date.timeIntervalSince(now)` modulo
///    formatter rounding (≤ 1 second slack).
/// 4. The contextual `shouldRetry` overload only emits `.retryAfter`
///    on `429` or `503` responses with a parseable header; everything
///    else is `.retry` (when the error/index would otherwise allow a
///    retry) or `.noRetry`.
@Suite("Retry-After parsing fuzz")
struct RetryAfterFuzzTests {
    private static let seeds: [UInt64] = [
        0x1234_5678_ABCD_EF01,
        0xDEAD_BEEF_CAFE_BABE,
        0x0F0F_0F0F_0F0F_0F0F,
        0xFEDC_BA98_7654_3210,
        0xA5A5_5A5A_3C3C_C3C3,
    ]

    @Test("non-negative integer delta-seconds round-trip", arguments: seeds)
    func nonNegativeIntegerDeltaRoundTrips(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<1000 {
            let value = Int(rng.next() % 100_000)
            let parsed = ExponentialBackoffRetryPolicy.parseRetryAfter("\(value)")
            #expect(parsed == TimeInterval(value), "delta=\(value) parsed=\(String(describing: parsed))")
        }
    }

    @Test("negative or non-numeric deltas return nil", arguments: seeds)
    func negativeOrJunkReturnsNil(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let junkAlphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEF!@#$%^&*()_+=[]{};:'\",<>/?\\|`~")
        for _ in 0..<500 {
            let isNegative = (rng.next() & 1) == 1
            if isNegative {
                let value = Int(rng.next() % 100_000) + 1
                #expect(ExponentialBackoffRetryPolicy.parseRetryAfter("-\(value)") == nil)
                continue
            }
            let length = Int(rng.next() % 10) + 1
            var junk = ""
            for _ in 0..<length {
                let pick = Int(rng.next() % UInt64(junkAlphabet.count))
                junk.append(junkAlphabet[pick])
            }
            // Skip the rare case the random string parses as a non-negative Int
            // (e.g. \"3\" if the alphabet ever gained digits — it doesn't, but
            // be defensive).
            if Int(junk.trimmingCharacters(in: .whitespacesAndNewlines)) != nil { continue }
            #expect(
                ExponentialBackoffRetryPolicy.parseRetryAfter(junk) == nil,
                "junk \(junk.debugDescription) parsed unexpectedly"
            )
        }
    }

    @Test("HTTP-date in the future returns delta within ±1s of true delta", arguments: seeds)
    func httpDateFutureMatchesTrueDelta(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        for _ in 0..<500 {
            let deltaSeconds = TimeInterval(Int(rng.next() % 86_400) + 1)
            let future = now.addingTimeInterval(deltaSeconds)
            let header = formatter.string(from: future)
            let parsed = ExponentialBackoffRetryPolicy.parseRetryAfter(header, now: now)
            guard let parsed else {
                Issue.record("future HTTP-date \(header) failed to parse (delta=\(deltaSeconds))")
                continue
            }
            #expect(parsed > 0)
            #expect(abs(parsed - deltaSeconds) <= 1.0)
        }
    }

    @Test("HTTP-date in the past returns nil", arguments: seeds)
    func httpDatePastReturnsNil(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        for _ in 0..<300 {
            let deltaSeconds = TimeInterval(Int(rng.next() % 86_400) + 1)
            let past = now.addingTimeInterval(-deltaSeconds)
            let header = formatter.string(from: past)
            #expect(
                ExponentialBackoffRetryPolicy.parseRetryAfter(header, now: now) == nil,
                "past HTTP-date \(header) parsed unexpectedly"
            )
        }
    }

    @Test(
        "contextual shouldRetry emits .retryAfter on 429/503 and 3xx with parseable header",
        arguments: seeds
    )
    func contextualShouldRetryRoutesByStatusAndHeader(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let policy = ExponentialBackoffRetryPolicy(maxRetries: 5, retryDelay: 1)
        let url = URL(string: "https://retry.example.com/path")!
        let candidateStatuses: [Int] = [200, 301, 400, 401, 408, 429, 500, 502, 503, 504]
        for _ in 0..<500 {
            let status = candidateStatuses[Int(rng.next() % UInt64(candidateStatuses.count))]
            let includeHeader = (rng.next() & 1) == 1
            let headerSeconds = Int(rng.next() % 30)
            let headers: [String: String]? = includeHeader ? ["Retry-After": "\(headerSeconds)"] : nil
            let httpResponse = try #require(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)
            )
            let networkResponse = Response(
                statusCode: status,
                data: Data(),
                request: URLRequest(url: url),
                response: httpResponse
            )
            let decision = policy.shouldRetry(
                error: .statusCode(networkResponse),
                retryIndex: 0,
                request: URLRequest(url: url),
                response: httpResponse
            )
            let expectedDecision: RetryDecision
            // RFC 9110 §10.2.3 lists Retry-After as applicable to 3xx in
            // addition to 429/503; the policy honors all three classes.
            let honorsRetryAfter = (300...399).contains(status) || status == 429 || status == 503
            if honorsRetryAfter, includeHeader {
                expectedDecision = .retryAfter(TimeInterval(headerSeconds))
            } else if status == 408 || status == 429 || (500...599).contains(status) {
                expectedDecision = .retry
            } else {
                expectedDecision = .noRetry
            }

            if decision != expectedDecision {
                Issue.record(
                    "expected \(expectedDecision) for status \(status), includeHeader=\(includeHeader), got \(decision)"
                )
            }
            if case .retryAfter(let seconds) = decision {
                #expect(seconds == TimeInterval(headerSeconds))
            }
        }
    }

    @Test("non-idempotent POST without idempotency-key never retries", arguments: seeds)
    func nonIdempotentPostNeverRetries(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let policy = ExponentialBackoffRetryPolicy(maxRetries: 5, retryDelay: 1)
        let url = URL(string: "https://retry.example.com/path")!
        for _ in 0..<200 {
            let status = [429, 503].randomElement(using: &rng)!
            let httpResponse = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "\(rng.next() % 30)"]
                )
            )
            let networkResponse = Response(
                statusCode: status,
                data: Data(),
                request: URLRequest(url: url),
                response: httpResponse
            )
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let decision = policy.shouldRetry(
                error: .statusCode(networkResponse),
                retryIndex: 0,
                request: request,
                response: httpResponse
            )
            #expect(decision == .noRetry, "POST without idempotency-key produced \(decision)")
        }
    }
}

/// Deterministic 64-bit PRNG (SplitMix64) so fuzz iterations are
/// reproducible across runs and Swift versions.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
