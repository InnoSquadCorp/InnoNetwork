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

    package struct Generation: Sendable, Equatable {
        fileprivate let global: UInt64
        fileprivate let tag: UInt64
    }

    private struct State: Sendable {
        var entries: [UUID: Entry] = [:]
        var globalGeneration: UInt64 = 0
        var tagGenerations: [CancellationTag: UInt64] = [:]
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    package init() {}

    package func generation(for tag: CancellationTag? = nil) -> Generation {
        state.withLock { state in
            Generation(
                global: state.globalGeneration,
                tag: tag.map { state.tagGenerations[$0, default: 0] } ?? 0
            )
        }
    }

    package func register(
        id: UUID,
        tag: CancellationTag? = nil,
        generation: Generation? = nil,
        cancelHandler: @escaping @Sendable () -> Void
    ) {
        let shouldCancel = state.withLock { state in
            if let generation {
                guard generation.global == state.globalGeneration else { return true }
                if let tag, generation.tag != state.tagGenerations[tag, default: 0] {
                    return true
                }
            }
            state.entries[id] = Entry(tag: tag, cancelHandler: cancelHandler)
            return false
        }
        if shouldCancel {
            cancelHandler()
        }
    }

    package func deregister(id: UUID) {
        state.withLock { state in
            _ = state.entries.removeValue(forKey: id)
        }
    }

    package func cancelAll() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            state.globalGeneration &+= 1
            let collected = state.entries.values.map { $0.cancelHandler }
            state.entries.removeAll()
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
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            state.tagGenerations[tag, default: 0] &+= 1
            var handlers: [@Sendable () -> Void] = []
            handlers.reserveCapacity(state.entries.count)
            var retained: [UUID: Entry] = [:]
            retained.reserveCapacity(state.entries.count)
            for (id, entry) in state.entries {
                if entry.tag == tag {
                    handlers.append(entry.cancelHandler)
                } else {
                    retained[id] = entry
                }
            }
            state.entries = retained
            return handlers
        }
        for handler in handlers {
            handler()
        }
    }

    package var inFlightCount: Int {
        state.withLock { $0.entries.count }
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
        var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
        var cancelledWaiters: Set<UUID> = []
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    package init() {}

    package func wait() async -> Bool {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediateResult = state.withLock { state -> Bool? in
                    if state.cancelledWaiters.remove(waiterID) != nil || Task.isCancelled {
                        return false
                    }
                    if state.isOpen {
                        return true
                    }
                    state.continuations[waiterID] = continuation
                    return nil
                }
                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                if let continuation = state.continuations.removeValue(forKey: waiterID) {
                    return continuation
                }
                if !state.isOpen {
                    state.cancelledWaiters.insert(waiterID)
                }
                return nil
            }
            continuation?.resume(returning: false)
        }
    }

    package func open() {
        let continuations: [CheckedContinuation<Bool, Never>] = state.withLock { state in
            guard !state.isOpen else { return [] }
            state.isOpen = true
            let continuations = Array(state.continuations.values)
            state.continuations.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume(returning: true)
        }
    }
}
