import Foundation

extension DownloadManager {
    /// Tears down the manager: cancels every in-flight transfer, finishes
    /// outstanding event streams, and invalidates the underlying URLSession.
    ///
    /// `shutdown()` is the supported lifecycle exit point. It releases the
    /// background session identifier, drops the URLSession's strong reference
    /// to its delegate, and stops the delegate-event consumer task. After
    /// `shutdown()` returns, treat the manager as terminal and create a fresh
    /// instance for new transfer work; diagnostic getters may still reflect
    /// last-known in-memory task state. A fresh manager can claim the same
    /// `sessionIdentifier`. Calling `shutdown()` multiple times is safe.
    /// A call made from one of this manager's async callbacks starts teardown
    /// and returns so the callback can unwind instead of waiting on its own
    /// restoration or delegate worker. A later external call still waits for
    /// the complete shutdown boundary.
    ///
    /// In tests and apps that own the manager instance directly, prefer
    /// `shutdown()` over relying on `deinit` — Foundation will hold the
    /// session (and thus the manager and its closures) alive until invalidate
    /// completes, which can take longer than the surrounding scope.
    public func shutdown() async {
        let callbackToken = DownloadUserCallbackContext.token
        let isReentrantCallback =
            callbackToken?.containsActiveCallback(
                for: runtimeRegistry.callbackContextID
            ) == true

        if markShutdownIfNeeded() {
            // Teardown must never run on the restoration/delegate worker that
            // may currently be invoking the callback above. A dedicated task
            // owns all joins; TaskLocal callback ancestry is inherited so
            // nested callbacks retain correct reentrancy classification.
            Task { [self] in
                await performShutdown()
            }
        }

        guard !isReentrantCallback else { return }
        await shutdownBarrier.wait()
    }

