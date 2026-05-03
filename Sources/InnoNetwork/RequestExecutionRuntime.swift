import Foundation

package final class RequestExecutionRuntime: Sendable {
    let refreshCoordinator: RefreshTokenCoordinator?
    let requestCoalescer: RequestCoalescer
    let circuitBreakers: CircuitBreakerRegistry
    let inFlight: InFlightRegistry
    let clock: any InnoNetworkClock

    init(
        configuration: NetworkConfiguration,
        inFlight: InFlightRegistry,
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.refreshCoordinator = configuration.refreshTokenPolicy.map { RefreshTokenCoordinator(policy: $0) }
        self.requestCoalescer = RequestCoalescer()
        self.circuitBreakers = CircuitBreakerRegistry()
        self.inFlight = inFlight
        self.clock = clock
    }
}
