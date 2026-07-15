import Foundation

// Split out of `DownloadManager.swift` so the restore-barrier wait,
// pending-failure persistence finalization, bookkeeping, and handler drain —
// which collaborate closely but are unrelated to the rest of the lifecycle —
// live in one place. All methods stay actor-isolated.
extension DownloadManager {

    func prepareBackgroundRestoreBoundary(_ result: DownloadRestoreResult) async {
        let remainingFailures = await remainingRestoreFailures(
            from: result.failedTaskIDs
        )
        provisionalBackgroundRestoreFailureIDs.formUnion(remainingFailures)
        backgroundRestoreSnapshotPrepared = true
        backgroundRestoreBoundaryPending = true

        await recordPendingRestoreCompletions(result.completedTaskIDs)
        scheduleRestoredRetries(result.deferredRetries)

        // `urlSessionDidFinishEvents` can already be queued ahead of the
        // synthetic snapshot marker. In that ordering, its manager event only
        // records the fact; this method performs internal finalization before
        // the host application's stored completion handler is released.
        if backgroundRestoreEventsFinished {
            await finalizeBackgroundRestoreBoundary()
            await invokePendingBackgroundSessionCompletions()
            backgroundRestoreEventsFinished = false
        }
    }

    func handleBackgroundRestoreEventsFinished(
        completion: (@Sendable () -> Void)?
    ) async {
        if let completion {
            pendingBackgroundSessionCompletions.append(completion)
        }
        backgroundRestoreEventsFinished = true
        guard backgroundRestoreSnapshotPrepared else { return }
        if backgroundRestoreBoundaryPending {
            await finalizeBackgroundRestoreBoundary()
        }
        await invokePendingBackgroundSessionCompletions()
        backgroundRestoreEventsFinished = false
    }

    private func finalizeBackgroundRestoreBoundary() async {
        guard backgroundRestoreBoundaryPending else { return }
        backgroundRestoreBoundaryPending = false

        // Foundation has now delivered every message that was queued for the
        // reattached background session. Close the one-shot restoration
        // admissions only at this official boundary.
        for task in await runtimeRegistry.allTasks() {
            await task.endRestoredSuccessAdmission()
        }

        let pending = await remainingRestoreFailures(
            from: Array(provisionalBackgroundRestoreFailureIDs)
        )
        provisionalBackgroundRestoreFailureIDs.removeAll()
        await recordPendingRestoreFailures(pending)
    }

    private func invokePendingBackgroundSessionCompletions() async {
        let completions = pendingBackgroundSessionCompletions
        pendingBackgroundSessionCompletions.removeAll(keepingCapacity: true)
        guard !completions.isEmpty else { return }
        await MainActor.run {
            for completion in completions {
                completion()
            }
        }
    }

    func recordPendingRestoreCompletions(_ taskIDs: [String]) async {
        for taskID in taskIDs {
            guard let task = await runtimeRegistry.task(withId: taskID) else { continue }
            guard await task.state == .completed else { continue }
            guard let record = await persistence.record(forID: taskID),
                record.lifecycle == .terminal,
                record.commitOutcome == .finished
            else {
                continue
            }
            pendingRestoreCompletions.insert(taskID)
        }

        // Handlers may be installed before the one-shot restore barrier opens.
        // Start delivery in independent tasks so a reentrant callback can await
        // that barrier without blocking the restoration worker that completes it.
        await drainPendingRestoreCompletionsToHandlers()
    }

    func drainPendingRestoreCompletionsToHandlers() async {
        guard await runtimeRegistry.hasRestoreCompletionHandler else { return }
        for taskID in pendingRestoreCompletions
        where drainingRestoreCompletionTaskIDs.insert(taskID).inserted {
            Task { [weak self] in
                await self?.deliverRestoredCompletionToHandlers(taskID: taskID)
            }
        }
    }