    private func performShutdown() async {
        let inactivityWatchdogTask = managerState.inactivityWatchdogTask
        inactivityWatchdogTask?.cancel()
        managerState.inactivityWatchdogTask = nil

        let delegateConsumerTask = delegateConsumerTaskHandle.withLock { task -> Task<Void, Never>? in
            let current = task
            task = nil
            return current
        }

        let restorationTask = restorationTaskHandle.withLock { task -> Task<Void, Never>? in
            let current = task
            task = nil
            return current
        }
        restorationTask?.cancel()
        // Restoration owns URL-task adoption and persistence reconciliation.
        // Drain it before removing runtime mappings or invalidating the
        // session so a late restore continuation cannot repopulate a terminal
        // manager.
        await restorationTask?.value

        delegateEventChannel.finish()
        // Cancel an in-progress retry wait immediately. The consumer keeps
        // draining the already-accepted channel after cancellation; legacy
        // temporary files are removed while deterministic production journals
        // remain available to the next manager's restoration pass.
        delegateConsumerTask?.cancel()
        // Completion locations already accepted into the channel are
        // library-owned staging files. The cancelled consumer still drains
        // them through its explicit preservation/cleanup branch.
        // Let every lifecycle mutation admitted before shutdown finish before
        // the final task snapshot. This closes the persistence-suspension race
        // where `startDownload` could otherwise register a URL task after the
        // session had already been invalidated.
        await waitForShutdownTrackedOperationsToDrain()
        await inactivityWatchdogTask?.value

        // Seal every durable row before invalidating the session. If the
        // process is killed between URLSession cancellation and the later
        // cleanup sweep, a fresh manager must observe terminal tombstones,
        // not runnable active/retry/pause records.
        let preInvalidationRecords = await persistence.allRecords()
        let preInvalidationProtectedTaskIDs = await commitRecoveryProtectedTaskIDs(
            in: preInvalidationRecords
        )
        let preInvalidationTaskIDs = Set(preInvalidationRecords.map(\.id))
            .subtracting(preInvalidationProtectedTaskIDs)
        do {
            try await persistence.markTerminal(ids: preInvalidationTaskIDs)
        } catch {
            Self.logger.fault(
                "shutdown pre-invalidation terminal-marker write failed for \(preInvalidationTaskIDs.count, privacy: .public) ids: \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }

        // No admitted public mutation can create another task past this
        // point. Invalidate promptly so Foundation releases pending receives
        // even when an already-admitted delegate callback is waiting for user
        // code; shutdown still awaits that consumer below.
        session.invalidateAndCancel()

        // Drain all delegate events accepted before `finish()`. Completion
        // locations are library-owned staging files, and the consumer either
        // commits them or deletes them before the terminal sweep begins.
        await delegateConsumerTask?.value
        await drainDeferredFailureTasks()

        // Cancel every in-flight URLSession task before invalidating, then
        // close the per-task event partition so listeners receive a clean
        // end-of-stream signal instead of hanging indefinitely. We do not
        // await the URLSession-level cancellation (it's fire-and-forget by
        // contract); `invalidateAndCancel()` below drains the rest.
        let tasks = await runtimeRegistry.allTasks()
        // Include runtime-only tasks and any row discovered while the
        // pre-invalidation seal was being written. Terminal is absorbing in
        // persistence, so this second pass cannot be undone by a stale retry.
        let persistedRecords = await persistence.allRecords()
        let protectedTaskIDs = preInvalidationProtectedTaskIDs.union(
            await commitRecoveryProtectedTaskIDs(
                in: persistedRecords,
                additionalTaskIDs: Set(tasks.map(\.id))
            )
        )
        let persistedTaskIDs = Set(persistedRecords.map(\.id))
        let shutdownTaskIDs = persistedTaskIDs.union(tasks.map(\.id))
            .subtracting(protectedTaskIDs)
        do {
            try await persistence.markTerminal(ids: shutdownTaskIDs)
        } catch {
            Self.logger.fault(
                "shutdown terminal-marker write failed for \(shutdownTaskIDs.count, privacy: .public) ids: \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }

        var cancelledTasks: [DownloadTask] = []
        for task in tasks {
            if protectedTaskIDs.contains(task.id) {
                if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
                    urlTask.cancel()
                }
                await eventHub.finish(taskID: task.id)
                await runtimeRegistry.removeTaskRuntime(taskId: task.id)
                continue
            }
            let transition = await task.transitionToTerminal(.cancelled, error: .cancelled)
            if transition == .transitioned {
                await eventHub.publishTerminalAndFinish(
                    .stateChanged(.cancelled),
                    for: task.id
                )
                cancelledTasks.append(task)
            }
            if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
                urlTask.cancel()
            }
            await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        }

        // Sweep the sealed persistence snapshot as well as live task IDs.
        do {
            try await persistence.remove(ids: shutdownTaskIDs)
        } catch {
            Self.logger.fault(
                "shutdown persistence bulk-remove failed for \(shutdownTaskIDs.count, privacy: .public) ids: \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
        for task in tasks {
            await runtimeRegistry.remove(task)
        }

        // Invoke manager callbacks only after terminal events are admitted and
        // partitions are sealed. Reentrant shutdown now returns immediately,
        // while external shutdown callers retain the strong callback-drain
        // boundary established by the final barrier below.
        for task in cancelledTasks {
            await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
        }

        // `invalidateAndCancel()` (not `finishTasksAndInvalidate()`) above is
        // the correct lifecycle boundary: pending transfers die immediately
        // and the OS releases the session identifier and delegate.
        await invalidationBarrier.wait()
        // App callbacks never hold the delegate FIFO or Foundation's
        // background-events completion. They remain part of the strong
        // external shutdown contract, however: stop callback admission only
        // after every lifecycle producer and the session have drained, then
        // wait for all callbacks accepted before that boundary.
        await callbackDeliveryQueue.finishAndDrain()
        await eventHub.shutdown()
        Self.unregisterSessionIdentifier(configuration.sessionIdentifier)
        await shutdownBarrier.complete()
    }

    nonisolated var isShutdown: Bool {
        lifecycleGate.isShutdown
    }

    func beginShutdownTrackedOperation() -> Bool {
        guard !isShutdown else { return false }
        managerState.shutdownTrackedOperationCount += 1
        return true
    }

    func finishShutdownTrackedOperation() {
        precondition(managerState.shutdownTrackedOperationCount > 0)
        managerState.shutdownTrackedOperationCount -= 1
        guard managerState.shutdownTrackedOperationCount == 0 else { return }
        let waiters = managerState.shutdownTrackedOperationWaiters
        managerState.shutdownTrackedOperationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForShutdownTrackedOperationsToDrain() async {
        guard managerState.shutdownTrackedOperationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            if managerState.shutdownTrackedOperationCount == 0 {
                continuation.resume()
            } else {
                managerState.shutdownTrackedOperationWaiters.append(continuation)
            }
        }
    }

    /// Atomically flips the shutdown latch. Returns `true` when this call
    /// is the one that observed the latch transitioning from `false` to
    /// `true`; returns `false` if another caller (or this one re-entering)
    /// had already shut the manager down. Callers that get `false` must
    /// await ``invalidationBarrier`` instead of running the teardown path
    /// a second time.
    nonisolated private func markShutdownIfNeeded() -> Bool {
        lifecycleGate.beginShutdown()
    }
}
