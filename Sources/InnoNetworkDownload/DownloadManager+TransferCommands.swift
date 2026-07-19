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
}
