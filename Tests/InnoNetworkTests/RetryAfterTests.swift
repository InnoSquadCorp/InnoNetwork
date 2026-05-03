import Foundation
import Testing

@testable import InnoNetwork

@Suite("Retry-After Parsing Tests")
struct RetryAfterParsingTests {

    @Test("Delta-seconds parses to TimeInterval")
    func deltaSecondsParses() {
        #expect(ExponentialBackoffRetryPolicy.parseRetryAfter("5") == 5)
        #expect(ExponentialBackoffRetryPolicy.parseRetryAfter("120") == 120)
        #expect(ExponentialBackoffRetryPolicy.parseRetryAfter("0") == 0)
        #expect(ExponentialBackoffRetryPolicy.parseRetryAfter("  3  ") == 3)
    }

    @Test("Negative or non-numeric delta is rejected")
    func negativeOrJunkRejected() {
        #expect(ExponentialBackoffRetryPolicy.parseRetryAfter("-5") == nil)
        #expect(ExponentialBackoffRetryPolicy.parseRetryAfter("five") == nil)
        #expect(ExponentialBackoffRetryPolicy.parseRetryAfter("") == nil)
    }

    @Test("HTTP-date in the future returns the elapsed seconds")
    func httpDateInFuture() {
        let now = Date(timeIntervalSince1970: 0)
        // 60 seconds after the reference now.
        let header = "Thu, 01 Jan 1970 00:01:00 GMT"
        let seconds = ExponentialBackoffRetryPolicy.parseRetryAfter(header, now: now)
        #expect(seconds == 60)
    }

