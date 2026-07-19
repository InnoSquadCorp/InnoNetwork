import Foundation

extension DownloadManager {
    /// Starts a download. An optional ``CancellationTag`` groups the task
    /// for ``cancelAll(matching:)``; tags are runtime-scoped and not
    /// persisted, so tasks restored from a background session carry none.
    @discardableResult
    public func download(
        url: URL,
        to destinationURL: URL,
        tag: CancellationTag? = nil
    ) async -> DownloadTask {
        let task = DownloadTask(url: url, destinationURL: destinationURL)
        guard beginShutdownTrackedOperation() else { return task }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else {
            // Preserve API shape for cancellation-aware callers without mutating manager state.
            return task
        }
        guard admitsDownloadURL(url) else {
            await runtimeRegistry.add(task, tag: tag)
            await failureCoordinator.markTaskFailed(
                task,
                reason: .invalidURL("Rejected by URL admission policy")
            )
            return task
        }
        await runtimeRegistry.add(task, tag: tag)
        await transferCoordinator.startDownload(task, mode: .initial)
        return task
    }

    @discardableResult
    public func download(
        url: URL,
        toDirectory directory: URL,
        fileName: String? = nil,
        tag: CancellationTag? = nil
    ) async -> DownloadTask {
        let destinationURL = DownloadDestinationResolver.resolve(
            sourceURL: url,
            directory: directory,
            fileName: fileName
        )
        guard await waitForRestore() else {
            return DownloadTask(url: url, destinationURL: destinationURL)
        }
        return await download(url: url, to: destinationURL, tag: tag)
    }

    public func pause(_ task: DownloadTask) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else { return }
        guard await runtimeRegistry.owns(task) else { return }
        guard managerState.pausingTaskIDs.insert(task.id).inserted else { return }
        defer { managerState.pausingTaskIDs.remove(task.id) }

        let expectedLifecycle = await task.lifecycleSnapshot()
        guard expectedLifecycle.state == .downloading else { return }
        guard let urlTask = await runtimeRegistry.urlTask(for: task.id) else { return }
        let expectedTaskIdentifier = urlTask.taskIdentifier
        managerState.pausingTaskIdentifiers[task.id] = expectedTaskIdentifier
        defer { managerState.pausingTaskIdentifiers.removeValue(forKey: task.id) }

        do {
            let markedPausing = try await persistence.transitionResumeState(
                id: task.id,
                fromAny: [.active, .resuming, nil],
                to: .pausing,
                // A retained blob belongs to the preceding attempt and must
                // never be mistaken for resume data produced by this pause.
                resumeData: nil
            )
            guard markedPausing else {
                throw DownloadPersistenceStateError.missingPausingRecord(task.id)
            }
        } catch is CancellationError {
            let persistence = self.persistence
            _ = await Task.detached {
                try? await persistence.transitionResumeState(
                    id: task.id,
                    from: .pausing,
                    to: .active,
                    resumeData: nil
                )
            }.value
            return
        } catch {
            urlTask.cancel()
            _ = await transferCoordinator.markTaskFailedForPersistence(
                task,
                error: error,
                ifMatching: expectedLifecycle
            )
            await runtimeRegistry.removeAttemptRuntime(taskIdentifier: expectedTaskIdentifier)
            return
        }

        guard await task.lifecycleSnapshot() == expectedLifecycle,
            let currentURLTask = await runtimeRegistry.urlTask(for: task.id),
            currentURLTask.taskIdentifier == expectedTaskIdentifier
        else {
            _ = try? await persistence.transitionResumeState(
                id: task.id,
                from: .pausing,
                to: .active,
                resumeData: nil,
            )
            return
        }

        let resumeDataResult = await lifecycleGate.raceOnlyWithShutdown {
            await urlTask.cancelByProducingResumeData()
        }
        guard case .value(let resumeData) = resumeDataResult else { return }

        // Linearize pause against the delegate's synchronous ownership transfer.
        // If didFinishDownloading already owns or established a deterministic
        // journal, completion wins and the still-registered task consumes the
        // queued journal event. Otherwise this closes the retired concrete
        // attempt before its mapping and resume state are finalized.
        guard await claimDestructiveLifecycle(taskID: task.id) else { return }
        await task.endRestoredSuccessAdmission()

