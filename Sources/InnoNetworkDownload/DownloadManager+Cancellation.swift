import Foundation
import InnoNetwork

// Per-task and bulk cancellation share the same destructive-lifecycle claim,
// terminal persistence, runtime cleanup, and callback delivery contract.
extension DownloadManager {

    public func cancel(_ task: DownloadTask) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else { return }
        guard await runtimeRegistry.owns(task) else { return }
        await task.waitForFailureFinalization()
        guard await claimDestructiveLifecycle(taskID: task.id) else { return }
        await task.endRestoredSuccessAdmission()
        managerState.provisionalBackgroundRestoreFailureIDs.remove(task.id)
        managerState.pendingRestoreFailures.remove(task.id)
        // Drive the state transition only when we're leaving a non-terminal
        // state. Calling `cancel` again on an already-terminal task (for
        // example, after the first attempt's persistence removal failed)
        // continues into the cleanup path below so callers can drain the
        // registry without triggering an illegal-transition assertion.
        let transition = await task.requestCancellationClaimingPersistenceCleanup()
        guard transition != .busy else { return }
        let didTransition = transition == .transitioned
        await task.waitForStartPersistenceClaimRelease()
        do {
            try await persistence.markTerminal(task: task)
        } catch {
            Self.logger.fault(
                "Failed to persist cancellation tombstone for task \(task.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
        if didTransition {
            await eventHub.publishTerminalAndFinish(
                .stateChanged(.cancelled),
                for: task.id
            )

            if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
                urlTask.cancel()
            }
        }
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)

        do {
            try await persistence.remove(id: task.id)
        } catch {
            Self.logger.fault(
                "Failed to remove cancelled task \(task.id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            if didTransition {
                await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
            }
            await task.releaseTerminalPersistenceCleanupClaim()
            return
        }
        await runtimeRegistry.remove(task)
        if didTransition {
            await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
        }
        await task.releaseTerminalPersistenceCleanupClaim()
    }

    public func cancelAll() async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else { return }
        await cancelRegisteredTasks(runtimeRegistry.allTasks())
    }

    /// Cancels every registered download whose start carried `tag`.
    ///
    /// Mirrors ``DefaultNetworkClient/cancelAll(matching:)`` so per-screen
    /// or per-feature teardown can interrupt only its own transfers. Tags
    /// are runtime-scoped: tasks restored from a background session carry
    /// no tag and remain reachable through ``cancelAll()`` or per-task
    /// ``cancel(_:)``.
    public func cancelAll(matching tag: CancellationTag) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else { return }
        await cancelRegisteredTasks(runtimeRegistry.tasks(matching: tag))
    }

    private func cancelRegisteredTasks(_ candidates: [DownloadTask]) async {
        var tasks: [DownloadTask] = []
        tasks.reserveCapacity(candidates.count)
        for task in candidates {
            if await claimDestructiveLifecycle(taskID: task.id) {
                tasks.append(task)
            }
        }
        guard !tasks.isEmpty else { return }
        for task in tasks {
            await task.waitForFailureFinalization()
        }
        managerState.pendingRestoreFailures.subtract(tasks.map(\.id))
        managerState.provisionalBackgroundRestoreFailureIDs.subtract(tasks.map(\.id))
        for task in tasks {
            await task.endRestoredSuccessAdmission()
        }

        // Phase 1: drive every state transition + URL-task cancel up front,
        // before touching persistence. Each task's state snapshot/transition
        // is an independent actor exchange, so a TaskGroup lets the runtime
        // dispatcher hand them out in any order; the per-task work itself
        // still serializes inside `DownloadTask` and `runtimeRegistry`.
        //
        // Only tasks we actually transitioned receive `.cancelled` events and
        // callbacks. Already-terminal tasks are still included in persistence
        // cleanup so a second `cancelAll()` can recover from an earlier bulk
        // remove failure without reporting a spurious state change.
        var transitionedIDs: Set<String> = []
        var removableIDs: Set<String> = []
        transitionedIDs.reserveCapacity(tasks.count)
        removableIDs.reserveCapacity(tasks.count)

        await withTaskGroup(of: (String, DownloadTerminalTransitionResult).self) { group in
            for task in tasks {
                group.addTask {
                    let result = await task.requestCancellationClaimingPersistenceCleanup()
                    return (task.id, result)
                }
            }
            for await (id, result) in group {
                switch result {
                case .transitioned:
                    transitionedIDs.insert(id)
                    removableIDs.insert(id)
                case .alreadyTerminal:
                    removableIDs.insert(id)
                case .busy:
                    break
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for task in tasks where removableIDs.contains(task.id) {
                group.addTask {
                    await task.waitForStartPersistenceClaimRelease()
                }
            }
        }

        do {
            try await persistence.markTerminal(tasks: tasks, ids: removableIDs)
        } catch {
            Self.logger.fault(
                "cancelAll terminal-marker write failed for \(removableIDs.count, privacy: .public) ids: \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }

        for task in tasks where transitionedIDs.contains(task.id) {
            await eventHub.publishTerminalAndFinish(
                .stateChanged(.cancelled),
                for: task.id
            )
            if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
                urlTask.cancel()
            }
        }
        for task in tasks where removableIDs.contains(task.id) {
            await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        }

        // Phase 2: a single bulk persistence remove takes the directory
        // lock once and emits one fsync regardless of `tasks.count`. The
        // pre-fix loop paid O(N) lock acquisitions and could spend seconds
        // on a 100-task cancel storm.
        do {
            try await persistence.remove(ids: removableIDs)
        } catch {
            Self.logger.fault(
                "cancelAll persistence bulk-remove failed for \(removableIDs.count, privacy: .public) ids: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            for task in tasks where transitionedIDs.contains(task.id) {
                await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
            }
            for task in tasks where removableIDs.contains(task.id) {
                await task.releaseTerminalPersistenceCleanupClaim()
            }
            return
        }

        for task in tasks where removableIDs.contains(task.id) {
            await runtimeRegistry.remove(task)
            if transitionedIDs.contains(task.id) {
                await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
            }
            await task.releaseTerminalPersistenceCleanupClaim()
        }
    }
}
