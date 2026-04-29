import Foundation

package final class RequestExecutionRuntime: Sendable {
    let refreshCoordinator: RefreshTokenCoordinator?
    let requestCoalescer: RequestCoalescer
    let circuitBreakers: CircuitBreakerRegistry
    let inFlight: InFlightRegistry

    init(configuration: NetworkConfiguration, inFlight: InFlightRegistry) {
        self.refreshCoordinator = configuration.refreshTokenPolicy.map(RefreshTokenCoordinator.init(policy:))
        self.requestCoalescer = RequestCoalescer()
        self.circuitBreakers = CircuitBreakerRegistry()
        self.inFlight = inFlight
    }
}
