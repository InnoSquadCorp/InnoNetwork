import Foundation

extension DownloadManager {
    /// Starts a download. An optional `CancellationTag` groups the task
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
        guard let urlTask = await runtimeRegistry.urlTask(for: task.id) else {
            // A failed attempt has been retired and its automatic retry is
            // still waiting for backoff or a network change: the logical task
            // stays `.downloading` but there is no transport to cancel.
            await pausePendingRetry(task, expectedLifecycle: expectedLifecycle)
            return
        }
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
                // The attempt failed while this pause was starting and its
                // retry marker became durable first. Pause the waiting retry
                // instead of failing a task that only lost its attempt.
                if await persistence.record(forID: task.id)?.lifecycle == .retryPending {
                    await pausePendingRetry(task, expectedLifecycle: await task.lifecycleSnapshot())
                    return
                }
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
            if await settlePauseOfEndedAttempt(task, producedResumeData: nil) { return }
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
            // A failure that retired the attempt in the meantime deferred to
            // this pause; finish it from what both left behind.
            if await settlePauseOfEndedAttempt(task, producedResumeData: resumeData) { return }
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

    /// Finishes a pause whose attempt ended while the pause was in flight.
    ///
    /// A failure of the attempt that finds the durable `.pausing` phase
    /// defers to the pause: it retires the attempt and neither retries nor
    /// fails the task. Unless something else has since taken the task — a
    /// newer attempt, a terminal outcome, or a phase other than `.pausing` —
    /// the pause owns the outcome and ends `.paused`, keeping the resume data
    /// this pause produced or, failing that, what the failure left on the
    /// task.
    ///
    /// - Returns: `true` when this method decided the outcome, so the caller
    ///   must not also act on the task.
    private func settlePauseOfEndedAttempt(
        _ task: DownloadTask,
        producedResumeData: Data?
    ) async -> Bool {
        guard await runtimeRegistry.urlTask(for: task.id) == nil,
            await persistence.record(forID: task.id)?.lifecycle == .pausing
        else {
            return false
        }
        let endedLifecycle = await task.lifecycleSnapshot()
        guard endedLifecycle.state == .downloading else { return false }
        // A successful attempt also leaves no runtime behind while its file
        // is being committed. Completion owns that task; only a claim that
        // closes completion admission makes the outcome this pause's.
        guard await claimDestructiveLifecycle(taskID: task.id) else { return false }
        await task.endRestoredSuccessAdmission()
        let retainedResumeData: Data?
        if let producedResumeData {
            retainedResumeData = producedResumeData
        } else {
            retainedResumeData = await task.resumeData
        }

        do {
            // Same order as an ordinary pause: the durable phase first, so a
            // resume never acts on a record that is still `.pausing`.
            let persistence = self.persistence
            let markedPaused = try await Task.detached {
                try await persistence.transitionResumeState(
                    id: task.id,
                    from: .pausing,
                    to: .paused,
                    resumeData: retainedResumeData
                )
            }.value
            guard markedPaused else {
                throw DownloadPersistenceStateError.missingPausingRecord(task.id)
            }
        } catch {
            await transferCoordinator.markTaskFailedForPersistence(
                task,
                error: error,
                ifMatching: endedLifecycle
            )
            return true
        }

        guard await task.transitionToPaused(resumeData: retainedResumeData, ifMatching: endedLifecycle) else {
            // As in an ordinary pause, never rewrite `.paused` to `.active`
            // once no attempt is left: the winner owns the record now.
            return true
        }
        let pausedLifecycle = await task.lifecycleSnapshot()
        await eventHub.publishIfCurrent(.stateChanged(.paused), for: task.id) {
            await task.lifecycleSnapshot() == pausedLifecycle
        }
        await callbackDeliveryQueue.enqueueStateChanged(task, .paused)
        return true
    }

    /// Pauses a logical task whose automatic retry has not started its next
    /// attempt yet. The task ends `.paused` with the same durable `.paused`
    /// phase an ordinary pause leaves behind, keeps any resume data the
    /// failed attempt produced, and is no longer restarted by the pending
    /// retry; `resume(_:)` starts the next attempt.
    private func pausePendingRetry(
        _ task: DownloadTask,
        expectedLifecycle: DownloadTaskLifecycleSnapshot
    ) async {
        // The durable retry marker is the only authoritative evidence of
        // this window. Every other attempt-less `.downloading` moment (a
        // failure still being admitted, a resume creating its attempt, a
        // completion being committed) is owned by that lifecycle path and
        // keeps the historical no-op.
        guard await persistence.record(forID: task.id)?.lifecycle == .retryPending else { return }

        // The in-memory pause below becomes visible before its durable
        // phase. `resume(_:)` consults this set so it cannot act on a pause
        // whose record still says `retryPending`.
        managerState.retryWaitPausingTaskIDs.insert(task.id)
        defer { managerState.retryWaitPausingTaskIDs.remove(task.id) }

        // Take the task away from the pending retry first. The retry claims
        // its restart with a compare-and-set on this same lifecycle
        // snapshot, so either this pause wins and the retry can never
        // restart the task, or the retry already owns the next attempt and
        // the pause is the same no-op as a pause issued during `.waiting`.
        guard await task.transitionToPausedRetainingResumeData(ifMatching: expectedLifecycle) else {
            return
        }
        let pausedLifecycle = await task.lifecycleSnapshot()
        let retainedResumeData = await task.resumeData

        do {
            // Shield the durable phase from caller cancellation: the task is
            // already paused in memory and must not be left behind a record
            // that still schedules a retry.
            let persistence = self.persistence
            let markedPaused = try await Task.detached {
                try await persistence.transitionResumeState(
                    id: task.id,
                    from: .retryPending,
                    to: .paused,
                    resumeData: retainedResumeData
                )
            }.value
            if !markedPaused {
                // A terminal path replaced the retry marker while this pause
                // was in flight and now owns the task and its record.
                guard await task.lifecycleSnapshot() == pausedLifecycle else { return }
                throw DownloadPersistenceStateError.missingPausingRecord(task.id)
            }
        } catch {
            await transferCoordinator.markTaskFailedForPersistence(
                task,
                error: error,
                ifMatching: pausedLifecycle
            )
            return
        }

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
        // A retry-wait pause is visible in memory before its durable phase.
        // As with any resume issued before a pause has finished, do nothing
        // rather than resume against a record that is not `.paused` yet.
        guard !managerState.retryWaitPausingTaskIDs.contains(task.id) else { return }
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
            // A persisted blob is untrusted input, and Foundation raises an
            // Objective-C exception for one that is not a property-list
            // dictionary. Check its shape before handing it over, as an
            // automatic retry does.
            let candidateTask: (any DownloadURLTask)? =
                DownloadAttemptResumeData.isStructurallyUsable(resumeData)
                ? session.makeDownloadTask(withResumeData: resumeData)
                : nil
            guard let urlTask = candidateTask,
                admitsResumedURLTask(urlTask, expectedURL: task.url)
            else {
                // Resume data is opaque and can carry a different request
                // than the persisted logical task. Never start or register an
                // untrusted task; discard the blob and restart from the URL
                // that already passed admission.
                candidateTask?.cancel()
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
            await transferCoordinator.finalizeResumedAttempt(
                task,
                urlTask: urlTask,
                consumedResumeData: resumeData
            )
        } else {
            guard await task.advanceAttempt(ifMatching: pausedLifecycle) != nil else { return }
            await transferCoordinator.startDownload(
                task,
                mode: .resumingPersistedPause
            )
        }
    }
}
