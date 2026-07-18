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

struct DownloadJournalRestoreResult: Sendable {
    var handledTaskIDs = Set<String>()
    var failedTaskIDs: [String] = []
    var completedTaskIDs: [String] = []
}

package struct DownloadRestoreCoordinator {
    static let logger = Logger(subsystem: "innosquad.network.download", category: "Persistence")

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
}
