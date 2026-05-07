import Foundation

/// Rejects transport attempts when the device is known to be
/// offline, instead of letting the request burn the URLSession
/// timeout budget on an unsatisfied path.
///
/// `ReachabilityCheckExecutionPolicy` consults a
/// ``NetworkMonitoring`` source before forwarding to the rest of
/// the ``RequestExecutionPolicy`` chain. If the snapshot reports
/// `.unsatisfied`, the policy throws an early
/// ``NetworkError`` so the caller sees an immediate failure
/// instead of a 30-second timeout. The ``Mode`` switch lets the
/// policy log-only without rejecting — useful for staged
/// rollouts where the team wants telemetry before tightening the
/// gate.
///
/// ```swift
/// let monitor = NetworkMonitor.shared
/// let reachability = ReachabilityCheckExecutionPolicy(monitor: monitor)
///
/// let configuration = NetworkConfiguration.advanced(baseURL: baseURL) { builder in
///     builder.customExecutionPolicies.append(reachability)
/// }
/// ```
///
/// `.requiresConnection` (VPN / proxy still negotiating) and a
/// `nil` snapshot (no path observed yet) fall through — those
/// states are not definitively offline. Only `.unsatisfied`
/// triggers the rejection.
///
/// The policy reports `NetworkError.invalidRequestConfiguration` for
/// rejected requests in the 4.x line. The 5.0 release introduces a
/// dedicated `.offline` case as part of the `NetworkError` ledger
/// consolidation; the policy will swap the case at that point with
/// a deprecated alias preserving source compatibility.
public struct ReachabilityCheckExecutionPolicy: RequestExecutionPolicy {
    /// Behaviour switch for offline observations.
    public enum Mode: Sendable, Equatable {
        /// Rejects requests with `NetworkError.invalidRequestConfiguration`
        /// when the snapshot reports `.unsatisfied`. Default.
        case requireOnline
        /// Lets the request continue regardless. Useful for early
        /// rollouts that want telemetry without altering behaviour.
        case warnOnly
    }

    public let monitor: any NetworkMonitoring
    public let mode: Mode

    public init(monitor: any NetworkMonitoring, mode: Mode = .requireOnline) {
        self.monitor = monitor
        self.mode = mode
    }

    public func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        if mode == .requireOnline {
            let snapshot = await monitor.currentSnapshot()
            if let snapshot, snapshot.status == .unsatisfied {
                throw NetworkError.invalidRequestConfiguration(
                    "Network is not reachable; refusing to dispatch."
                )
            }
        }
        return try await next.execute(input.request)
    }
}