        guard await task.lifecycleSnapshot() == expectedLifecycle,
            let currentURLTask = await runtimeRegistry.urlTask(for: task.id),
            currentURLTask.taskIdentifier == expectedTaskIdentifier
        else {
            // The physical attempt has already been cancelled. Keeping the
            // durable `.pausing` marker is the crash-safe outcome: restoration
            // reconstructs a paused handle and restarts from the admitted URL.
            return
        }

        // The attempt is cancelled regardless of when URLSession delivers its
        // cancellation delegate event. Retire only this identifier: actor
        // reentrancy may already have allowed a newer runtime to register.
        await runtimeRegistry.removeAttemptRuntime(taskIdentifier: expectedTaskIdentifier)

        do {
            let persistence = self.persistence
            let markedPaused = try await Task.detached {
                try await persistence.transitionResumeState(
                    id: task.id,
                    from: .pausing,
                    to: .paused,
                    resumeData: resumeData,
                )
            }.value
            guard markedPaused else {
                throw DownloadPersistenceStateError.missingPausingRecord(task.id)
            }
        } catch {
            await transferCoordinator.markTaskFailedForPersistence(task, error: error)
            return
        }

        guard await task.transitionToPaused(resumeData: resumeData, ifMatching: expectedLifecycle) else {
            // Do not rewrite `.paused` to `.active`: there is no longer a live
            // URLSession task. A terminal winner normally removes the record;
            // if cleanup fails, leaving the recoverable pause is safer than an
            // active record with no system attempt.
            return
        }

