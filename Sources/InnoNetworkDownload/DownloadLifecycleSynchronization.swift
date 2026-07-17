import Foundation
import os

/// Outcome of an asynchronous operation racing the download manager's
/// shutdown boundary.
package enum DownloadLifecycleRaceResult<Value: Sendable>: Sendable {
    case value(Value)
    case shutdown
}

/// Lock-backed lifecycle admission shared by the manager and its transport
/// coordinators.
///
/// The final check and `resume()` are performed under the same lock used by
/// shutdown admission. A task therefore resumes-before-shutdown (and is swept)
/// or is cancelled without ever resuming; it cannot start after the latch has
/// closed.
package final class DownloadLifecycleGate: Sendable {
    private struct State: Sendable {
        var isShutdown = false
        var shutdownHandlers: [UUID: @Sendable () -> Void] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isShutdown: Bool {
        state.withLock { $0.isShutdown }
    }

    func beginShutdown() -> Bool {
        let result = state.withLock { state -> (Bool, [@Sendable () -> Void]) in
            guard !state.isShutdown else { return (false, []) }
            state.isShutdown = true
            let handlers = Array(state.shutdownHandlers.values)
            state.shutdownHandlers.removeAll(keepingCapacity: false)
            return (true, handlers)
        }
        for handler in result.1 {
            handler()
        }
        return result.0
    }

    func resumeIfOpen(_ task: any DownloadURLTask) -> Bool {
        state.withLock { state in
            guard !state.isShutdown else { return false }
            task.resume()
            return true
        }
    }

    package func raceWithShutdown<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> DownloadLifecycleRaceResult<Value> {
        let gate = DownloadLifecycleRaceGate<Value>()
        guard
            let handlerID = registerShutdownHandler({
                gate.complete(.shutdown)
            })
        else {
            return .shutdown
        }

        let operationTask = Task {
            let value = await operation()
            gate.complete(.value(value))
        }
        let result = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            gate.complete(.shutdown)
        }

        removeShutdownHandler(handlerID)
        if case .shutdown = result {
            operationTask.cancel()
        }
        return result
    }

    /// Once an operation has initiated an irreversible transport transition,
    /// caller cancellation must not abandon its durable reconciliation. This
    /// variant still exits promptly for manager shutdown, but shields the
    /// operation from cancellation of the public API caller.
    package func raceOnlyWithShutdown<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> DownloadLifecycleRaceResult<Value> {
        let gate = DownloadLifecycleRaceGate<Value>()
        guard
            let handlerID = registerShutdownHandler({
                gate.complete(.shutdown)
            })
        else {
            return .shutdown
        }

        let operationTask = Task {
            let value = await operation()
            gate.complete(.value(value))
        }
        let result = await gate.wait()

        removeShutdownHandler(handlerID)
        if case .shutdown = result {
            operationTask.cancel()
        }
        return result
    }

    private func registerShutdownHandler(
        _ handler: @escaping @Sendable () -> Void
    ) -> UUID? {
        let id = UUID()
        let registered = state.withLock { state in
            guard !state.isShutdown else { return false }
            state.shutdownHandlers[id] = handler
            return true
        }
        guard registered else {
            handler()
            return nil
        }
        return id
    }

    private func removeShutdownHandler(_ id: UUID) {
        state.withLock { state in
            _ = state.shutdownHandlers.removeValue(forKey: id)
        }
    }
}

private final class DownloadLifecycleRaceGate<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<DownloadLifecycleRaceResult<Value>, Never>?
        var result: DownloadLifecycleRaceResult<Value>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async -> DownloadLifecycleRaceResult<Value> {
        await withCheckedContinuation { continuation in
            let immediateResult = state.withLock { state -> DownloadLifecycleRaceResult<Value>? in
                if let result = state.result {
                    return result
                }
                state.continuation = continuation
                return nil
            }
            if let immediateResult {
                continuation.resume(returning: immediateResult)
            }
        }
    }

    func complete(_ result: DownloadLifecycleRaceResult<Value>) {
        let continuation = state.withLock {
            state -> CheckedContinuation<DownloadLifecycleRaceResult<Value>, Never>? in
            guard case .none = state.result else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

/// One-shot barrier that delays public operations until durable download state
/// restoration has finished.
actor RestoreBarrier {
    private var isCompleted = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        guard !isCompleted else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if isCompleted {
                    continuation.resume(returning: ())
                    return
                }
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { [weak self] in
                guard let self else { return }
                await self.cancelWaiter(waiterID)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
    }

    func complete() {
        guard !isCompleted else { return }
        isCompleted = true
        for waiter in waiters.values {
            waiter.resume(returning: ())
        }
        waiters.removeAll(keepingCapacity: false)
    }
}

/// Idempotent one-shot barrier used by shutdown and URLSession invalidation.
actor InvalidationBarrier {
    private var isCompleted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isCompleted else { return }
        await withCheckedContinuation { continuation in
            if isCompleted {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func complete() {
        guard !isCompleted else { return }
        isCompleted = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll(keepingCapacity: false)
    }
}
