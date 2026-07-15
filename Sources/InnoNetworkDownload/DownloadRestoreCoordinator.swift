import Foundation
import InnoNetwork
import OSLog

package struct DownloadRestoreCoordinator {
    private static let logger = Logger(subsystem: "innosquad.network.download", category: "Persistence")

    let configuration: DownloadConfiguration
    let session: any DownloadURLSession
    let runtimeRegistry: DownloadRuntimeRegistry
    let persistence: DownloadTaskPersistence
    let transferCoordinator: DownloadTransferCoordinator

    package init(
        configuration: DownloadConfiguration,
        session: any DownloadURLSession,
        runtimeRegistry: DownloadRuntimeRegistry,
        persistence: DownloadTaskPersistence,
        transferCoordinator: DownloadTransferCoordinator
    ) {
        self.configuration = configuration
        self.session = session
        self.runtimeRegistry = runtimeRegistry
        self.persistence = persistence
        self.transferCoordinator = transferCoordinator
    }

    /// Restore in-memory state from background URLSession tasks and persisted
    /// records.
    ///
    /// Returns the IDs of tasks whose persisted record exists without a
    /// corresponding system task. Their `.failed(.restorationMissingSystemTask)`
    /// announcement is deferred to the manager so the events can be published
    /// after the caller has had an opportunity to subscribe via
    /// ``DownloadManager/events(for:)`` — publishing during init would race
    /// the subscriber and the events would drain into an empty partition.
    package func restorePendingDownloads() async -> [String] {
        let downloadTasks = await session.allDownloadTasks()
        var restoredTaskIDs = Set<String>()

        for urlTask in downloadTasks {
            // A system task that is mid-cancel does not produce future
            // delegate callbacks the runtime registry can act on. Letting
            // it linger in the registry would leave a phantom entry that
            // future restarts and pause/resume reconciliation would have
            // to special-case. Skip the registry hop entirely and let the
            // cancel finish on its own without surfacing as a restored
            // task. Mark the persisted record (if any) as accounted for so
            // the second pass below does not resurrect it as a
            // `.restorationMissingSystemTask` failure — the cancel is the
            // authoritative terminal state, not a missing-task failure.
            if urlTask.state == .canceling {
                if let description = urlTask.taskDescription, !description.isEmpty {
                    restoredTaskIDs.insert(description)
                }
                if let url = urlTask.originalRequest?.url,
                    let id = await persistence.id(forURL: url)
                {
                    restoredTaskIDs.insert(id)
                }
                continue
            }
            guard let downloadTask = await restoreTrackedTask(for: urlTask) else {
                urlTask.cancel()
                continue
            }
            restoredTaskIDs.insert(downloadTask.id)

            await transferCoordinator.register(urlTask: urlTask, for: downloadTask)

            let state: DownloadState
            switch urlTask.state {
            case .running:
                state = .downloading
            case .suspended:
                state = .paused
            case .canceling:
                // Defensive — the `.canceling` short-circuit above would
                // normally route this case away before we reach the switch.
                state = .cancelled
            case .completed:
                state = .completed
            @unknown default:
                state = .paused
            }

            await downloadTask.restoreState(state)
        }

        var pendingMissingSystemTaskIDs: [String] = []
        let persistedTasks = await persistence.allRecords()
        for record in persistedTasks where !restoredTaskIDs.contains(record.id) {
            guard admitsDownloadURL(record.url) else {
                await pruneRejectedRecord(record.id)
                continue
            }
            if let resumeData = record.resumeData {
                let restoredTask = DownloadTask(
                    url: record.url,
                    destinationURL: record.destinationURL,
                    id: record.id,
                    resumeData: resumeData
                )
                await restoredTask.restoreState(.paused)
                await runtimeRegistry.add(restoredTask)
                continue
            }

            let failedTask = DownloadTask(url: record.url, destinationURL: record.destinationURL, id: record.id)
            await failedTask.restoreState(.failed)
            await failedTask.setError(.restorationMissingSystemTask)
            await runtimeRegistry.add(failedTask)
            // Queue the failure announcement before attempting persistence
            // cleanup. The manager replays this list to handler subscribers
            // and stream consumers on first observation, so missing the
            // append on a prune failure would silently drop the failure for
            // any caller that was about to subscribe.
            pendingMissingSystemTaskIDs.append(failedTask.id)
            do {
                try await persistence.remove(id: record.id)
            } catch {
                Self.logger.fault(
                    "Failed to prune orphaned task \(record.id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash)). Failure announcement is still queued; the next launch will reprocess this record."
                )
            }
        }
        return pendingMissingSystemTaskIDs
    }

    private func restoreTrackedTask(for urlTask: any DownloadURLTask) async -> DownloadTask? {
        guard let requestURL = urlTask.originalRequest?.url,
            admitsDownloadURL(requestURL)
        else {
            return nil
        }

        let taskID: String

        if let description = urlTask.taskDescription, !description.isEmpty {
            taskID = description
        } else {
            taskID =
                await persistence.id(forURL: urlTask.originalRequest?.url)
                ?? UUID().uuidString
            urlTask.taskDescription = taskID
        }

        if let existingTask = await runtimeRegistry.task(withId: taskID) {
            // A duplicate system task must not steal an existing logical ID
            // and redirect its destination to a different admitted URL.
            return existingTask.url == requestURL ? existingTask : nil
        }

        guard let record = await persistence.record(forID: taskID) else { return nil }
        guard admitsDownloadURL(record.url), record.url == requestURL else {
            // A persisted source and the live URLSession request must describe
            // the same admitted transfer. Otherwise adopting the live task
            // could write bytes from a different origin to the persisted
            // destination, and its opaque resume data could revive that URL.
            await pruneRejectedRecord(record.id)
            return nil
        }
        let restoredTask = DownloadTask(
            url: record.url,
            destinationURL: record.destinationURL,
            id: record.id,
            resumeData: record.resumeData
        )
        await runtimeRegistry.add(restoredTask)
        return restoredTask
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
