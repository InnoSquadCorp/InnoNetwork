import Darwin
import Foundation
import InnoNetwork
import OSLog

package enum DownloadStartMode: Sendable, Equatable {
    case initial
    case automaticRetry
    case manualRetry
    case resumingPersistedPause

    var persistenceMode: DownloadTaskPersistence.StartMode? {
        switch self {
        case .initial:
            return .initial
        case .automaticRetry:
            return .automaticRetry
        case .manualRetry:
            return .manualRetry
        case .resumingPersistedPause:
            return nil
        }
    }
}

package struct DownloadTransferCoordinator {
    private static let logger = Logger(subsystem: "innosquad.network.download", category: "Persistence")

    let session: any DownloadURLSession
    let runtimeRegistry: DownloadRuntimeRegistry
    let callbackDeliveryQueue: DownloadCallbackDeliveryQueue
    let persistence: DownloadTaskPersistence
    let eventHub: TaskEventHub<DownloadEvent>
    let lifecycleGate: DownloadLifecycleGate
    let completionStager: DownloadCompletionStager
    let completionAdmissionGate: DownloadCompletionAdmissionGate

    package init(
        session: any DownloadURLSession,
        runtimeRegistry: DownloadRuntimeRegistry,
        callbackDeliveryQueue: DownloadCallbackDeliveryQueue? = nil,
        persistence: DownloadTaskPersistence,
        eventHub: TaskEventHub<DownloadEvent>,
        lifecycleGate: DownloadLifecycleGate,
        completionStager: DownloadCompletionStager = DownloadCompletionStager(),
        completionAdmissionGate: DownloadCompletionAdmissionGate = DownloadCompletionAdmissionGate()
    ) {
        self.session = session
        self.runtimeRegistry = runtimeRegistry
        self.callbackDeliveryQueue =
            callbackDeliveryQueue
            ?? DownloadCallbackDeliveryQueue(runtimeRegistry: runtimeRegistry)
        self.persistence = persistence
        self.eventHub = eventHub
        self.lifecycleGate = lifecycleGate
        self.completionStager = completionStager
        self.completionAdmissionGate = completionAdmissionGate
    }

    package func startDownload(
        _ task: DownloadTask,
        mode: DownloadStartMode
    ) async {
        let initialLifecycle = await task.lifecycleSnapshot()
        do {
            try DownloadDestinationPreflight.validate(task.destinationURL)
        } catch {
            await markTaskFailedForPersistence(
                task,
                error: error,
                ifMatching: initialLifecycle
            )
            return
        }
        guard
            let waitingLifecycle = await task.transition(
                to: .waiting,
                ifMatching: initialLifecycle
            )
        else {
            return
        }
        await eventHub.publishIfCurrent(.stateChanged(.waiting), for: task.id) {
            await task.lifecycleSnapshot() == waitingLifecycle
        }
        guard await task.lifecycleSnapshot() == waitingLifecycle else { return }
        await callbackDeliveryQueue.enqueueStateChangedAndWait(task, .waiting)
        guard await task.lifecycleSnapshot() == waitingLifecycle,
            !lifecycleGate.isShutdown
        else {
            await rollbackSupersededStart(
                task,
                mode: mode
            )
            return
        }
        if let persistenceMode = mode.persistenceMode {
            guard await task.claimStartPersistence(ifMatching: waitingLifecycle) else {
                return
            }
            let retryCount = await task.retryCount
            let totalRetryCount = await task.totalRetryCount
            let didBegin: Bool
            do {
                didBegin = try await persistence.beginStart(
                    id: task.id,
                    url: task.url,
                    destinationURL: task.destinationURL,
                    mode: persistenceMode,
                    retryCount: retryCount,
                    totalRetryCount: totalRetryCount
                )
            } catch {
                await task.releaseStartPersistenceClaim()
                if await task.lifecycleSnapshot() == waitingLifecycle {
                    await markTaskFailedForPersistence(
                        task,
                        error: error,
                        ifMatching: waitingLifecycle
                    )
                }
                return
            }
            await task.releaseStartPersistenceClaim()
            guard didBegin else {
                // A terminal winner or a newer persistence phase invalidated
                // this start. In particular, automatic retry is a strict
                // retryPending->active CAS and stale jobs simply disappear.
                if mode != .automaticRetry,
                    await task.lifecycleSnapshot() == waitingLifecycle
                {
                    await markTaskFailedForPersistence(
                        task,
                        error: DownloadTransferPersistenceStateError.failedToBeginStart(task.id),
                        ifMatching: waitingLifecycle
                    )
                }
                return
            }
        }
        guard await task.lifecycleSnapshot() == waitingLifecycle,
            !lifecycleGate.isShutdown
        else {
            await rollbackSupersededStart(
                task,
                mode: mode
            )
            return
        }

        let urlTask = session.makeDownloadTask(with: task.url)
        await register(urlTask: urlTask, for: task)

        guard
            let downloadingLifecycle = await task.transition(
                to: .downloading,
                ifMatching: waitingLifecycle
            )
        else {
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
        if mode == .resumingPersistedPause {
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
                        // Pause/cancel won after this attempt started. Its
                        // durable marker is authoritative and must not be
                        // overwritten by the resume finalizer.
                        return
                    }
                    throw DownloadTransferPersistenceStateError.failedToFinalizeResume(task.id)
                }
                await task.setResumeData(nil)
            } catch {
                urlTask.cancel()
                await runtimeRegistry.removeAttemptRuntime(taskIdentifier: urlTask.taskIdentifier)
                await markTaskFailedForPersistence(task, error: error)
            }
        }
    }

    package func register(urlTask: any DownloadURLTask, for task: DownloadTask) async {
        urlTask.taskDescription = task.id
        completionAdmissionGate.openAttempt(
            taskID: task.id,
            taskIdentifier: urlTask.taskIdentifier
        )
        let displacedURLTask = await runtimeRegistry.register(urlTask: urlTask, for: task)
        displacedURLTask?.cancel()
    }

    package func resumeRestoredURLTask(
        _ urlTask: any DownloadURLTask,
        for task: DownloadTask
    ) async -> Bool {
        _ = task
        guard lifecycleGate.resumeIfOpen(urlTask) else {
            urlTask.cancel()
            await runtimeRegistry.removeAttemptRuntime(taskIdentifier: urlTask.taskIdentifier)
            return false
        }
        return true
    }

    package func rollbackSupersededStart(
        _ task: DownloadTask,
        mode: DownloadStartMode
    ) async {
        let state = await task.state
        guard !state.isTerminal else { return }
        guard mode != .resumingPersistedPause, mode != .automaticRetry else { return }
        do {
            try await persistence.remove(id: task.id)
        } catch {
            Self.logger.fault(
                "Failed to roll back superseded download start \(task.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
    }

    /// Package-test compatibility entry point. Production delegate completions
    /// are synchronously journaled before they leave URLSession's callback.
    @discardableResult
    package func completeDownload(task: DownloadTask, temporaryLocation: URL) async throws -> Bool {
        let completion = try completionStager.stage(
            temporaryLocation,
            taskID: task.id,
            originalRequestURL: task.url,
            currentRequestURL: task.url
        )
        do {
            return try await completeDownload(task: task, stagedCompletion: completion)
        } catch {
            // Direct package tests historically own this temporary file. They
            // do not model restart recovery, so retain their bounded cleanup
            // contract while production keeps journal evidence on failure.
            try? completionStager.cleanup(completion)
            throw error
        }
    }

    /// Commits a deterministic staged completion through a durable two-phase
    /// journal. The source payload remains intact until both the final file
    /// and terminal persistence marker are durable.
    @discardableResult
    package func completeDownload(
        task: DownloadTask,
        stagedCompletion: StagedCompletion
    ) async throws -> Bool {
        guard await task.claimTerminalTransition() else { return false }

        let manifest = stagedCompletion.manifest
        let metadata: DownloadTaskPersistence.CommitMetadata

        do {
            try completionStager.validate(stagedCompletion)
            guard manifest.taskID == task.id,
                manifest.originalRequestURL == task.url
            else {
                throw DownloadCommitJournalError.correlationMismatch(task.id)
            }
            metadata = DownloadTaskPersistence.CommitMetadata(
                stagingKey: manifest.key,
                originalRequestURL: manifest.originalRequestURL,
                currentRequestURL: manifest.currentRequestURL,
                destinationURL: task.destinationURL,
                expectedByteCount: manifest.expectedByteCount,
                payloadSHA256: try completionStager.payloadSHA256(
                    for: stagedCompletion
                )
            )

            let didBegin = try await persistence.beginCommit(
                id: task.id,
                metadata: metadata
            )
            if !didBegin {
                let record = await persistence.record(forID: task.id)
                if record?.lifecycle == .committing,
                    record?.commitMetadata == metadata
                {
                    // A pre-actor crash or duplicate delegate delivery already
                    // established the same authoritative commit. Replay it.
                } else {
                    await task.releaseTerminalTransitionClaim()
                    if record?.lifecycle == .terminal {
                        try? completionStager.cleanup(stagedCompletion)
                        completionAdmissionGate.release(taskID: task.id)
                    }
                    return false
                }
            }

            try installFinalFile(
                from: stagedCompletion.payloadURL,
                to: task.destinationURL,
                stagingKey: metadata.stagingKey
            )

            guard
                try await persistence.finishCommit(
                    id: task.id,
                    metadata: metadata
                )
            else {
                throw DownloadCommitJournalError.failedToFinish(task.id)
            }
        } catch {
            await markCommitDeferredFailure(
                task,
                error: error,
                terminalClaimHeld: true
            )
            throw error
        }

        guard await task.finishClaimedTerminalTransition(to: .completed, error: nil) else {
            throw DownloadCommitJournalError.failedToFinishTask(task.id)
        }
        let completedLifecycle = await task.lifecycleSnapshot()
        await eventHub.publishIfCurrent(.stateChanged(.completed), for: task.id) {
            await task.lifecycleSnapshot() == completedLifecycle
        }
        await eventHub.publishTerminalAndFinish(
            .completed(task.destinationURL),
            for: task.id
        )

        // Terminal durability is established. Cleanup is now best effort: a
        // crash or cleanup error leaves only bounded residue that restoration
        // can identify from the terminal metadata.
        var didCleanCommitResidue = false
        do {
            try completionStager.cleanup(stagedCompletion)
            try removeDestinationStage(
                for: task.destinationURL,
                stagingKey: metadata.stagingKey
            )
            didCleanCommitResidue = true
        } catch {
            Self.logger.fault(
                "Failed to clean completed task journal \(task.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). Terminal metadata remains durable for the next launch."
            )
        }
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        await callbackDeliveryQueue.enqueueStateChanged(task, .completed)
        await callbackDeliveryQueue.enqueueCompleted(task, task.destinationURL)

        // The durable receipt is the crash boundary between installing the
        // final file and admitting the terminal event/app callbacks. Remove it
        // only after those deliveries have been accepted, and only while the
        // exact commit metadata still owns the terminal row. A stale success
        // must never erase a newer retry generation.
        var didAcknowledge = false
        do {
            didAcknowledge = try await persistence.acknowledgeCommitOutcome(
                id: task.id,
                metadata: metadata,
                outcome: .finished
            )
        } catch {
            Self.logger.fault(
                "Failed to acknowledge completed task \(task.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). The finished receipt remains durable for restoration."
            )
        }
        if didAcknowledge {
            completionAdmissionGate.release(taskID: task.id)
            await runtimeRegistry.remove(task)
        } else if didCleanCommitResidue {
            // The final file plus exact terminal metadata is sufficient for
            // replay after bounded residue cleanup. Keep destructive
            // lifecycle admission closed until the receipt is acknowledged.
            completionAdmissionGate.registerJournal(taskID: task.id)
        }
        return true
    }

    /// Surfaces a commit failure without routing it through transport retry or
    /// generic terminal persistence. The journal remains authoritative for a
    /// later launch to replay.
    package func markCommitDeferredFailure(
        _ task: DownloadTask,
        error: Error,
        terminalClaimHeld: Bool = false
    ) async {
        let downloadError = DownloadError.fileSystemError(SendableUnderlyingError(error))
        let didTransition: Bool
        if terminalClaimHeld {
            didTransition = await task.finishClaimedTerminalTransition(
                to: .failed,
                error: downloadError
            )
        } else {
            didTransition =
                await task.transitionToTerminal(
                    .failed,
                    error: downloadError
                ) == .transitioned
        }
        guard didTransition else { return }
        let failedLifecycle = await task.lifecycleSnapshot()
        await eventHub.publishIfCurrent(.stateChanged(.failed), for: task.id) {
            await task.lifecycleSnapshot() == failedLifecycle
        }
        await eventHub.publishTerminalAndFinish(.failed(downloadError), for: task.id)
        await callbackDeliveryQueue.enqueueStateChanged(task, .failed)
        await callbackDeliveryQueue.enqueueFailed(task, downloadError)
    }

    package func destinationStageURL(
        for destinationURL: URL,
        stagingKey: String
    ) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).innonetwork-\(stagingKey).commit",
            isDirectory: false
        )
    }

    package func removeDestinationStage(
        for destinationURL: URL,
        stagingKey: String
    ) throws {
        guard DownloadCompletionStager.isValidKey(stagingKey) else {
            throw DownloadCompletionStagingError.invalidKey
        }
        let stageURL = destinationStageURL(
            for: destinationURL,
            stagingKey: stagingKey
        )
        if try removeReplaceableNode(at: stageURL) {
            try synchronizeDirectory(at: stageURL.deletingLastPathComponent())
        }
    }

    private func installFinalFile(
        from sourceURL: URL,
        to destinationURL: URL,
        stagingKey: String
    ) throws {
        guard DownloadCompletionStager.isValidKey(stagingKey) else {
            throw DownloadCompletionStagingError.invalidKey
        }
        try DownloadDestinationPreflight.validate(destinationURL)
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try DownloadDestinationPreflight.validate(destinationURL)

        let stageURL = destinationStageURL(
            for: destinationURL,
            stagingKey: stagingKey
        )
        _ = try removeReplaceableNode(at: stageURL)
        try copyDataOnly(from: sourceURL, to: stageURL)
        try synchronizeFile(at: stageURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stageURL)
        } else {
            try fileManager.moveItem(at: stageURL, to: destinationURL)
        }
        try synchronizeFile(at: destinationURL)
        try synchronizeDirectory(at: directoryURL)
    }

    private func copyDataOnly(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return copyfile(
                    sourcePath,
                    destinationPath,
                    nil,
                    copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    @discardableResult
    private func removeReplaceableNode(at url: URL) throws -> Bool {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &status)
        }
        if result != 0 {
            guard errno == ENOENT || errno == ENOTDIR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return false
        }
        switch status.st_mode & S_IFMT {
        case S_IFREG, S_IFLNK:
            try FileManager.default.removeItem(at: url)
            return true
        default:
            throw DownloadCommitJournalError.unsafeDestinationStage(url)
        }
    }

    private func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    @discardableResult
    func markTaskFailedForPersistence(
        _ task: DownloadTask,
        error: Error,
        ifMatching expectedLifecycle: DownloadTaskLifecycleSnapshot? = nil
    ) async -> Bool {
        let downloadError = DownloadError.fileSystemError(SendableUnderlyingError(error))
        let transition: DownloadTerminalTransitionResult
        if let expectedLifecycle {
            transition = await task.transitionToFailureFinalizing(
                error: downloadError,
                ifMatching: expectedLifecycle
            )
        } else {
            transition = await task.transitionToFailureFinalizing(error: downloadError)
        }
        guard transition == .transitioned else { return false }
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        do {
            try await persistence.markTerminal(task: task)
        } catch {
            Self.logger.fault(
                "Failed to persist failure tombstone for task \(task.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
        var removedFromPersistence = false
        do {
            try await persistence.remove(id: task.id)
            removedFromPersistence = true
        } catch {
            Self.logger.fault(
                "Failed to remove persistence-failed task \(task.id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
        if removedFromPersistence {
            // Finish old-generation cleanup before exposing a retryable event
            // so a callback-created generation cannot be deleted afterward.
            await runtimeRegistry.remove(task)
        }
        let failedLifecycle = await task.lifecycleSnapshot()
        await eventHub.publishIfCurrent(.stateChanged(.failed), for: task.id) {
            await task.lifecycleSnapshot() == failedLifecycle
        }
        await eventHub.publishTerminalAndFinish(
            .failed(downloadError),
            for: task.id
        )
        await task.finishFailureFinalization()
        await callbackDeliveryQueue.enqueueStateChanged(task, .failed)
        await callbackDeliveryQueue.enqueueFailed(task, downloadError)
        return true
    }
}

private enum DownloadTransferPersistenceStateError: Error {
    case failedToBeginStart(String)
    case failedToFinalizeResume(String)
}

private enum DownloadCommitJournalError: Error {
    case correlationMismatch(String)
    case failedToFinish(String)
    case failedToFinishTask(String)
    case unsafeDestinationStage(URL)
}