    @Test("HTTP-date in the past returns nil")
    func httpDateInPast() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let header = "Thu, 01 Jan 1970 00:00:00 GMT"
        #expect(ExponentialBackoffRetryPolicy.parseRetryAfter(header, now: now) == nil)
    }

    @Test("Asctime HTTP-date variants parse")
    func asctimeVariantsParse() {
        let now = Date(timeIntervalSince1970: 0)
        let doubleSpaceDay = ExponentialBackoffRetryPolicy.parseRetryAfter("Sun Nov  6 08:49:37 1994", now: now)
        let zeroPaddedDay = ExponentialBackoffRetryPolicy.parseRetryAfter("Sun Nov 06 08:49:37 1994", now: now)
        #expect(doubleSpaceDay != nil)
        #expect(zeroPaddedDay != nil)
        #expect(doubleSpaceDay == zeroPaddedDay)
    }

    @Test("Contextual shouldRetry returns .retryAfter on 429 with Retry-After: 3")
    func retryAfterRoutesThroughContextualOverload() throws {
        let policy = ExponentialBackoffRetryPolicy(maxRetries: 5, retryDelay: 1)
        let url = URL(string: "https://example.com")!
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "3"]
            ))
        let networkResponse = Response(
            statusCode: 429,
            data: Data(),
            request: URLRequest(url: url),
            response: response
        )
        let decision = policy.shouldRetry(
            error: .statusCode(networkResponse),
            retryIndex: 0,
            request: URLRequest(url: url),
            response: response
        )
        #expect(decision == .retryAfter(3))
    }

    @Test("Contextual shouldRetry falls back to .retry when Retry-After is missing")
    func missingRetryAfterFallsBack() throws {
        let policy = ExponentialBackoffRetryPolicy(maxRetries: 5, retryDelay: 1)
        let url = URL(string: "https://example.com")!
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            ))
        let networkResponse = Response(
            statusCode: 503,
            data: Data(),
            request: URLRequest(url: url),
            response: response
        )
        let decision = policy.shouldRetry(
            error: .statusCode(networkResponse),
            retryIndex: 0,
            request: URLRequest(url: url),
            response: response
        )
        #expect(decision == .retry)
    }

    @Test("Contextual shouldRetry returns .noRetry when retryIndex hits maxRetries")
    func capStopsRetry() throws {
        let policy = ExponentialBackoffRetryPolicy(maxRetries: 1, retryDelay: 1)
        let url = URL(string: "https://example.com")!
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "10"]
            ))
        let networkResponse = Response(
            statusCode: 429,
            data: Data(),
            request: URLRequest(url: url),
            response: response
        )
        let decision = policy.shouldRetry(
            error: .statusCode(networkResponse),
            retryIndex: 1,
            request: URLRequest(url: url),
            response: response
        )
        #expect(decision == .noRetry)
    }

    @Test("Retry-After: Int.max clamps to policy ceiling instead of producing year-scale waits")
    func absurdRetryAfterIsClamped() throws {
        // RFC 9110 lets servers return any non-negative integer; without a
        // clamp, `Retry-After: 9223372036854775807` would pin the retry to
        // a sleep of ~292 billion years. The parser must respect the
        // policy's maxRetryAfterDelay (or maxDelay when unset).
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 3,
            retryDelay: 1,
            maxRetryAfterDelay: 60,
            maxDelay: 30
        )
        let url = URL(string: "https://example.com")!
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "9223372036854775807"]
            ))
        let networkResponse = Response(
            statusCode: 429,
            data: Data(),
            request: URLRequest(url: url),
            response: response
        )
        let decision = policy.shouldRetry(
            error: .statusCode(networkResponse),
            retryIndex: 0,
            request: URLRequest(url: url),
            response: response
        )
        #expect(decision == .retryAfter(60))
    }

    @Test("Retry-After honored on 3xx redirect status per RFC 9110")
    func retryAfterHonoredOn3xx() throws {
        // RFC 9110 §10.2.3 lists Retry-After as applicable to 3xx
        // redirects; custom redirect policies that surface the response
        // (rather than auto-following) must still observe the hint.
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 3,
            retryDelay: 1,
            idempotencyPolicy: .methodAgnostic
        )
        let url = URL(string: "https://example.com")!
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Retry-After": "7"]
            ))
        let networkResponse = Response(
            statusCode: 503,
            data: Data(),
            request: URLRequest(url: url),
            response: response
        )
        let decision = policy.shouldRetry(
            error: .statusCode(networkResponse),
            retryIndex: 0,
            request: URLRequest(url: url),
            response: response
        )
        #expect(decision == .retryAfter(7))
    }

    @Test("Coordinator safety net: non-idempotent POST + .timeout downgrades to .noRetry")
    func coordinatorSafetyNetForPostTimeout() async throws {
        // Even when a custom policy elects to retry, the coordinator must
        // not auto-retry POST/PATCH timeouts that lack an Idempotency-Key.
        // A timed-out write may have already succeeded server-side, so
        // retrying without an idempotency anchor risks duplicate writes
        // (e.g. duplicate payments).
        struct AlwaysRetryPolicy: RetryPolicy {
            let maxRetries = 3
            let maxTotalRetries = 3
            let retryDelay: TimeInterval = 0
            func shouldRetry(
                error: NetworkError,
                retryIndex: Int,
                request: URLRequest?,
                response: HTTPURLResponse?
            ) -> RetryDecision {
                .retry
            }
        }

        let url = URL(string: "https://example.com/charge")!
        let request: URLRequest = {
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            // No Idempotency-Key header — the safety net must engage.
            return r
        }()

        let eventHub = NetworkEventHub()
        let coordinator = RetryCoordinator(eventHub: eventHub)

        let attempts = OSAllocatedUnfairLockBox(value: 0)
        do {
            _ = try await coordinator.execute(
                retryPolicy: AlwaysRetryPolicy(),
                networkMonitor: nil,
                requestID: UUID(),
                eventObservers: []
            ) { _, _ in
                attempts.withLock { $0 += 1 }
                throw RequestExecutionFailure(
                    error: .timeout(reason: .requestTimeout),
                    request: request
                )
            }
            Issue.record("Expected timeout to surface without retry")
        } catch let error as NetworkError {
            if case .timeout = error {
                // expected
            } else {
                Issue.record("Expected .timeout, got \(error)")
            }
        }
        let totalAttempts = attempts.withLock { $0 }
        #expect(totalAttempts == 1, "POST timeout without Idempotency-Key must not auto-retry; got \(totalAttempts)")
    }

    @Test("Coordinator safety net: POST + .timeout + Idempotency-Key still retries")
    func coordinatorSafetyNetSkippedWhenIdempotencyKeyPresent() async throws {
        // The safety net is keyed on the absence of `Idempotency-Key`;
        // when the caller has anchored the request, the policy's verdict
        // wins.
        struct AlwaysRetryPolicy: RetryPolicy {
            let maxRetries = 1
            let maxTotalRetries = 1
            let retryDelay: TimeInterval = 0
            func shouldRetry(
                error: NetworkError,
                retryIndex: Int,
                request: URLRequest?,
                response: HTTPURLResponse?
            ) -> RetryDecision {
                .retry
            }
        }

        let url = URL(string: "https://example.com/charge")!
        let request: URLRequest = {
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue("idem-1", forHTTPHeaderField: "Idempotency-Key")
            return r
        }()

        let eventHub = NetworkEventHub()
        let coordinator = RetryCoordinator(eventHub: eventHub)

        let attempts = OSAllocatedUnfairLockBox(value: 0)
        do {
            _ = try await coordinator.execute(
                retryPolicy: AlwaysRetryPolicy(),
                networkMonitor: nil,
                requestID: UUID(),
                eventObservers: []
            ) { _, _ in
                attempts.withLock { $0 += 1 }
                throw RequestExecutionFailure(
                    error: .timeout(reason: .requestTimeout),
                    request: request
                )
            }
            Issue.record("Expected timeout to surface after retry budget exhausted")
        } catch let error as NetworkError {
            if case .timeout = error {
                // expected
            } else {
                Issue.record("Expected .timeout, got \(error)")
            }
        }
        let totalAttempts = attempts.withLock { $0 }
        #expect(totalAttempts == 2, "POST timeout WITH Idempotency-Key must still retry once; got \(totalAttempts)")
    }
}

import os

/// Minimal `OSAllocatedUnfairLock` wrapper used by the C16 regression
/// tests so the integer counter can be mutated from the `@Sendable`
/// operation closure without an extra actor hop.
private struct OSAllocatedUnfairLockBox<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(value: Value) { self.lock = OSAllocatedUnfairLock(initialState: value) }

    func withLock<Result: Sendable>(_ body: @Sendable (inout Value) -> Result) -> Result {
        lock.withLock(body)
    }
}
