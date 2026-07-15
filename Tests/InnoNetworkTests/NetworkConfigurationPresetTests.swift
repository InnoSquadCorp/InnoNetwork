import Foundation
import Testing

@testable import InnoNetwork

@Suite("Network configuration presets")
struct NetworkConfigurationPresetTests {
    @Test("Safe and advanced presets cap inline responses at 5 MiB")
    func presetsCapInlineResponsesAtFiveMiB() {
        let baseURL = URL(string: "https://api.example.com")!
        let safe = NetworkConfiguration.safeDefaults(baseURL: baseURL)
        let advanced = NetworkConfiguration.advanced(baseURL: baseURL)

        #expect(safe.responseBodyBufferingPolicy == .streaming(maxBytes: 5 * 1024 * 1024))
        #expect(advanced.responseBodyBufferingPolicy == .streaming(maxBytes: 5 * 1024 * 1024))
    }

    @Test("Advanced configuration preserves explicit unbounded buffering opt-outs")
    func advancedPreservesExplicitUnboundedBuffering() {
        let baseURL = URL(string: "https://api.example.com")!
        let streaming = NetworkConfiguration.advanced(
            baseURL: baseURL,
            resilience: ResiliencePack(bodyBuffering: .streaming(maxBytes: nil))
        )
        let buffered = NetworkConfiguration.advanced(
            baseURL: baseURL,
            resilience: ResiliencePack(bodyBuffering: .buffered(maxBytes: nil))
        )

        #expect(streaming.responseBodyBufferingPolicy == .streaming(maxBytes: nil))
        #expect(streaming.responseBodyLimit == nil)
        #expect(buffered.responseBodyBufferingPolicy == .buffered(maxBytes: nil))
        #expect(buffered.responseBodyLimit == nil)
    }

    @Test("recommendedForProduction enables conservative resilience defaults")
    func recommendedForProductionEnablesConservativeResilienceDefaults() {
        let configuration = NetworkConfiguration.recommendedForProduction(
            baseURL: URL(string: "https://api.example.com")!
        )

        #expect(configuration.retryPolicy != nil)
        #expect(configuration.circuitBreakerPolicy != nil)
        #expect(configuration.idempotencyKeyPolicy.methods == [.post, .put, .patch, .delete])
        #expect(configuration.responseBodyBufferingPolicy.maxBytes == Int64(5 * 1024 * 1024))
    }

    // MARK: - Configuration packs

    @Test("ResiliencePack composes retry, circuit breaker, and coalescing policies")
    func resiliencePackComposesPolicies() {
        let baseURL = URL(string: "https://api.example.com")!
        let policy = ExponentialBackoffRetryPolicy(maxRetries: 7)
        let configuration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            resilience: ResiliencePack(
                retry: policy,
                coalescing: .getOnly,
                circuitBreaker: CircuitBreakerPolicy(failureThreshold: 3)
            )
        )

        #expect(configuration.retryPolicy != nil)
        #expect(configuration.circuitBreakerPolicy != nil)
        #expect(configuration.requestCoalescingPolicy == .getOnly)
        #expect(configuration.baseURL == baseURL)
        #expect(configuration.refreshTokenPolicy == nil)
    }

    @Test("CachePack supplies the response cache")
    func cachePackSuppliesResponseCache() {
        let baseURL = URL(string: "https://api.example.com")!
        let cache = InMemoryResponseCache()
        let configuration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            cache: CachePack(responseCache: cache)
        )

        #expect(configuration.responseCache != nil)
        #expect(configuration.baseURL == baseURL)
        #expect(configuration.retryPolicy == nil)
        #expect(configuration.circuitBreakerPolicy == nil)
    }

    @Test("AuthPack supplies the refresh token policy")
    func authPackSuppliesRefreshTokenPolicy() {
        let baseURL = URL(string: "https://api.example.com")!
        let refresh = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: { "new" }
        )
        let configuration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            auth: AuthPack(refreshToken: refresh)
        )

        #expect(configuration.refreshTokenPolicy != nil)
        #expect(configuration.baseURL == baseURL)
        #expect(configuration.retryPolicy == nil)
        #expect(configuration.circuitBreakerPolicy == nil)
    }

    @Test("ResiliencePack supplies the custom execution policy chain")
    func resiliencePackSuppliesCustomExecutionPolicies() {
        let baseURL = URL(string: "https://api.example.com")!
        let configuration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            resilience: ResiliencePack(
                customExecutionPolicies: [PassthroughExecutionPolicy()]
            )
        )

        #expect(configuration.customExecutionPolicies.count == 1)
        #expect(configuration.baseURL == baseURL)
        #expect(configuration.retryPolicy == nil)
        #expect(configuration.circuitBreakerPolicy == nil)
    }

    @Test("ObservabilityPack supplies network event observers")
    func observabilityPackSuppliesEventObservers() {
        let baseURL = URL(string: "https://api.example.com")!
        let configuration = NetworkConfiguration.advanced(
            baseURL: baseURL,
            observability: ObservabilityPack(
                eventObservers: [NoOpNetworkEventObserver()]
            )
        )

        #expect(configuration.eventObservers.count == 1)
        #expect(configuration.baseURL == baseURL)
        #expect(configuration.retryPolicy == nil)
        #expect(configuration.circuitBreakerPolicy == nil)
    }
}

private struct PassthroughExecutionPolicy: RequestExecutionPolicy {
    func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        _ = context
        _ = input
        return try await next.execute()
    }
}