    private func deliverRestoredCompletionToHandlers(taskID: String) async {
        guard pendingRestoreCompletions.contains(taskID),
            let task = await runtimeRegistry.task(withId: taskID),
            await task.state == .completed
        else {
            drainingRestoreCompletionTaskIDs.remove(taskID)
            return
        }

        let stateCallback = await runtimeRegistry.prepareStateChangedCallback(
            task,
            .completed
        )
        let completionCallback = await runtimeRegistry.prepareCompletedCallback(
            task,
            task.destinationURL
        )
        guard stateCallback != nil || completionCallback != nil else {
            drainingRestoreCompletionTaskIDs.remove(taskID)
            return
        }

        if let stateCallback {
            await stateCallback()
        }
        if let completionCallback {
            await completionCallback()
        }
        await acknowledgeRestoredCompletionIfNeeded(taskID: taskID)
    }

    func acknowledgeRestoredCompletionIfNeeded(taskID: String) async {
        guard pendingRestoreCompletions.contains(taskID) else {
            drainingRestoreCompletionTaskIDs.remove(taskID)
            return
        }

        // Keep the in-flight marker set when removal fails. The callback/event
        // was already observed, so suppress duplicate delivery in this process;
        // the durable receipt remains available for retry on the next launch.
        guard let record = await persistence.record(forID: taskID),
            record.lifecycle == .terminal,
            let metadata = record.commitMetadata,
            record.commitOutcome == .finished
        else {
            return
        }
        drainingRestoreCompletionTaskIDs.insert(taskID)
        do {
            guard
                try await persistence.acknowledgeCommitOutcome(
                    id: taskID,
                    metadata: metadata,
                    outcome: .finished
                )
            else {
                Self.logger.fault(
                    "Restored completion acknowledgment no longer matched task \(taskID, privacy: .private(mask: .hash)). The current durable generation was preserved."
                )
                return
            }
        } catch {
            Self.logger.fault(
                "Failed to acknowledge restored completion \(taskID, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). The finished receipt remains durable for the next launch."
            )
            return
        }

        pendingRestoreCompletions.remove(taskID)
        drainingRestoreCompletionTaskIDs.remove(taskID)
        completionAdmissionGate.release(taskID: taskID)
        if let task = await runtimeRegistry.task(withId: taskID) {
            await runtimeRegistry.removeTaskRuntime(taskId: taskID)
            await runtimeRegistry.remove(task)
        }
    }

    func recordPendingRestoreFailures(_ taskIDs: [String]) async {
        var sealedTaskIDs = Set<String>()
        sealedTaskIDs.reserveCapacity(taskIDs.count)
        for taskID in taskIDs {
            guard let task = await runtimeRegistry.task(withId: taskID) else { continue }
            guard await task.state == .failed else { continue }
            guard await task.error != nil else { continue }

            if let record = await persistence.record(forID: taskID),
                record.lifecycle == .terminal,
                record.commitOutcome == .finished
            {
                // A finished receipt whose destination failed integrity
                // validation is diagnostic/recovery evidence, not an orphaned
                // transport row. Publish the failure but retain the exact
                // receipt and any staged payload instead of converting it into
                // an ordinary removable tombstone.
                sealedTaskIDs.insert(taskID)
                continue
            }

            // The restoration FIFO boundary is now closed, so no staged
            // success may consume this synthetic failure. Seal terminal intent
            // before removing the active/legacy row and before any public
            // event or callback is admitted. If removal fails, the absorbing
            // tombstone survives for the next launch instead of resurrecting
            // an orphaned active download.
            do {
                try await persistence.markTerminal(task: task)
            } catch {
                Self.logger.fault(
                    "Failed to seal restored missing-system task \(taskID, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). The active row is retained for reconciliation on the next launch, and the synthetic failure remains unpublished in this process."
                )
                // No durable terminal intent exists, so this synthetic handle
                // must not become observable through task lookup, terminal
                // event replay, or callbacks in the current process. The
                // retained active row reconstructs a fresh handle next launch.
                await runtimeRegistry.remove(task)
                continue
            }
            sealedTaskIDs.insert(taskID)
            do {
                try await persistence.remove(id: taskID)
            } catch {
                Self.logger.fault(
                    "Failed to prune restored missing-system task \(taskID, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). A successful terminal marker remains durable for the next launch."
                )
            }
        }

        pendingRestoreFailures.formUnion(sealedTaskIDs)
        for taskID in sealedTaskIDs {
            let listenerCount = await eventHub.listenerCount(taskID: taskID)
            let streamConsumerCount = await eventHub.streamConsumerCount(taskID: taskID)
            let hasEventConsumer = listenerCount > 0 || streamConsumerCount > 0
            if hasEventConsumer,
                pendingRestoreFailures.remove(taskID) != nil
            {
                await drainRestoreFailure(taskID: taskID)
            }
        }
        // If callers wired handlers up before restoration completed, flush
        // immediately so they observe the failure without needing to also
        // subscribe through `events(for:)`.
        await drainPendingRestoreFailuresToHandlers()
    }

