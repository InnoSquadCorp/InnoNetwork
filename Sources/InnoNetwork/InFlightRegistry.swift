import Foundation


/// Tracks the cancel handlers for requests currently dispatched through a
/// ``DefaultNetworkClient``.
///
/// Each entry is a `@Sendable () -> Void` closure that calls `cancel()` on the
/// inner work `Task`, so a single `cancelAll()` invocation can interrupt every
/// request in flight without the client having to expose its `Task`s. The
/// registry is package-scoped because external consumers should drive
/// cancellation through ``DefaultNetworkClient/cancelAll()`` rather than poke
/// at this storage directly.
package actor InFlightRegistry {
    private var cancelHandlers: [UUID: @Sendable () -> Void] = [:]

    package init() {}

    package func register(id: UUID, cancelHandler: @escaping @Sendable () -> Void) {
        cancelHandlers[id] = cancelHandler
    }

    package func deregister(id: UUID) {
        cancelHandlers.removeValue(forKey: id)
    }

    package func cancelAll() {
        let handlers = Array(cancelHandlers.values)
        cancelHandlers.removeAll()
        for handler in handlers {
            handler()
        }
    }

    package var inFlightCount: Int {
        cancelHandlers.count
    }
}
