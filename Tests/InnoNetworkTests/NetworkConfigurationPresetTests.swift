import Foundation
import Testing

@testable import InnoNetwork

@Suite("Network configuration presets")
struct NetworkConfigurationPresetTests {
    @Test("Package initializer caps responses at 5 MiB unless explicitly overridden")
    func packageInitializerCapsResponsesAtFiveMiB() {
        let baseURL = URL(string: "https://api.example.com")!
        let bounded = NetworkConfiguration(baseURL: baseURL)
        let explicitlyUnbounded = NetworkConfiguration(
            baseURL: baseURL,
            responseBodyBufferingPolicy: .streaming(maxBytes: nil)
        )

        #expect(
            bounded.responseBodyBufferingPolicy
                == .streaming(maxBytes: Int64(5 * 1024 * 1024))
        )
        #expect(explicitlyUnbounded.responseBodyBufferingPolicy == .streaming(maxBytes: nil))
    }

    @Test("Safe and advanced presets cap inline responses at 5 MiB")
    func presetsCapInlineResponsesAtFiveMiB() {
        let baseURL = URL(string: "https://api.example.com")!
        let safe = NetworkConfiguration.safeDefaults(baseURL: baseURL)
        let advanced = NetworkConfiguration.advanced(baseURL: baseURL)
        let expectedPolicy = ResponseBodyBufferingPolicy.streaming(
            maxBytes: Int64(5 * 1024 * 1024)
        )

        #expect(safe.responseBodyBufferingPolicy == expectedPolicy)
        #expect(advanced.responseBodyBufferingPolicy == expectedPolicy)
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
        #expect(buffered.responseBodyBufferingPolicy == .buffered(maxBytes: nil))
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
                eventObservers: [TestNetworkEventObserver()]
            )
        )

        #expect(configuration.eventObservers.count == 1)
        #expect(configuration.baseURL == baseURL)
        #expect(configuration.retryPolicy == nil)
        #expect(configuration.circuitBreakerPolicy == nil)
    }
}

private struct TestNetworkEventObserver: NetworkEventObserving {
    func handle(_ event: NetworkEvent) async {
        _ = event
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