    func remainingRestoreFailures(from taskIDs: [String]) async -> [String] {
        var remaining: [String] = []
        remaining.reserveCapacity(taskIDs.count)
        for taskID in taskIDs {
            guard let task = await runtimeRegistry.task(withId: taskID) else { continue }
            guard await task.state == .failed else { continue }
            guard await task.error != nil else { continue }
            remaining.append(taskID)
        }
        return remaining
    }

    func flushPendingRestoreFailureIfNeeded(taskID: String) async {
        guard pendingRestoreFailures.remove(taskID) != nil else { return }
        await drainRestoreFailure(taskID: taskID)
    }

    func drainPendingRestoreFailuresToHandlers() async {
        guard await runtimeRegistry.hasRestoreFailureHandler else { return }
        let ids = pendingRestoreFailures
        pendingRestoreFailures.removeAll()
        for id in ids {
            await drainRestoreFailure(taskID: id)
        }
    }

    func drainRestoreFailure(taskID: String) async {
        guard drainingRestoreFailureTaskIDs.insert(taskID).inserted else { return }
        defer { finishRestoreFailureDrain(taskID: taskID) }

        let task = await runtimeRegistry.task(withId: taskID)
        guard let task else { return }
        guard await task.state == .failed else { return }
        guard let error = await task.error else { return }

        // Remove the old logical registration before publishing the retryable
        // failure. retry(_:) waits for this drain, then safely re-adds the same
        // owned handle as a new generation.
        await runtimeRegistry.remove(task)
        let failedLifecycle = await task.lifecycleSnapshot()
        await eventHub.publishIfCurrent(.stateChanged(.failed), for: taskID) {
            await task.lifecycleSnapshot() == failedLifecycle
        }
        await eventHub.publishTerminalAndFinish(
            .failed(error),
            for: taskID
        )
        // Cleanup and terminal sealing are complete. Release retry waiters
        // before invoking user code so a failure callback can reenter retry
        // without waiting on itself.
        finishRestoreFailureDrain(taskID: taskID)
        await callbackDeliveryQueue.enqueueStateChanged(task, .failed)
        await callbackDeliveryQueue.enqueueFailed(task, error)
    }

    func waitForRestoreFailureDrain(taskID: String) async {
        guard drainingRestoreFailureTaskIDs.contains(taskID) else { return }
        await withCheckedContinuation { continuation in
            restoreFailureDrainWaiters[taskID, default: []].append(continuation)
        }
    }

    private func finishRestoreFailureDrain(taskID: String) {
        drainingRestoreFailureTaskIDs.remove(taskID)
        let waiters = restoreFailureDrainWaiters.removeValue(forKey: taskID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForRestore() async -> Bool {
        guard !isShutdown else { return false }
        do {
            try await restoreBarrier.wait()
            try Task.checkCancellation()
            // Shutdown can win while this caller is suspended on the restore
            // barrier. Re-check after the await so no public operation can
            // register work into the session being invalidated.
            return !isShutdown
        } catch {
            return false
        }
    }
}
