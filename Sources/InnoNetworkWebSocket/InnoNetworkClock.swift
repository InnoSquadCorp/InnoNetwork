import Foundation


/// Package-internal clock abstraction used by coordinators that schedule
/// time-based work (heartbeat cadence, reconnect backoff). Production code
/// uses `SystemClock`; tests can substitute a virtual-time implementation so
/// timing behavior is deterministic without relying on wall-clock sleeps.
package protocol InnoNetworkClock: Sendable {
    /// Suspends for the requested duration. Conforming types should honor
    /// task cancellation so coordinators can exit promptly when their enclosing
    /// task is cancelled.
    func sleep(for duration: Duration) async throws
}


/// Production-backed clock that defers to structured-concurrency
/// `Task.sleep(for:)`.
package struct SystemClock: InnoNetworkClock {
    package init() {}

    package func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
