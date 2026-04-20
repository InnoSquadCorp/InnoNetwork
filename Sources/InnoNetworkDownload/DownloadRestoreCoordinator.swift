import Foundation


package struct DownloadRestoreCoordinator {
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

    package func restorePendingDownloads() async {
        let downloadTasks = await session.allDownloadTasks()
        var restoredTaskIDs = Set<String>()

        for urlTask in downloadTasks {
            guard let downloadTask = await restoreTrackedTask(for: urlTask) else { continue }
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

            await downloadTask.updateState(state)
        }

        let persistedTasks = await persistence.allRecords()
        for record in persistedTasks where !restoredTaskIDs.contains(record.id) {
            await persistence.remove(id: record.id)
        }
    }

    private func restoreTrackedTask(for urlTask: any DownloadURLTask) async -> DownloadTask? {
        let taskID: String

        if let description = urlTask.taskDescription, !description.isEmpty {
            taskID = description
        } else {
            taskID = await persistence.id(forURL: urlTask.originalRequest?.url)
                ?? UUID().uuidString
            urlTask.taskDescription = taskID
        }

        if let existingTask = await runtimeRegistry.task(withId: taskID) {
            return existingTask
        }

        guard let record = await persistence.record(forID: taskID) else { return nil }
        let restoredTask = DownloadTask(url: record.url, destinationURL: record.destinationURL, id: record.id)
        await runtimeRegistry.add(restoredTask)
        return restoredTask
    }
}
