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
        let response = try #require(HTTPURLResponse(
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
        let response = try #require(HTTPURLResponse(
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
        let response = try #require(HTTPURLResponse(
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
}
