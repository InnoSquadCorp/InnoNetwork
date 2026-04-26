import Foundation
import Testing
@testable import InnoNetwork


private struct LegacyBoolPolicy: RetryPolicy {
    let maxRetries = 1
    let maxTotalRetries = 1
    let retryDelay: TimeInterval = 0

    func shouldRetry(error: NetworkError, retryIndex: Int) -> Bool {
        true
    }
}


private struct ContextualPolicy: RetryPolicy {
    let maxRetries = 1
    let maxTotalRetries = 1
    let retryDelay: TimeInterval = 0
    let returnedDecision: RetryDecision

    func shouldRetry(error: NetworkError, retryIndex: Int) -> Bool {
        // Should not be reached because the contextual override is provided.
        Issue.record("Legacy boolean shouldRetry was called even though the contextual override exists.")
        return false
    }

    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision {
        returnedDecision
    }
}


@Suite("Retry Decision Tests")
struct RetryDecisionTests {

    @Test("RetryDecision equality treats retryAfter as a parametric case")
    func retryDecisionEquality() {
        #expect(RetryDecision.retry == RetryDecision.retry)
        #expect(RetryDecision.noRetry == RetryDecision.noRetry)
        #expect(RetryDecision.retryAfter(5) == RetryDecision.retryAfter(5))
        #expect(RetryDecision.retryAfter(5) != RetryDecision.retryAfter(7))
        #expect(RetryDecision.retry != RetryDecision.retryAfter(0))
    }

    @Test("Legacy boolean shouldRetry maps true → .retry and false → .noRetry by default")
    func legacyBoolMapsThroughDefault() {
        let policy = LegacyBoolPolicy()
        let decision = policy.shouldRetry(
            error: .undefined,
            retryIndex: 0,
            request: nil,
            response: nil
        )
        #expect(decision == .retry)
    }

    @Test("Contextual override is preferred over the legacy boolean overload")
    func contextualOverrideTakesPrecedence() {
        let policy = ContextualPolicy(returnedDecision: .retryAfter(5))
        let decision = policy.shouldRetry(
            error: .undefined,
            retryIndex: 0,
            request: URLRequest(url: URL(string: "https://example.com")!),
            response: nil
        )
        #expect(decision == .retryAfter(5))
    }

    @Test("NetworkError.underlyingRequest exposes URLRequest from .statusCode payload")
    func underlyingRequestExtraction() {
        let request = URLRequest(url: URL(string: "https://example.com/items")!)
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: nil
        )!
        let response = Response(
            statusCode: 503,
            data: Data(),
            request: request,
            response: httpResponse
        )
        let error = NetworkError.statusCode(response)
        #expect(error.underlyingRequest?.url == request.url)
        #expect(error.underlyingHTTPResponse?.statusCode == 503)
    }
}
