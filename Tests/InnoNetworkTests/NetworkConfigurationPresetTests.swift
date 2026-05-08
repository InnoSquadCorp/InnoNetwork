import Foundation
import Testing

@testable import InnoNetwork

@Suite("Network configuration presets")
struct NetworkConfigurationPresetTests {
    @Test("recommendedForProduction enables conservative resilience defaults")
    func recommendedForProductionEnablesConservativeResilienceDefaults() {
        let configuration = NetworkConfiguration.recommendedForProduction(
            baseURL: URL(string: "https://api.example.com")!
        )

        #expect(configuration.retryPolicy != nil)
        #expect(configuration.circuitBreakerPolicy != nil)
        #expect(configuration.idempotencyKeyPolicy.methods == [.post, .put, .patch, .delete])
        #expect(configuration.responseBodyBufferingPolicy.maxBytes == nil)
    }

    // MARK: - Fluent modifiers

    @Test("with(retry:) replaces only the retry policy and keeps every other field")
    func withRetryReplacesOnlyRetryPolicy() {
        let baseURL = URL(string: "https://api.example.com")!
        let original = NetworkConfiguration.safeDefaults(baseURL: baseURL)
        let policy = ExponentialBackoffRetryPolicy(maxRetries: 7)
        let updated = original.with(retry: policy)

        #expect(updated.retryPolicy != nil)
        #expect(updated.baseURL == original.baseURL)
        #expect(updated.timeout == original.timeout)
        #expect(updated.acceptableStatusCodes == original.acceptableStatusCodes)
    }

    @Test("with(retry: nil) detaches an existing retry policy")
    func withRetryNilDetachesPolicy() {
        let baseURL = URL(string: "https://api.example.com")!
        let production = NetworkConfiguration.recommendedForProduction(baseURL: baseURL)
        #expect(production.retryPolicy != nil)

        let detached = production.with(retry: nil)
        #expect(detached.retryPolicy == nil)
        #expect(detached.circuitBreakerPolicy != nil)
    }

    @Test("Modifiers chain compositionally")
    func modifiersChainCompositionally() {
        let baseURL = URL(string: "https://api.example.com")!
        let configuration = NetworkConfiguration
            .safeDefaults(baseURL: baseURL)
            .with(retry: ExponentialBackoffRetryPolicy())
            .with(circuitBreaker: CircuitBreakerPolicy(failureThreshold: 3))
            .with(coalescing: .getOnly)

        #expect(configuration.retryPolicy != nil)
        #expect(configuration.circuitBreakerPolicy != nil)
        #expect(configuration.requestCoalescingPolicy == .getOnly)
    }

    @Test("with(circuitBreaker:) replaces only the breaker policy")
    func withCircuitBreakerReplacesOnlyBreaker() {
        let baseURL = URL(string: "https://api.example.com")!
        let original = NetworkConfiguration.safeDefaults(baseURL: baseURL)
        let breaker = CircuitBreakerPolicy(failureThreshold: 9)

        let updated = original.with(circuitBreaker: breaker)

        #expect(updated.circuitBreakerPolicy != nil)
        #expect(updated.retryPolicy == nil)
        #expect(updated.refreshTokenPolicy == nil)
    }
}
