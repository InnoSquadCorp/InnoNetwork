import Foundation

// Split out of `DownloadManager.swift` so the watchdog poll loop and its
// stall-detection heuristics live next to each other rather than being
// interleaved with unrelated lifecycle / event-handling code. All methods
// stay actor-isolated; this file only relocates code, no behaviour changes.
extension DownloadManager {

    func startInactivityWatchdog(timeout: Duration) {
        guard !isShutdown, inactivityWatchdogTask == nil else { return }
        inactivityWatchdogTask = Task { [weak self] in
            await self?.runInactivityWatchdog(timeout: timeout)
        }
    }

    func runInactivityWatchdog(timeout: Duration) async {
        // Poll at half the timeout so worst-case detection latency is
        // bounded by `timeout * 1.5` for any stall.
        let cadence = max(Duration.milliseconds(50), timeout / 2)
        while !Task.isCancelled, !isShutdown {
            do {
                try await Task.sleep(for: cadence)
            } catch {
                return
            }
            if Task.isCancelled || isShutdown { return }
            await cancelInactiveDownloads(timeout: timeout)
        }
    }

    func cancelInactiveDownloads(timeout: Duration) async {
        let now = ContinuousClock().now
        let tasks = await runtimeRegistry.allTasks()
        for task in tasks {
            let expectedLifecycle = await task.lifecycleSnapshot()
            guard expectedLifecycle.state == .downloading else { continue }
            // Retry backoff and attempt replacement intentionally leave the
            // logical task in `.downloading` while no URLSession task is
            // active. Such a task cannot be stalled on the wire and must not
            // be cancelled by the inactivity watchdog.
            guard let expectedURLTask = await runtimeRegistry.urlTask(for: task.id) else { continue }
            let expectedTaskIdentifier = expectedURLTask.taskIdentifier
            // Seed `lastProgressAt` lazily on first observation of a
            // `.downloading` task that has never reported progress. This
            // covers the "server accepted the connection but never sends
            // bytes" case — the most common real-world stall — so the
            // watchdog measures from "first observed downloading" rather
            // than refusing to fire because no progress arrived.
            let lastProgress: ContinuousClock.Instant
            if let observed = await task.lastProgressAt {
                lastProgress = observed
            } else {
                await task.setLastProgressAt(now)
                continue
            }
            if now - lastProgress > timeout {
                // Re-check state right before cancel: the task may have
                // raced to `.paused` / `.completed` / `.failed` across the
                // `lastProgressAt` await above.
                guard await task.lifecycleSnapshot() == expectedLifecycle,
                    let currentURLTask = await runtimeRegistry.urlTask(for: task.id),
                    currentURLTask.taskIdentifier == expectedTaskIdentifier
                else { continue }
                Self.logger.notice(
                    "Cancelling stalled download \(task.id, privacy: .private(mask: .hash)) — no progress for \(String(describing: timeout), privacy: .public)"
                )
                await cancelInactiveDownload(
                    task,
                    expectedLifecycle: expectedLifecycle,
                    expectedTaskIdentifier: expectedTaskIdentifier,
                    expectedURLTask: expectedURLTask
                )
            }
        }
    }

    private func cancelInactiveDownload(
        _ task: DownloadTask,
        expectedLifecycle: DownloadTaskLifecycleSnapshot,
        expectedTaskIdentifier: Int,
        expectedURLTask: any DownloadURLTask
    ) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else { return }
        guard await runtimeRegistry.owns(task) else { return }
        guard
            await task.requestCancellationClaimingPersistenceCleanup(
                ifMatching: expectedLifecycle
            ) == .transitioned
        else {
            return
        }

        pendingRestoreFailures.remove(task.id)
        await task.waitForStartPersistenceClaimRelease()
        do {
            try await persistence.markTerminal(task: task)
        } catch {
            Self.logger.fault(
                "Failed to persist inactivity-cancellation tombstone for task \(task.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
        await eventHub.publishTerminalAndFinish(
            .stateChanged(.cancelled),
            for: task.id
        )
        expectedURLTask.cancel()
        await runtimeRegistry.removeAttemptRuntime(taskIdentifier: expectedTaskIdentifier)

        do {
            try await persistence.remove(id: task.id)
        } catch {
            Self.logger.fault(
                "Failed to remove inactivity-cancelled task \(task.id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
            await task.releaseTerminalPersistenceCleanupClaim()
            return
        }
        await runtimeRegistry.remove(task)
        await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
        await task.releaseTerminalPersistenceCleanupClaim()
    }
}
