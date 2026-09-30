import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("Circuit backoff arithmetic")
struct CircuitBackoffArithmeticTests {
    @Test func durationDoublingCapsBeforeOverflowAndKeepsPrecision() {
        let large = Duration.seconds(Int64.max) * 2
        #expect(CircuitBreakerRegistry.cappedBackoff(resetAfter: large, maximum: large) == large)
        #expect(CircuitBreakerRegistry.cappedBackoff(resetAfter: large, maximum: large * 2) == large * 2)
        #expect(CircuitBreakerRegistry.cappedBackoff(resetAfter: large, maximum: .seconds(1)) == .seconds(1))
        #expect(CircuitBreakerRegistry.cappedBackoff(resetAfter: .zero, maximum: large) == .zero)
        #expect(
            CircuitBreakerRegistry.cappedBackoff(resetAfter: .nanoseconds(1), maximum: .seconds(1))
                == .nanoseconds(2))
        #expect(CircuitBreakerRegistry.cappedBackoff(resetAfter: .seconds(2), maximum: .seconds(3)) == .seconds(3))
    }

    @Test(arguments: [1.0, 1e16])
    func failedProbeKeepsTheDoubledOpenBudget(seconds: Double) async throws {
        let clock = TestClock()
        let registry = CircuitBreakerRegistry(clock: clock)
        let reset = Duration.seconds(seconds)
        let policy = CircuitBreakerPolicy(
            failureThreshold: 1, windowSize: 1, resetAfter: reset, maxResetAfter: reset * 2)
        let request = URLRequest(url: URL(string: "https://example.test/circuit")!)
        await registry.recordStatus(request: request, policy: policy, statusCode: 503)
        clock.advance(by: reset)
        let probe = try #require(try await registry.prepare(request: request, policy: policy))
        await registry.recordStatus(request: request, policy: policy, statusCode: 503, probe: probe)

        clock.advance(by: reset)
        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request, policy: policy)
        }
        clock.advance(by: reset)
        let nextProbe = try #require(try await registry.prepare(request: request, policy: policy))
        await registry.recordStatus(request: request, policy: policy, statusCode: 200, probe: nextProbe)
        #expect(try await registry.prepare(request: request, policy: policy) == nil)
    }

    @Test func openingAnExtremeDurationDoesNotReadNarrowComponents() async throws {
        let clock = TestClock()
        let registry = CircuitBreakerRegistry(clock: clock)
        let reset = Duration.seconds(Int64.max) * 2
        let policy = CircuitBreakerPolicy(
            failureThreshold: 1, windowSize: 1, resetAfter: reset, maxResetAfter: reset)
        let request = URLRequest(url: URL(string: "https://example.test/circuit")!)
        await registry.recordStatus(request: request, policy: policy, statusCode: 503)
        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request, policy: policy)
        }
    }
}
