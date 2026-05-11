import Foundation
import InnoNetwork

// Split out of `DownloadManager.swift` to keep the manager's public surface
// and lifecycle (`init`, `shutdown`, public download/control methods) visually
// separate from the delegate-event consumer plumbing. All methods stay
// actor-isolated; this file only relocates code, no behaviour changes.
extension DownloadManager {

    func handleDelegateEvent(_ event: DelegateEvent) async {
        switch event {
        case .progress(let taskIdentifier, let bytesWritten, let totalBytesWritten, let totalBytesExpectedToWrite):
            await handleProgress(
                taskIdentifier: taskIdentifier,
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        case .completion(let taskIdentifier, let location, let error):
            await handleCompletion(taskIdentifier: taskIdentifier, location: location, error: error)
        }
    }

    func handleProgress(
        taskIdentifier: Int, bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) async {
        guard let task = await runtimeRegistry.downloadTask(for: taskIdentifier) else { return }

        let progress = DownloadProgress(
            bytesWritten: bytesWritten,
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
        await task.updateProgress(progress)
        if configuration.taskInactivityTimeout != nil {
            await task.setLastProgressAt(ContinuousClock().now)
        }
        await runtimeRegistry.onProgress?(task, progress)
        await eventHub.publish(.progress(progress), for: task.id)
    }

    func handleCompletion(taskIdentifier: Int, location: URL?, error: SendableUnderlyingError?) async {
        guard let task = await runtimeRegistry.downloadTask(for: taskIdentifier) else { return }

        if let error {
            await runtimeRegistry.detachRuntime(taskIdentifier: taskIdentifier)
            await failureCoordinator.handleError(task: task, error: error) { [transferCoordinator] task in
                await transferCoordinator.startDownload(task)
            }
            return
        }

        guard let location else {
            await runtimeRegistry.detachRuntime(taskIdentifier: taskIdentifier)
            await failureCoordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: "InnoNetworkDownload",
                    code: -1,
                    message: "Download completed without temporary file location."
                )
            ) { [transferCoordinator] task in
                await transferCoordinator.startDownload(task)
            }
            return
        }

        do {
            try await transferCoordinator.completeDownload(task: task, temporaryLocation: location)
        } catch {
            await runtimeRegistry.detachRuntime(taskIdentifier: taskIdentifier)
            await failureCoordinator.handleError(
                task: task,
                error: SendableUnderlyingError(error)
            ) { [transferCoordinator] task in
                await transferCoordinator.startDownload(task)
            }
        }
    }
}
