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
}
