import Foundation
import Testing

@testable import InnoNetwork

@Suite("CircuitBreakerPolicy validation")
struct CircuitBreakerPolicyValidationTests {

    @Test("Validating initializer rejects non-positive windowSize")
    func rejectsNonPositiveWindow() {
        #expect(throws: CircuitBreakerPolicy.ConfigurationError.self) {
            _ = try CircuitBreakerPolicy(
                validatedFailureThreshold: 1,
                windowSize: 0,
                resetAfter: .seconds(1),
                maxResetAfter: .seconds(60)
            )
        }
    }

    @Test("Validating initializer rejects threshold > windowSize")
    func rejectsThresholdAboveWindow() {
        #expect(throws: CircuitBreakerPolicy.ConfigurationError.self) {
            _ = try CircuitBreakerPolicy(
                validatedFailureThreshold: 5,
                windowSize: 3,
                resetAfter: .seconds(1),
                maxResetAfter: .seconds(60)
            )
        }
    }

    @Test("Validating initializer rejects maxReset < reset")
    func rejectsMaxBelowReset() {
        #expect(throws: CircuitBreakerPolicy.ConfigurationError.self) {
            _ = try CircuitBreakerPolicy(
                validatedFailureThreshold: 1,
                windowSize: 1,
                resetAfter: .seconds(60),
                maxResetAfter: .seconds(30)
            )
        }
    }

    @Test("Silent-clamp initializer still applies normalization")
    func silentClampStillWorks() {
        let policy = CircuitBreakerPolicy(
            failureThreshold: 100,
            windowSize: 3,
            resetAfter: .seconds(-1),
            maxResetAfter: .seconds(-2)
        )
        #expect(policy.windowSize == 3)
        #expect(policy.failureThreshold == 3)
        #expect(policy.resetAfter == .zero)
        #expect(policy.maxResetAfter == .zero)
    }
}


@Suite("CircuitBreakerRegistry hardening")
struct CircuitBreakerRegistryHardeningTests {

    @Test("Same host on different ports tracks independent state")
    func portIsolatesState() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
        let request80 = URLRequest(url: URL(string: "http://api.example.com:8080/users")!)
        let request443 = URLRequest(url: URL(string: "https://api.example.com/users")!)

        await registry.recordStatus(request: request80, policy: policy, statusCode: 500)

        // 8080 is open, 443 still closed
        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request80, policy: policy)
        }
        try await registry.prepare(request: request443, policy: policy)
    }

    @Test("Different schemes on the same host:port still isolate state")
    func schemeIsolatesState() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
        let httpRequest = URLRequest(url: URL(string: "http://api.example.com:443/x")!)
        let httpsRequest = URLRequest(url: URL(string: "https://api.example.com:443/x")!)

        await registry.recordStatus(request: httpRequest, policy: policy, statusCode: 500)
        try await registry.prepare(request: httpsRequest, policy: policy)
    }

    @Test("Hysteresis requires multiple successful probes before closing")
    func hysteresisRequiresMultipleProbes() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(
            failureThreshold: 1,
            windowSize: 1,
            resetAfter: .zero,
            maxResetAfter: .seconds(60),
            numberOfProbesRequiredToClose: 2
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)

        // First probe — admitted because resetAfter is .zero.
        try await registry.prepare(request: request, policy: policy)
        await registry.recordStatus(request: request, policy: policy, statusCode: 200)
        // Still half-open after a single success: a second probe must be admitted.
        try await registry.prepare(request: request, policy: policy)
        await registry.recordStatus(request: request, policy: policy, statusCode: 200)

        // After two successes the breaker is closed; further requests proceed.
        try await registry.prepare(request: request, policy: policy)
    }

    @Test("Cancellation in closed state preserves the rolling window")
    func cancellationPreservesClosedWindow() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 2, windowSize: 2)
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        await registry.recordCancellation(request: request, policy: policy)
        // The window must still hold the prior failure; one more 500 trips.
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)

        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request, policy: policy)
        }
    }

    @Test("DNS lookup failure does not open the breaker by default")
    func dnsFailureNotCountable() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        let dns = URLError(.dnsLookupFailed)
        await registry.recordFailure(request: request, policy: policy, error: dns)

        try await registry.prepare(request: request, policy: policy)
    }

    @Test("DNS failures count when countsTransportSecurityFailures is true")
    func dnsCountableWhenOptedIn() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(
            failureThreshold: 1,
            windowSize: 1,
            countsTransportSecurityFailures: true
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        let dns = URLError(.dnsLookupFailed)
        await registry.recordFailure(request: request, policy: policy, error: dns)

        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request, policy: policy)
        }
    }

    @Test("Trust evaluation failure does not count by default")
    func trustEvaluationNotCountable() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        let trustError = NetworkError.trustEvaluationFailed(.systemTrustEvaluationFailed(reason: "bad"))

        await registry.recordFailure(request: request, policy: policy, error: trustError)

        try await registry.prepare(request: request, policy: policy)
    }
}
