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
    func withRetryReplacesOnlyRetryPolicy() async {
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
    func withRetryNilDetachesPolicy() async {
        let baseURL = URL(string: "https://api.example.com")!
        let production = NetworkConfiguration.recommendedForProduction(baseURL: baseURL)
        #expect(production.retryPolicy != nil)

        let detached = production.with(retry: nil)
        #expect(detached.retryPolicy == nil)
        #expect(detached.circuitBreakerPolicy != nil)
    }

    @Test("Modifiers chain compositionally")
    func modifiersChainCompositionally() async {
        let baseURL = URL(string: "https://api.example.com")!
        let configuration =
            NetworkConfiguration
            .safeDefaults(baseURL: baseURL)
            .with(retry: ExponentialBackoffRetryPolicy())
            .with(circuitBreaker: CircuitBreakerPolicy(failureThreshold: 3))
            .with(coalescing: .getOnly)

        #expect(configuration.retryPolicy != nil)
        #expect(configuration.circuitBreakerPolicy != nil)
        #expect(configuration.requestCoalescingPolicy == .getOnly)
    }

    @Test("with(circuitBreaker:) replaces only the breaker policy")
    func withCircuitBreakerReplacesOnlyBreaker() async {
        let baseURL = URL(string: "https://api.example.com")!
        let original = NetworkConfiguration.safeDefaults(baseURL: baseURL)
        let breaker = CircuitBreakerPolicy(failureThreshold: 9)

        let updated = original.with(circuitBreaker: breaker)

        #expect(updated.circuitBreakerPolicy != nil)
        #expect(updated.retryPolicy == nil)
        #expect(updated.refreshTokenPolicy == nil)
    }

    @Test("with(cache:) replaces only the response cache")
    func withCacheReplacesOnlyResponseCache() {
        let baseURL = URL(string: "https://api.example.com")!
        let original = NetworkConfiguration.safeDefaults(baseURL: baseURL)
        let cache = InMemoryResponseCache()

        let updated = original.with(cache: cache)

        #expect(updated.responseCache != nil)
        #expect(updated.baseURL == original.baseURL)
        #expect(updated.retryPolicy == nil)
        #expect(updated.circuitBreakerPolicy == nil)
    }

    @Test("with(refresh:) replaces only the refresh token policy")
    func withRefreshReplacesOnlyRefreshTokenPolicy() {
        let baseURL = URL(string: "https://api.example.com")!
        let original = NetworkConfiguration.safeDefaults(baseURL: baseURL)
        let refresh = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: { "new" }
        )

        let updated = original.with(refresh: refresh)

        #expect(updated.refreshTokenPolicy != nil)
        #expect(updated.baseURL == original.baseURL)
        #expect(updated.retryPolicy == nil)
        #expect(updated.circuitBreakerPolicy == nil)
    }

    @Test("with(executionPolicies:) replaces only the custom policy chain")
    func withExecutionPoliciesReplacesOnlyCustomPolicyChain() {
        let baseURL = URL(string: "https://api.example.com")!
        let original = NetworkConfiguration.safeDefaults(baseURL: baseURL)

        let updated = original.with(executionPolicies: [PassthroughExecutionPolicy()])

        #expect(updated.customExecutionPolicies.count == 1)
        #expect(updated.baseURL == original.baseURL)
        #expect(updated.retryPolicy == nil)
        #expect(updated.circuitBreakerPolicy == nil)
    }

    @Test("with(eventObservers:) replaces only network event observers")
    func withEventObserversReplacesOnlyEventObservers() {
        let baseURL = URL(string: "https://api.example.com")!
        let original = NetworkConfiguration.safeDefaults(baseURL: baseURL)

        let updated = original.with(eventObservers: [NoOpNetworkEventObserver()])

        #expect(updated.eventObservers.count == 1)
        #expect(updated.baseURL == original.baseURL)
        #expect(updated.retryPolicy == nil)
        #expect(updated.circuitBreakerPolicy == nil)
    }
}

private struct PassthroughExecutionPolicy: RequestExecutionPolicy {
    func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        _ = context
        return try await next.execute(input.request)
    }
}
