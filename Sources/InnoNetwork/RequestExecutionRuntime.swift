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
        let now: @Sendable () -> Date = { clock.now() }
        self.refreshCoordinator = configuration.refreshTokenPolicy.map {
            RefreshTokenCoordinator(policy: $0, now: now)
        }
        self.requestCoalescer = RequestCoalescer(now: now)
        self.circuitBreakers = CircuitBreakerRegistry(clock: clock)
        self.inFlight = inFlight
        self.clock = clock
    }

    package func shutdown() async {
        await refreshCoordinator?.shutdown()
    }
}
