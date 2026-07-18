import Foundation
import InnoNetwork
import OSLog

extension DownloadRestoreCoordinator {
    /// Reconciles deterministic completion evidence before URLSession task
    /// adoption. A valid staged payload is authoritative proof that transport
    /// finished; a final destination alone is never treated as proof because it
    /// may predate this logical download or have been replaced by another actor.
    func reconcileCompletionJournals(
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

    func reconcileCommittingRowsWithoutUsablePayload(
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

    func abandonUnusableCommit(
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

    func cleanupCommitResidue(
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

    func commitMetadataMatches(
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

    func cancelCorrelatedSystemTasks(
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

}
