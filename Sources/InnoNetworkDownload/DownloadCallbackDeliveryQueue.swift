import Foundation
import os

/// Delivers app-facing download callbacks outside the system delegate FIFO.
///
/// Each logical task owns one serial worker, so its callbacks retain enqueue
/// order while callbacks for unrelated tasks may make progress independently.
/// Progress waiting behind a slow callback is coalesced to the latest value,
/// matching the delegate channel's bounded-progress behavior without allowing
/// an app callback to grow an unbounded queue. Admission callbacks normally
/// retain that per-task order and synchronously complete before transport. If
/// waiting would close a same-manager callback dependency cycle, only the edge
/// that closes the cycle runs inline. This preserves the prior same-task
/// reentrancy behavior and avoids cross-task worker deadlocks without weakening
/// ordinary admission ordering.
package actor DownloadCallbackDeliveryQueue {
    private struct WaitDependency: Sendable {
        let sourceTaskID: String
        let targetTaskID: String
    }

    private struct Delivery: Sendable {
        let taskID: String
        let isProgress: Bool
        let callback: @Sendable () async -> Void

        func deliver() async {
            await callback()
        }
    }

    private struct QueuedDelivery: Sendable {
        let delivery: Delivery
        let completion: DownloadCallbackDeliveryCompletion?

        var taskID: String { delivery.taskID }
        var isProgress: Bool { delivery.isProgress }

        func deliver() async {
            await delivery.deliver()
            completion?.complete()
        }
    }

    private let runtimeRegistry: DownloadRuntimeRegistry
    private var pendingByTaskID: [String: [QueuedDelivery]] = [:]
    private var workerByTaskID: [String: Task<Void, Never>] = [:]
    /// Reference-counted callback wait graph. Counts are necessary because a
    /// callback can spawn child tasks that inherit its still-active TaskLocal
    /// token and concurrently wait on the same target.
    private var waitDependencyCountsBySource: [String: [String: Int]] = [:]
    private var acceptsDeliveries = true

    package init(runtimeRegistry: DownloadRuntimeRegistry) {
        self.runtimeRegistry = runtimeRegistry
    }

    package func enqueueProgress(
        _ task: DownloadTask,
        _ progress: DownloadProgress
    ) async {
        guard let callback = await runtimeRegistry.prepareProgressCallback(task, progress) else {
            return
        }
        enqueue(
            Delivery(taskID: task.id, isProgress: true, callback: callback)
        )
    }

    package func enqueueStateChanged(
        _ task: DownloadTask,
        _ state: DownloadState
    ) async {
        guard let callback = await runtimeRegistry.prepareStateChangedCallback(task, state) else {
            return
        }
        enqueue(
            Delivery(taskID: task.id, isProgress: false, callback: callback)
        )
    }

    /// Enqueues an admission-phase state callback and waits for that callback
    /// to return. Only pre-transport `.waiting` / `.downloading` hooks use this
    /// variant so an existing callback-driven cancellation can still win
    /// before persistence or `URLSessionTask.resume()`. Delegate-originated
    /// and terminal callbacks always use the non-blocking enqueue methods.
    package func enqueueStateChangedAndWait(
        _ task: DownloadTask,
        _ state: DownloadState
    ) async {
        guard let callback = await runtimeRegistry.prepareStateChangedCallback(task, state) else {
            return
        }
        let dependency: WaitDependency?
        if let sourceTaskID = DownloadUserCallbackContext.token?.activeTaskID(
            for: runtimeRegistry.callbackContextID
        ) {
            if hasWaitPath(from: task.id, to: sourceTaskID) {
                // Adding source -> target would close a dependency cycle. The
                // target worker cannot service this callback until a callback
                // already in the cycle returns, so invoke this one snapshotted
                // admission hook inline. A same-task request is the one-node
                // form of the same cycle.
                await callback()
                return
            }
            let registeredDependency = WaitDependency(
                sourceTaskID: sourceTaskID,
                targetTaskID: task.id
            )
            addWaitDependency(registeredDependency)
            dependency = registeredDependency
        } else {
            dependency = nil
        }
        defer {
            if let dependency {
                removeWaitDependency(dependency)
            }
        }

        let completion = DownloadCallbackDeliveryCompletion()
        let delivery = Delivery(
            taskID: task.id,
            isProgress: false,
            callback: callback
        )
        guard enqueue(delivery, completion: completion) else {
            return
        }
        await completion.wait()
    }

    private func hasWaitPath(from sourceTaskID: String, to targetTaskID: String) -> Bool {
        var pending = [sourceTaskID]
        var visited = Set<String>()

        while let taskID = pending.popLast() {
            if taskID == targetTaskID { return true }
            guard visited.insert(taskID).inserted else { continue }
            if let targets = waitDependencyCountsBySource[taskID] {
                pending.append(contentsOf: targets.keys)
            }
        }
        return false
    }

    private func addWaitDependency(_ dependency: WaitDependency) {
        waitDependencyCountsBySource[dependency.sourceTaskID, default: [:]][
            dependency.targetTaskID,
            default: 0
        ] += 1
    }

    private func removeWaitDependency(_ dependency: WaitDependency) {
        guard var targets = waitDependencyCountsBySource[dependency.sourceTaskID],
            let count = targets[dependency.targetTaskID]
        else {
            return
        }

        if count > 1 {
            targets[dependency.targetTaskID] = count - 1
            waitDependencyCountsBySource[dependency.sourceTaskID] = targets
            return
        }

        targets.removeValue(forKey: dependency.targetTaskID)
        if targets.isEmpty {
            waitDependencyCountsBySource.removeValue(forKey: dependency.sourceTaskID)
        } else {
            waitDependencyCountsBySource[dependency.sourceTaskID] = targets
        }
    }

    package func enqueueCompleted(
        _ task: DownloadTask,
        _ location: URL
    ) async {
        guard let callback = await runtimeRegistry.prepareCompletedCallback(task, location) else {
            return
        }
        enqueue(
            Delivery(taskID: task.id, isProgress: false, callback: callback)
        )
    }

    package func enqueueFailed(
        _ task: DownloadTask,
        _ error: DownloadError
    ) async {
        guard let callback = await runtimeRegistry.prepareFailedCallback(task, error) else {
            return
        }
        enqueue(
            Delivery(taskID: task.id, isProgress: false, callback: callback)
        )
    }

    /// Stops admission and waits for every callback accepted before this call.
    /// Shutdown invokes this only after delegate, retry, watchdog, and public
    /// lifecycle producers are drained, so rejecting later work cannot lose an
    /// admitted lifecycle callback.
    package func finishAndDrain() async {
        acceptsDeliveries = false
        let workers = Array(workerByTaskID.values)
        for worker in workers {
            await worker.value
        }
    }

    @discardableResult
    private func enqueue(
        _ delivery: Delivery,
        completion: DownloadCallbackDeliveryCompletion? = nil
    ) -> Bool {
        guard acceptsDeliveries else {
            completion?.complete()
            return false
        }
        let queuedDelivery = QueuedDelivery(
            delivery: delivery,
            completion: completion
        )
        let taskID = queuedDelivery.taskID

        if queuedDelivery.isProgress,
            var pending = pendingByTaskID[taskID],
            pending.last?.isProgress == true
        {
            pending[pending.count - 1] = queuedDelivery
            pendingByTaskID[taskID] = pending
        } else {
            pendingByTaskID[taskID, default: []].append(queuedDelivery)
        }

        guard workerByTaskID[taskID] == nil else { return true }
        let worker = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.drain(taskID: taskID)
        }
        workerByTaskID[taskID] = worker
        return true
    }

    private func drain(taskID: String) async {
        while let delivery = takeNext(taskID: taskID) {
            await delivery.deliver()
        }
        workerByTaskID.removeValue(forKey: taskID)
    }

    private func takeNext(taskID: String) -> QueuedDelivery? {
        guard var pending = pendingByTaskID[taskID], !pending.isEmpty else {
            pendingByTaskID.removeValue(forKey: taskID)
            return nil
        }
        let next = pending.removeFirst()
        if pending.isEmpty {
            pendingByTaskID.removeValue(forKey: taskID)
        } else {
            pendingByTaskID[taskID] = pending
        }
        return next
    }
}

private final class DownloadCallbackDeliveryCompletion: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var isComplete = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                if state.isComplete { return true }
                state.continuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func complete() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.isComplete else { return nil }
            state.isComplete = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}
