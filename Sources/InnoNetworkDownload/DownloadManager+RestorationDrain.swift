import Foundation

// Split out of `DownloadManager.swift` so the restore-barrier wait,
// pending-failure bookkeeping, and handler drain — which collaborate
// closely but are unrelated to the rest of the lifecycle — live in one
// place. All methods stay actor-isolated; this file only relocates code,
// no behaviour changes.
extension DownloadManager {

    func recordPendingRestoreFailures(_ taskIDs: [String]) async {
        pendingRestoreFailures.formUnion(taskIDs)
        // If callers wired handlers up before restoration completed, flush
        // immediately so they observe the failure without needing to also
        // subscribe through `events(for:)`.
        await drainPendingRestoreFailuresToHandlers()
    }

    func flushPendingRestoreFailureIfNeeded(taskID: String) async {
        guard pendingRestoreFailures.remove(taskID) != nil else { return }
        await drainRestoreFailure(taskID: taskID)
    }

    func drainPendingRestoreFailuresToHandlers() async {
        let onState = await runtimeRegistry.onStateChanged
        let onFailed = await runtimeRegistry.onFailed
        guard onState != nil || onFailed != nil else { return }
        let ids = pendingRestoreFailures
        pendingRestoreFailures.removeAll()
        for id in ids {
            await drainRestoreFailure(taskID: id)
        }
    }

    func drainRestoreFailure(taskID: String) async {
        let task = await runtimeRegistry.task(withId: taskID)
        if let task {
            await runtimeRegistry.onStateChanged?(task, .failed)
            await runtimeRegistry.onFailed?(task, .restorationMissingSystemTask)
        }
        await eventHub.publish(.stateChanged(.failed), for: taskID)
        await eventHub.publish(.failed(.restorationMissingSystemTask), for: taskID)
        await eventHub.finish(taskID: taskID)
        if let task {
            await runtimeRegistry.remove(task)
        }
    }

    func waitForRestore() async -> Bool {
        do {
            try await restoreBarrier.wait()
            try Task.checkCancellation()
            return true
        } catch {
            return false
        }
    }
}