        let pausedLifecycle = await task.lifecycleSnapshot()
        await eventHub.publishIfCurrent(.stateChanged(.paused), for: task.id) {
            await task.lifecycleSnapshot() == pausedLifecycle
        }
        await callbackDeliveryQueue.enqueueStateChanged(task, .paused)
    }

    public func resume(_ task: DownloadTask) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else { return }
        guard await runtimeRegistry.owns(task) else { return }
        guard managerState.resumingTaskIDs.insert(task.id).inserted else { return }
        defer { managerState.resumingTaskIDs.remove(task.id) }
        let pausedLifecycle = await task.lifecycleSnapshot()
        guard pausedLifecycle.state == .paused else { return }
        guard await claimDestructiveLifecycle(taskID: task.id) else { return }
        await task.endRestoredSuccessAdmission()
        guard admitsDownloadURL(task.url) else {
            await failureCoordinator.markTaskFailed(
                task,
                reason: .invalidURL("Rejected by URL admission policy")
            )
            return
        }
        do {
            try DownloadDestinationPreflight.validate(task.destinationURL)
        } catch {
            await transferCoordinator.markTaskFailedForPersistence(
                task,
                error: error,
                ifMatching: pausedLifecycle
            )
            return
        }

        // A paused logical task must never retain a concrete attempt. Clean up
        // any legacy/restoration drift before creating a replacement so late
        // callbacks from that attempt cannot race the resumed generation.
        if let staleURLTask = await runtimeRegistry.urlTask(for: task.id) {
            staleURLTask.cancel()
            await runtimeRegistry.removeAttemptRuntime(taskIdentifier: staleURLTask.taskIdentifier)
        }

        let retainedResumeData = await task.resumeData
        guard await task.lifecycleSnapshot() == pausedLifecycle else { return }
        do {
            let markedResuming = try await persistence.transitionResumeState(
                id: task.id,
                fromAny: [.paused, .pausing, .resuming, nil],
                to: .resuming,
                resumeData: retainedResumeData,
            )
            guard markedResuming else {
                throw DownloadPersistenceStateError.missingResumingRecord(task.id)
            }
            guard let record = await persistence.record(forID: task.id),
                record.lifecycle == .resuming,
                record.resumeData == retainedResumeData
            else {
                throw DownloadPersistenceStateError.missingResumingRecord(task.id)
            }
        } catch is CancellationError {
            let persistence = self.persistence
            _ = await Task.detached {
                try? await persistence.transitionResumeState(
                    id: task.id,
                    from: .resuming,
                    to: .paused,
                    resumeData: retainedResumeData
                )
            }.value
            return
        } catch {
            await transferCoordinator.markTaskFailedForPersistence(task, error: error)
            return
        }
        guard await task.lifecycleSnapshot() == pausedLifecycle else { return }
        if let resumeData = retainedResumeData {
            let urlTask = session.makeDownloadTask(withResumeData: resumeData)
            guard admitsResumedURLTask(urlTask, expectedURL: task.url) else {
                // Resume data is opaque and can carry a different request
                // than the persisted logical task. Never start or register an
                // untrusted task; discard the blob and restart from the URL
                // that already passed admission.
                urlTask.cancel()
                await task.setResumeData(nil)
                do {
                    let discardedOpaqueData = try await persistence.transitionResumeState(
                        id: task.id,
                        from: .resuming,
                        to: .resuming,
                        resumeData: nil,
                    )
                    guard discardedOpaqueData else {
                        throw DownloadPersistenceStateError.missingResumingRecord(task.id)
                    }
                } catch is CancellationError {
                    await task.setResumeData(retainedResumeData)
                    let persistence = self.persistence
                    _ = await Task.detached {
                        try? await persistence.transitionResumeState(
                            id: task.id,
                            from: .resuming,
                            to: .paused,
                            resumeData: retainedResumeData
                        )
                    }.value
                    return
                } catch {
                    await transferCoordinator.markTaskFailedForPersistence(task, error: error)
                    return
                }
                guard await task.lifecycleSnapshot() == pausedLifecycle else { return }
                guard await task.advanceAttempt(ifMatching: pausedLifecycle) != nil else {
                    return
                }
                await transferCoordinator.startDownload(
                    task,
                    mode: .resumingPersistedPause
                )
                return
            }
            guard
                let downloadingLifecycle = await task.startNextAttempt(
                    transitioningTo: .downloading,
                    ifMatching: pausedLifecycle
                )
            else {
                urlTask.cancel()
                return
            }
            await transferCoordinator.register(urlTask: urlTask, for: task)
            guard await task.lifecycleSnapshot() == downloadingLifecycle else {
                urlTask.cancel()
                await runtimeRegistry.removeAttemptRuntime(taskIdentifier: urlTask.taskIdentifier)
                return
            }
            await eventHub.publishIfCurrent(.stateChanged(.downloading), for: task.id) {
                await task.lifecycleSnapshot() == downloadingLifecycle
            }
            guard await task.lifecycleSnapshot() == downloadingLifecycle else {
                urlTask.cancel()
                await runtimeRegistry.removeAttemptRuntime(taskIdentifier: urlTask.taskIdentifier)
                return
            }
            await callbackDeliveryQueue.enqueueStateChangedAndWait(task, .downloading)
            guard
                await task.resume(
                    urlTask,
                    ifMatching: downloadingLifecycle,
                    lifecycleGate: lifecycleGate
                )
            else {
                urlTask.cancel()
                await runtimeRegistry.removeAttemptRuntime(taskIdentifier: urlTask.taskIdentifier)
                return
            }
            do {
                let persistence = self.persistence
                let finalizedResume = try await Task.detached {
                    try await persistence.transitionResumeState(
                        id: task.id,
                        from: .resuming,
                        to: .active,
                        resumeData: nil
                    )
                }.value
                if !finalizedResume {
                    let record = await persistence.record(forID: task.id)
                    let currentState = await task.state
                    if record?.lifecycle == .pausing || record?.lifecycle == .paused
                        || currentState.isTerminal
                    {
                        // A concurrent pause/cancel owns the concrete attempt
                        // and its durable phase. Never clobber it back to active.
                        return
                    }
                    throw DownloadPersistenceStateError.failedToFinalizeResumingRecord(task.id)
                }
            } catch {
                Self.logger.fault(
                    "Failed to finalize active persistence for task \(task.id, privacy: .private(mask: .hash)) on resume: \(String(describing: error), privacy: .private(mask: .hash))"
                )
                urlTask.cancel()
                await runtimeRegistry.removeAttemptRuntime(taskIdentifier: urlTask.taskIdentifier)
                await transferCoordinator.markTaskFailedForPersistence(task, error: error)
                return
            }
            await task.setResumeData(nil)
        } else {
            guard await task.advanceAttempt(ifMatching: pausedLifecycle) != nil else { return }
            await transferCoordinator.startDownload(
                task,
                mode: .resumingPersistedPause
            )
        }
    }

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
