import Foundation
import InnoNetwork


package struct DownloadTransferCoordinator {
    let session: URLSession
    let runtimeRegistry: DownloadRuntimeRegistry
    let persistence: DownloadTaskPersistence
    let eventHub: TaskEventHub<DownloadEvent>

    package init(
        session: URLSession,
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
        await persistence.upsert(id: task.id, url: task.url, destinationURL: task.destinationURL)

        let urlTask = session.downloadTask(with: task.url)
        await register(urlTask: urlTask, for: task)

        await task.updateState(.downloading)
        await runtimeRegistry.onStateChanged?(task, .downloading)
        await eventHub.publish(.stateChanged(.downloading), for: task.id)
        urlTask.resume()
    }

    package func register(urlTask: URLSessionDownloadTask, for task: DownloadTask) async {
        urlTask.taskDescription = task.id
        await runtimeRegistry.setMapping(downloadTask: task, for: urlTask.taskIdentifier)
        await runtimeRegistry.setURLTask(urlTask, for: task.id)
    }

    package func completeDownload(task: DownloadTask, temporaryLocation: URL) async throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: task.destinationURL.path) {
            try fileManager.removeItem(at: task.destinationURL)
        }

        let directory = task.destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try fileManager.moveItem(at: temporaryLocation, to: task.destinationURL)

        await task.updateState(.completed)
        await runtimeRegistry.onStateChanged?(task, .completed)
        await runtimeRegistry.onCompleted?(task, task.destinationURL)
        await eventHub.publish(.stateChanged(.completed), for: task.id)
        await eventHub.publish(.completed(task.destinationURL), for: task.id)
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        await eventHub.finish(taskID: task.id)
        await runtimeRegistry.remove(task)
        await persistence.remove(id: task.id)
    }
}
