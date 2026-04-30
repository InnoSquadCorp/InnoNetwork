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
    private struct Entry: Sendable {
        let tag: CancellationTag?
        let cancelHandler: @Sendable () -> Void
    }

    private let entries = OSAllocatedUnfairLock<[UUID: Entry]>(initialState: [:])

    package init() {}

    package func register(
        id: UUID,
        tag: CancellationTag? = nil,
        cancelHandler: @escaping @Sendable () -> Void
    ) {
        entries.withLock { $0[id] = Entry(tag: tag, cancelHandler: cancelHandler) }
    }

    package func deregister(id: UUID) {
        entries.withLock { state in
            _ = state.removeValue(forKey: id)
        }
    }

    package func cancelAll() {
        let handlers = entries.withLock { state -> [@Sendable () -> Void] in
            let collected = state.values.map { $0.cancelHandler }
            state.removeAll()
            return collected
        }
        for handler in handlers {
            handler()
        }
    }

    /// Cancel only the in-flight requests registered with the supplied tag.
    /// Requests registered without a tag, and requests with a different tag,
    /// are left alone. Matching entries are removed from the registry.
    package func cancelAll(matching tag: CancellationTag) {
        let handlers = entries.withLock { state -> [@Sendable () -> Void] in
            let matchingKeys = state.compactMap { key, entry -> UUID? in
                entry.tag == tag ? key : nil
            }
            return matchingKeys.compactMap { key -> (@Sendable () -> Void)? in
                state.removeValue(forKey: key)?.cancelHandler
            }
        }
        for handler in handlers {
            handler()
        }
    }

    package var inFlightCount: Int {
        entries.withLock { $0.count }
    }
}


package final class InFlightTaskHandle: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var isCancelled = false
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    package init() {}

    package func attach(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state in
            state.task = task
            return state.isCancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    package func cancel() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.isCancelled = true
            return state.task
        }
        task?.cancel()
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
