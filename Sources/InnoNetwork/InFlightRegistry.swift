import Foundation
import os


/// Tracks the cancel handlers for requests currently dispatched through a
/// ``DefaultNetworkClient``.
///
/// Each entry is a `@Sendable () -> Void` closure that calls `cancel()` on the
/// inner work `Task`, so a single `cancelAll()` invocation can interrupt every
/// request in flight without the client having to expose its `Task`s. The
/// registry is package-scoped because external consumers should drive
/// cancellation through ``DefaultNetworkClient/cancelAll()`` rather than poke
/// at this storage directly.
package final class InFlightRegistry: Sendable {
    private let cancelHandlers = OSAllocatedUnfairLock<[UUID: @Sendable () -> Void]>(initialState: [:])

    package init() {}

    package func register(id: UUID, cancelHandler: @escaping @Sendable () -> Void) {
        cancelHandlers.withLock { $0[id] = cancelHandler }
    }

    package func deregister(id: UUID) {
        cancelHandlers.withLock { state in
            _ = state.removeValue(forKey: id)
        }
    }

    package func cancelAll() {
        let handlers = cancelHandlers.withLock { state in
            let handlers = Array(state.values)
            state.removeAll()
            return handlers
        }
        for handler in handlers {
            handler()
        }
    }

    package var inFlightCount: Int {
        cancelHandlers.withLock { $0.count }
    }
}


package final class TaskStartGate: Sendable {
    private struct State {
        var isOpen = false
        var continuations: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    package init() {}

    package func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state in
                if state.isOpen {
                    return true
                }
                state.continuations.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    package func open() {
        let continuations: [CheckedContinuation<Void, Never>] = state.withLock { state in
            guard !state.isOpen else { return [] }
            state.isOpen = true
            let continuations = state.continuations
            state.continuations.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
}
