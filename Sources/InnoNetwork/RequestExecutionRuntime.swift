import Foundation

package final class RequestExecutionRuntime: Sendable {
    let refreshCoordinator: RefreshTokenCoordinator?
    let requestCoalescer: RequestCoalescer
    let circuitBreakers: CircuitBreakerRegistry

    init(configuration: NetworkConfiguration) {
        self.refreshCoordinator = configuration.refreshTokenPolicy.map(RefreshTokenCoordinator.init(policy:))
        self.requestCoalescer = RequestCoalescer()
        self.circuitBreakers = CircuitBreakerRegistry()
    }
}
