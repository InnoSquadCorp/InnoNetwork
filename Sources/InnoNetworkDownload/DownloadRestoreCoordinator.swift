import Foundation
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
            await runtimeRegistry.onStateChanged?(failedTask, .failed)
            await runtimeRegistry.onFailed?(failedTask, .restorationMissingSystemTask)
            do {
                try await persistence.remove(id: record.id)
            } catch {
                Self.logger.fault(
                    "Failed to prune orphaned task \(record.id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash))"
                )
                continue
            }
            pendingMissingSystemTaskIDs.append(failedTask.id)
        }
        return pendingMissingSystemTaskIDs
    }

    private func restoreTrackedTask(for urlTask: any DownloadURLTask) async -> DownloadTask? {
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
            return existingTask
        }

        guard let record = await persistence.record(forID: taskID) else { return nil }
        let restoredTask = DownloadTask(
            url: record.url,
            destinationURL: record.destinationURL,
            id: record.id,
            resumeData: record.resumeData
        )
        await runtimeRegistry.add(restoredTask)
        return restoredTask
    }
}
