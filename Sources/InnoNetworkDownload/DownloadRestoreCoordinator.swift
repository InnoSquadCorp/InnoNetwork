import Foundation
import InnoNetwork
import OSLog

package struct DownloadRestoredRetry: Sendable {
    package let task: DownloadTask
    package let plan: DownloadTaskPersistence.RetryPlan
}

package struct DownloadRestoreResult: Sendable {
    package let failedTaskIDs: [String]
    package let completedTaskIDs: [String]
    package let deferredRetries: [DownloadRestoredRetry]

    package static let empty = Self(
        failedTaskIDs: [],
        completedTaskIDs: [],
        deferredRetries: []
    )
}

private struct DownloadJournalRestoreResult: Sendable {
    var handledTaskIDs = Set<String>()
    var failedTaskIDs: [String] = []
    var completedTaskIDs: [String] = []
}

package struct DownloadRestoreCoordinator {
    private static let logger = Logger(subsystem: "innosquad.network.download", category: "Persistence")

    let configuration: DownloadConfiguration
    let session: any DownloadURLSession
    let runtimeRegistry: DownloadRuntimeRegistry
    let persistence: DownloadTaskPersistence
    let transferCoordinator: DownloadTransferCoordinator
    let completionStager: DownloadCompletionStager
    let completionAdmissionGate: DownloadCompletionAdmissionGate

    package init(
        configuration: DownloadConfiguration,
        session: any DownloadURLSession,
        runtimeRegistry: DownloadRuntimeRegistry,
        persistence: DownloadTaskPersistence,
        transferCoordinator: DownloadTransferCoordinator,
        completionStager: DownloadCompletionStager = DownloadCompletionStager(),
        completionAdmissionGate: DownloadCompletionAdmissionGate = DownloadCompletionAdmissionGate()
    ) {
        self.configuration = configuration
        self.session = session
        self.runtimeRegistry = runtimeRegistry
        self.persistence = persistence
        self.transferCoordinator = transferCoordinator
        self.completionStager = completionStager
        self.completionAdmissionGate = completionAdmissionGate
    }

    /// Restore in-memory state from background URLSession tasks and persisted
    /// records.
    ///
    /// Returns missing-system-task failures plus durable retry waits that the
    /// manager must schedule outside the one-shot restoration barrier.
    package func restorePendingDownloads() async -> DownloadRestoreResult {
        let downloadTasks = await session.allDownloadTasks()
        guard !Task.isCancelled else { return .empty }
        let initialRecords = await persistence.allRecords()
        let journalRestore = await reconcileCompletionJournals(
            downloadTasks: downloadTasks,
            records: initialRecords
        )
        guard !Task.isCancelled else { return .empty }

        // Journal replay can move rows through committing -> terminal ->
        // removal. Re-read persistence before ordinary URLSession correlation
        // so stale pre-replay records cannot resurrect a completed task.
        let currentRecords = await persistence.allRecords()
        let recordsByID = Dictionary(uniqueKeysWithValues: currentRecords.map { ($0.id, $0) })
        let recordsByURL = Dictionary(grouping: currentRecords, by: \.url)

        var restoredTaskIDs = journalRestore.handledTaskIDs
        var correlatedRecordByIdentifier: [Int: DownloadTaskPersistence.Record] = [:]
        var authoritativeAttemptByTaskID: [String: Int] = [:]

        for urlTask in downloadTasks where urlTask.state != .canceling {
            guard
                let record = correlatedRecord(
                    for: urlTask,
                    recordsByID: recordsByID,
                    recordsByURL: recordsByURL
                )
            else {
                continue
            }
            correlatedRecordByIdentifier[urlTask.taskIdentifier] = record
            guard !hasPersistedPauseIntent(record), permitsLiveTransport(record) else { continue }
            authoritativeAttemptByTaskID[record.id] = max(
                authoritativeAttemptByTaskID[record.id] ?? Int.min,
                urlTask.taskIdentifier
            )
        }

        for urlTask in downloadTasks {
            guard !Task.isCancelled else { return .empty }
            if urlTask.state == .canceling {
                guard
                    let record = correlatedRecord(
                        for: urlTask,
                        recordsByID: recordsByID,
                        recordsByURL: recordsByURL
                    )
                else {
                    continue
                }
                if authoritativeAttemptByTaskID[record.id] != nil
                    || restoresAsPausedWithoutSystemTask(record)
                    || record.lifecycle == .retryPending
                {
                    // A viable replacement owns the row, or this canceling
                    // transport is the expected residue of pause/resume.
                    continue
                }
                if record.lifecycle == .terminal, record.commitOutcome == nil {
                    // A durable tombstone proves that this canceling transport
                    // belongs to an intentional terminal path. It is safe to
                    // prune silently even when no live replacement exists.
                    restoredTaskIDs.insert(record.id)
                    do {
                        try await persistence.remove(id: record.id)
                    } catch {
                        Self.logger.fault(
                            "Failed to prune terminal cancelling task \(record.id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash)). The tombstone will be reconciled again on the next launch."
                        )
                    }
                }
                // An active/legacy row paired only with a canceling system
                // task has no durable cancellation intent. Leave it for the
                // missing-system reconciliation pass so consumers observe a
                // typed restoration failure instead of silent disappearance.
                continue
            }

            guard let record = correlatedRecordByIdentifier[urlTask.taskIdentifier] else {
                urlTask.cancel()
                continue
            }
            guard !hasPersistedPauseIntent(record) else {
                // A public pause owns no concrete attempt. Cancel crash residue
                // and reconstruct the logical paused handle in the second pass.
                urlTask.cancel()
                continue
            }
            guard permitsLiveTransport(record) else {
                urlTask.cancel()
                continue
            }
            guard authoritativeAttemptByTaskID[record.id] == urlTask.taskIdentifier else {
                urlTask.cancel()
                continue
            }
            if urlTask.state != .completed {
                do {
                    try DownloadDestinationPreflight.validate(record.destinationURL)
                } catch {
                    urlTask.cancel()
                    guard let rejectedTask = await restoreTrackedTask(record: record) else {
                        continue
                    }
                    restoredTaskIDs.insert(rejectedTask.id)
                    await transferCoordinator.markTaskFailedForPersistence(
                        rejectedTask,
                        error: error
                    )
                    continue
                }
            }
            guard let downloadTask = await restoreTrackedTask(record: record) else {
                urlTask.cancel()
                continue
            }
            guard !Task.isCancelled else {
                urlTask.cancel()
                return .empty
            }
            restoredTaskIDs.insert(downloadTask.id)
            await transferCoordinator.register(urlTask: urlTask, for: downloadTask)

            let state: DownloadState
            switch urlTask.state {
            case .running:
                state = .downloading
            case .suspended:
                // Active/resuming persistence means transport suspension, not
                // a public pause. Resume this exact task instead of creating a
                // duplicate through `DownloadManager.resume(_:)`.
                guard await transferCoordinator.resumeRestoredURLTask(urlTask, for: downloadTask) else {
                    continue
                }
                state = .downloading
            case .canceling:
                state = .cancelled
            case .completed:
                // The staged didFinishDownloading callback can still arrive.
                state = .downloading
            @unknown default:
                guard await transferCoordinator.resumeRestoredURLTask(urlTask, for: downloadTask) else {
                    continue
                }
                state = .downloading
            }

            await downloadTask.restoreState(state)
            if record.lifecycle == .resuming {
                do {
                    _ = try await persistence.transitionResumeState(
                        id: record.id,
                        from: .resuming,
                        to: .active,
                        resumeData: nil
                    )
                    await downloadTask.setResumeData(nil)
                } catch {
                    Self.logger.fault(
                        "Failed to finalize restored resuming task \(record.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). The recoverable marker remains durable."
                    )
                }
            }
        }

        var pendingFailedTaskIDs = journalRestore.failedTaskIDs
        var deferredRetries: [DownloadRestoredRetry] = []
        let persistedTasks = await persistence.allRecords()
        guard !Task.isCancelled else { return .empty }
        for record in persistedTasks where !restoredTaskIDs.contains(record.id) {
            guard !Task.isCancelled else { return .empty }
            guard admitsDownloadURL(record.url) else {
                await pruneRejectedRecord(record.id)
                continue
            }
            if record.lifecycle == .terminal {
                await pruneRejectedRecord(record.id)
                continue
            }
            if record.lifecycle == .committing {
                // Only the exact-metadata journal reconciler may resolve this
                // absorbing phase. A malformed row is quarantined instead of
                // being exposed as retryable and then silently surviving every
                // generic terminal/remove mutation.
                Self.logger.fault(
                    "Quarantined unreconciled committing task \(record.id, privacy: .private(mask: .hash))."
                )
                continue
            }
            if record.lifecycle == .retryPending {
                let restoredTask = DownloadTask(
                    url: record.url,
                    destinationURL: record.destinationURL,
                    id: record.id
                )
                await restoredTask.restoreRetryCounts(
                    retryCount: record.retryCount ?? 0,
                    totalRetryCount: record.totalRetryCount ?? 0
                )
                guard !Task.isCancelled else { return .empty }
                await runtimeRegistry.add(restoredTask)
                deferredRetries.append(
                    DownloadRestoredRetry(
                        task: restoredTask,
                        // Backward compatibility: pre-plan retryPending rows
                        // restart promptly, but still outside the one-shot
                        // restoration barrier.
                        plan: record.retryPlan
                            ?? .backoff(retryNotBefore: .distantPast)
                    )
                )
                continue
            }
            if restoresAsPausedWithoutSystemTask(record) {
                if record.lifecycle != .paused {
                    do {
                        _ = try await persistence.transitionResumeState(
                            id: record.id,
                            from: record.lifecycle,
                            to: .paused,
                            resumeData: record.resumeData
                        )
                    } catch {
                        Self.logger.fault(
                            "Failed to normalize recovered pause state for task \(record.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). The intermediate marker remains recoverable."
                        )
                    }
                }
                let restoredTask = DownloadTask(
                    url: record.url,
                    destinationURL: record.destinationURL,
                    id: record.id,
                    resumeData: record.resumeData
                )
                await restoredTask.restoreState(.paused)
                if record.lifecycle == .pausing || record.lifecycle == .resuming {
                    await restoredTask.admitRestoredSuccessWhilePaused()
                }
                guard !Task.isCancelled else { return .empty }
                await runtimeRegistry.add(restoredTask)
                continue
            }

            let failedTask = DownloadTask(url: record.url, destinationURL: record.destinationURL, id: record.id)
            await failedTask.setError(.restorationMissingSystemTask)
            await failedTask.restoreState(.failed)
            await failedTask.admitMissingSystemRestoredSuccess()
            await runtimeRegistry.add(failedTask)
            pendingFailedTaskIDs.append(failedTask.id)
            // Keep the active/legacy row authoritative until the manager has
            // drained the pre-boundary delegate snapshot. A correlated staged
            // success still needs that row for its terminal commit CAS. Any
            // task that remains failed is sealed and pruned by the manager
            // after the restoration FIFO boundary closes, before publication.
        }
        return DownloadRestoreResult(
            failedTaskIDs: pendingFailedTaskIDs,
            completedTaskIDs: journalRestore.completedTaskIDs,
            deferredRetries: deferredRetries
        )
    }

    /// Reconciles deterministic completion evidence before URLSession task
    /// adoption. A valid staged payload is authoritative proof that transport
    /// finished; a final destination alone is never treated as proof because it
    /// may predate this logical download or have been replaced by another actor.
    private func reconcileCompletionJournals(
        downloadTasks: [any DownloadURLTask],
        records: [DownloadTaskPersistence.Record]
    ) async -> DownloadJournalRestoreResult {
        var result = DownloadJournalRestoreResult()
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let recordsByURL = Dictionary(grouping: records, by: \.url)

        // A terminal row is an absorbing checkpoint. A finished receipt must
        // validate the installed destination before any recoverable source is
        // deleted; residue collection is independent from publishing the
        // already-durable outcome.
        for record in records where record.lifecycle == .terminal {
            guard !Task.isCancelled else { return result }
            if record.commitOutcome == .finished,
                let metadata = record.commitMetadata
            {
                do {
                    try completionStager.validateCommittedFile(
                        at: record.destinationURL,
                        expectedByteCount: metadata.expectedByteCount,
                        payloadSHA256: metadata.payloadSHA256
                    )
                    let completedTask = DownloadTask(
                        url: record.url,
                        destinationURL: record.destinationURL,
                        id: record.id
                    )
                    await completedTask.restoreState(.completed)
                    await runtimeRegistry.add(completedTask)
                    result.handledTaskIDs.insert(record.id)
                    result.completedTaskIDs.append(record.id)
                    // A cleanup failure must not suppress a valid committed
                    // result. The retained terminal receipt gives the next
                    // launch another bounded garbage-collection opportunity.
                    _ = await cleanupCommitResidue(for: record)
                    continue
                } catch {
                    Self.logger.fault(
                        "Finished commit validation failed for task \(record.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). Recoverable journal evidence is preserved."
                    )
                    // Do not clean the staged payload or destination stage.
                    // The final path may have been externally replaced, and
                    // automatically overwriting it would be destructive; the
                    // receipt remains durable for diagnosis/recovery policy.
                }
            }
            if record.commitOutcome == .abandoned {
                guard await cleanupCommitResidue(for: record) else {
                    result.handledTaskIDs.insert(record.id)
                    continue
                }
            }
            if record.commitOutcome == .abandoned || record.commitOutcome == .finished {
                let failedTask = DownloadTask(
                    url: record.url,
                    destinationURL: record.destinationURL,
                    id: record.id
                )
                let restoreError: DownloadError =
                    if record.commitOutcome == .finished {
                        Self.finishedReceiptIntegrityError
                    } else {
                        .restorationMissingSystemTask
                    }
                await failedTask.setError(restoreError)
                await failedTask.restoreState(.failed)
                await runtimeRegistry.add(failedTask)
                result.handledTaskIDs.insert(record.id)
                result.failedTaskIDs.append(record.id)
                continue
            }
            guard await cleanupCommitResidue(for: record) else {
                result.handledTaskIDs.insert(record.id)
                continue
            }
            do {
                try await persistence.remove(id: record.id)
                result.handledTaskIDs.insert(record.id)
            } catch {
                Self.logger.fault(
                    "Failed to prune terminal completion journal for task \(record.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))."
                )
            }
        }

        let artifactKeys: [String]
        do {
            artifactKeys = try completionStager.enumerateArtifactKeys()
        } catch {
            Self.logger.fault(
                "Failed to enumerate completion journals: \(String(describing: error), privacy: .private(mask: .hash))."
            )
            // A root-level I/O or permission failure says nothing about
            // whether individual payloads exist. Quarantine every nonterminal
            // row for this launch instead of converting uncertainty into loss.
            result.handledTaskIDs.formUnion(
                records.lazy.filter { $0.lifecycle != .terminal }.map(\.id)
            )
            return result
        }

        let recordsByStagingKey = Dictionary(
            grouping: records.filter { $0.lifecycle != .terminal },
            by: { record in
                record.commitMetadata?.stagingKey
                    ?? ((try? DownloadCompletionStager.stagingKey(forTaskID: record.id)) ?? "")
            }
        )

        let terminalArtifactKeys = Set(
            records.lazy
                .filter { $0.lifecycle == .terminal }
                .compactMap { record in
                    record.commitMetadata?.stagingKey
                        ?? (try? DownloadCompletionStager.stagingKey(forTaskID: record.id))
                }
        )

        for key in artifactKeys where !terminalArtifactKeys.contains(key) {
            guard !Task.isCancelled else { return result }
            let fallbackRecord =
                recordsByStagingKey[key]?.count == 1
                ? recordsByStagingKey[key]?.first
                : nil
            let completion: StagedCompletion
            do {
                completion = try completionStager.load(forKey: key)
            } catch DownloadCompletionStagingError.fileSystemFailure {
                // Transient read/permission failures preserve both the row and
                // artifacts. A later launch can retry without redownloading.
                if let fallbackRecord {
                    result.handledTaskIDs.insert(fallbackRecord.id)
                }
                continue
            } catch {
                if let fallbackRecord, fallbackRecord.lifecycle == .committing {
                    await abandonUnusableCommit(
                        record: fallbackRecord,
                        discoveredArtifactKey: key,
                        result: &result
                    )
                } else {
                    try? completionStager.cleanupArtifacts(forKey: key)
                    if let fallbackRecord {
                        completionAdmissionGate.release(taskID: fallbackRecord.id)
                    }
                }
                continue
            }

            guard let record = recordsByID[completion.manifest.taskID],
                record.lifecycle != .terminal,
                record.lifecycle != .retryPending,
                completion.manifest.key == key,
                completion.manifest.originalRequestURL == record.url,
                admitsDownloadURL(completion.manifest.originalRequestURL),
                admitsDownloadURL(completion.manifest.currentRequestURL)
            else {
                if let fallbackRecord, fallbackRecord.lifecycle == .committing {
                    await abandonUnusableCommit(
                        record: fallbackRecord,
                        discoveredArtifactKey: key,
                        result: &result
                    )
                } else {
                    try? completionStager.cleanup(completion)
                    completionAdmissionGate.release(taskID: completion.manifest.taskID)
                }
                continue
            }

            if record.lifecycle == .committing,
                !commitMetadataMatches(record.commitMetadata, completion: completion, record: record)
            {
                await abandonUnusableCommit(
                    record: record,
                    discoveredArtifactKey: key,
                    result: &result
                )
                continue
            }

            completionAdmissionGate.registerJournal(taskID: record.id)

            cancelCorrelatedSystemTasks(
                for: record,
                downloadTasks: downloadTasks,
                recordsByURL: recordsByURL
            )

            let restoredTask = DownloadTask(
                url: record.url,
                destinationURL: record.destinationURL,
                id: record.id
            )
            await restoredTask.restoreRetryCounts(
                retryCount: record.retryCount ?? 0,
                totalRetryCount: record.totalRetryCount ?? 0
            )
            await restoredTask.restoreState(.downloading)
            await runtimeRegistry.add(restoredTask)
            do {
                let completed = try await transferCoordinator.completeDownload(
                    task: restoredTask,
                    stagedCompletion: completion
                )
                if completed {
                    result.handledTaskIDs.insert(record.id)
                } else {
                    // A competing durable phase rejected this journal. Do not
                    // leave the synthetic downloading handle registered or
                    // suppress reconciliation of the latest persistence row.
                    await runtimeRegistry.removeTaskRuntime(taskId: record.id)
                    await runtimeRegistry.remove(restoredTask)
                    // A competing durable phase rejected this stale snapshot.
                    // Preserve the deterministic evidence until a fresh
                    // reconciliation identifies the authoritative owner.
                }
            } catch {
                // The coordinator publishes a filesystem failure and retains
                // both persistence and source evidence for the next launch.
                result.handledTaskIDs.insert(record.id)
            }
        }

        return await reconcileCommittingRowsWithoutUsablePayload(
            records: records,
            result: result
        )
    }

    private func reconcileCommittingRowsWithoutUsablePayload(
        records: [DownloadTaskPersistence.Record],
        result initialResult: DownloadJournalRestoreResult
    ) async -> DownloadJournalRestoreResult {
        var result = initialResult
        for record in records
        where record.lifecycle == .committing
            && !result.handledTaskIDs.contains(record.id)
        {
            guard !Task.isCancelled else { return result }
            await abandonUnusableCommit(record: record, result: &result)
        }
        return result
    }

    private func abandonUnusableCommit(
        record: DownloadTaskPersistence.Record,
        discoveredArtifactKey: String? = nil,
        result: inout DownloadJournalRestoreResult
    ) async {
        let metadata = record.commitMetadata
        do {
            guard try await persistence.abandonCommit(id: record.id, metadata: metadata) else {
                return
            }
        } catch {
            Self.logger.fault(
                "Failed to abandon unusable completion journal for task \(record.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))."
            )
            return
        }

        result.handledTaskIDs.insert(record.id)
        let didClean: Bool
        if record.commitMetadata != nil {
            didClean = await cleanupCommitResidue(for: record)
        } else if let discoveredArtifactKey {
            do {
                try completionStager.cleanupArtifacts(forKey: discoveredArtifactKey)
                try transferCoordinator.removeDestinationStage(
                    for: record.destinationURL,
                    stagingKey: discoveredArtifactKey
                )
                completionAdmissionGate.release(taskID: record.id)
                didClean = true
            } catch {
                didClean = false
            }
        } else {
            didClean = await cleanupCommitResidue(for: record)
        }
        guard didClean else { return }

        let failedTask = DownloadTask(
            url: record.url,
            destinationURL: record.destinationURL,
            id: record.id
        )
        await failedTask.setError(.restorationMissingSystemTask)
        await failedTask.restoreState(.failed)
        await runtimeRegistry.add(failedTask)
        result.failedTaskIDs.append(record.id)
    }

    private static let finishedReceiptIntegrityError = DownloadError.fileSystemError(
        SendableUnderlyingError(
            domain: "InnoNetworkDownload.Restoration",
            code: 1,
            message: "Committed download destination failed integrity validation",
            failureReason: "The final file no longer matches its durable completion receipt.",
            recoverySuggestion: "Preserve the receipt and staged payload, then choose an explicit recovery policy."
        )
    )

    private func cleanupCommitResidue(
        for record: DownloadTaskPersistence.Record
    ) async -> Bool {
        let stagingKey: String
        if let persistedKey = record.commitMetadata?.stagingKey {
            stagingKey = persistedKey
        } else {
            guard let derivedKey = try? DownloadCompletionStager.stagingKey(forTaskID: record.id) else {
                return false
            }
            stagingKey = derivedKey
        }
        do {
            try completionStager.cleanupArtifacts(forKey: stagingKey)
            try transferCoordinator.removeDestinationStage(
                for: record.destinationURL,
                stagingKey: stagingKey
            )
            completionAdmissionGate.release(taskID: record.id)
            return true
        } catch {
            Self.logger.fault(
                "Failed to clean bounded commit residue for task \(record.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). The terminal metadata is retained for another launch."
            )
            return false
        }
    }

    private func commitMetadataMatches(
        _ metadata: DownloadTaskPersistence.CommitMetadata?,
        completion: StagedCompletion,
        record: DownloadTaskPersistence.Record
    ) -> Bool {
        guard let metadata else { return false }
        return metadata.stagingKey == completion.manifest.key
            && metadata.originalRequestURL == completion.manifest.originalRequestURL
            && metadata.currentRequestURL == completion.manifest.currentRequestURL
            && metadata.destinationURL == record.destinationURL
            && metadata.expectedByteCount == completion.manifest.expectedByteCount
            && metadata.payloadSHA256.utf8.count == 64
            && metadata.payloadSHA256.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
            }
    }

    private func cancelCorrelatedSystemTasks(
        for record: DownloadTaskPersistence.Record,
        downloadTasks: [any DownloadURLTask],
        recordsByURL: [URL: [DownloadTaskPersistence.Record]]
    ) {
        let permitsUniqueLegacyFallback = recordsByURL[record.url]?.count == 1
        for urlTask in downloadTasks {
            let describedMatch = urlTask.taskDescription == record.id
            let legacyMatch =
                (urlTask.taskDescription?.isEmpty ?? true)
                && permitsUniqueLegacyFallback
                && urlTask.originalRequest?.url == record.url
            if describedMatch || legacyMatch {
                urlTask.cancel()
            }
        }
    }

    private func restoreTrackedTask(
        record: DownloadTaskPersistence.Record
    ) async -> DownloadTask? {
        guard !Task.isCancelled else { return nil }
        if await runtimeRegistry.task(withId: record.id) != nil {
            // A second system task must not steal an existing logical ID or
            // remain live beside it. The caller cancels this duplicate.
            return nil
        }
        let restoredTask = DownloadTask(
            url: record.url,
            destinationURL: record.destinationURL,
            id: record.id,
            resumeData: record.resumeData
        )
        await restoredTask.restoreRetryCounts(
            retryCount: record.retryCount ?? 0,
            totalRetryCount: record.totalRetryCount ?? 0
        )
        guard !Task.isCancelled else { return nil }
        await runtimeRegistry.add(restoredTask)
        return restoredTask
    }

    private func correlatedRecord(
        for urlTask: any DownloadURLTask,
        recordsByID: [String: DownloadTaskPersistence.Record],
        recordsByURL: [URL: [DownloadTaskPersistence.Record]]
    ) -> DownloadTaskPersistence.Record? {
        guard let requestURL = urlTask.originalRequest?.url,
            let currentURL = urlTask.currentRequest?.url,
            admitsDownloadURL(requestURL),
            admitsDownloadURL(currentURL)
        else {
            return nil
        }

        let record: DownloadTaskPersistence.Record
        if let description = urlTask.taskDescription, !description.isEmpty {
            guard let describedRecord = recordsByID[description] else { return nil }
            record = describedRecord
        } else {
            let liveCandidates = recordsByURL[requestURL, default: []]
                .filter(permitsLegacyURLFallback)
            guard liveCandidates.count == 1,
                let matchingRecord = liveCandidates.first
            else {
                return nil
            }
            record = matchingRecord
            urlTask.taskDescription = record.id
        }

        guard admitsDownloadURL(record.url), record.url == requestURL else {
            // taskDescription is process-external metadata. It identifies a
            // durable row only when the retained original request matches that
            // row's admitted source. The current request may be a separately
            // admitted redirect target.
            return nil
        }
        return record
    }

    private func hasPersistedPauseIntent(
        _ record: DownloadTaskPersistence.Record
    ) -> Bool {
        switch record.lifecycle {
        case .pausing, .paused:
            return true
        case .active, .resuming, .retryPending, .committing, .terminal:
            return false
        case nil:
            return record.resumeData != nil
        }
    }

    private func restoresAsPausedWithoutSystemTask(
        _ record: DownloadTaskPersistence.Record
    ) -> Bool {
        record.resumeData != nil || record.lifecycle?.restoresAsPausedWithoutSystemTask == true
    }

    private func permitsLiveTransport(
        _ record: DownloadTaskPersistence.Record
    ) -> Bool {
        record.lifecycle != .retryPending
            && record.lifecycle != .committing
            && record.lifecycle != .terminal
    }

    /// URL-only correlation is a compatibility fallback for legacy system
    /// tasks without `taskDescription`. Only phases that can legitimately own
    /// a live transport participate in uniqueness; paused/retry/terminal rows
    /// must not make an otherwise unambiguous active attempt look ambiguous.
    private func permitsLegacyURLFallback(
        _ record: DownloadTaskPersistence.Record
    ) -> Bool {
        switch record.lifecycle {
        case .active, .resuming:
            return true
        case nil:
            return record.resumeData == nil
        case .pausing, .paused, .retryPending, .committing, .terminal:
            return false
        }
    }

    private func admitsDownloadURL(_ url: URL) -> Bool {
        do {
            try NetworkURLAdmission.validate(
                url,
                policy: .http(allowsInsecure: configuration.allowsInsecureHTTP)
            )
            return true
        } catch {
            return false
        }
    }

    private func pruneRejectedRecord(_ id: String) async {
        do {
            try await persistence.remove(id: id)
        } catch {
            Self.logger.fault(
                "Failed to prune URL-policy-rejected task \(id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash)). The record remains quarantined and will be retried on the next launch."
            )
        }
    }
}
