import Foundation
import InnoNetwork
import OSLog

package struct DownloadTransferCoordinator {
    private static let logger = Logger(subsystem: "innosquad.network.download", category: "Persistence")

    let session: any DownloadURLSession
    let runtimeRegistry: DownloadRuntimeRegistry
    let persistence: DownloadTaskPersistence
    let eventHub: TaskEventHub<DownloadEvent>

    package init(
        session: any DownloadURLSession,
        runtimeRegistry: DownloadRuntimeRegistry,
        persistence: DownloadTaskPersistence,
        eventHub: TaskEventHub<DownloadEvent>
    ) {
        self.session = session
        self.runtimeRegistry = runtimeRegistry
        self.persistence = persistence
        self.eventHub = eventHub
    }

    package func startDownload(_ task: DownloadTask) async {
        await task.updateState(.waiting)
        await runtimeRegistry.onStateChanged?(task, .waiting)
        await eventHub.publish(.stateChanged(.waiting), for: task.id)
        do {
            try await persistence.upsert(id: task.id, url: task.url, destinationURL: task.destinationURL)
        } catch {
            await markTaskFailedForPersistence(task, error: error)
            return
        }

        let urlTask = session.makeDownloadTask(with: task.url)
        await register(urlTask: urlTask, for: task)

        await task.updateState(.downloading)
        await runtimeRegistry.onStateChanged?(task, .downloading)
        await eventHub.publish(.stateChanged(.downloading), for: task.id)
        urlTask.resume()
    }

    package func register(urlTask: any DownloadURLTask, for task: DownloadTask) async {
        urlTask.taskDescription = task.id
        await runtimeRegistry.setMapping(downloadTask: task, for: urlTask.taskIdentifier)
        await runtimeRegistry.setURLTask(urlTask, for: task.id)
    }

    package func completeDownload(task: DownloadTask, temporaryLocation: URL) async throws {
        let fileManager = FileManager.default

        let directory = task.destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if fileManager.fileExists(atPath: task.destinationURL.path) {
            _ = try fileManager.replaceItemAt(task.destinationURL, withItemAt: temporaryLocation)
        } else {
            try fileManager.moveItem(at: temporaryLocation, to: task.destinationURL)
        }

        await task.updateState(.completed)
        await runtimeRegistry.onStateChanged?(task, .completed)
        await runtimeRegistry.onCompleted?(task, task.destinationURL)
        await eventHub.publish(.stateChanged(.completed), for: task.id)
        await eventHub.publish(.completed(task.destinationURL), for: task.id)
        do {
            try await persistence.remove(id: task.id)
        } catch {
            Self.logger.fault(
                "Failed to remove completed task \(task.id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            return
        }
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        await eventHub.finish(taskID: task.id)
        await runtimeRegistry.remove(task)
    }

    package func markTaskFailedForPersistence(_ task: DownloadTask, error: Error) async {
        let downloadError = DownloadError.fileSystemError(SendableUnderlyingError(error))
        await task.updateState(.failed)
        await task.setError(downloadError)
        await runtimeRegistry.onStateChanged?(task, .failed)
        await runtimeRegistry.onFailed?(task, downloadError)
        await eventHub.publish(.stateChanged(.failed), for: task.id)
        await eventHub.publish(.failed(downloadError), for: task.id)
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        await eventHub.finish(taskID: task.id)
        await runtimeRegistry.remove(task)
    }
}
