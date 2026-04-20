import Foundation


package struct DownloadFailureCoordinator {
    let configuration: DownloadConfiguration
    let runtimeRegistry: DownloadRuntimeRegistry
    let persistence: DownloadTaskPersistence
    let eventHub: TaskEventHub<DownloadEvent>
    let clock: any InnoNetworkClock

    package init(
        configuration: DownloadConfiguration,
        runtimeRegistry: DownloadRuntimeRegistry,
        persistence: DownloadTaskPersistence,
        eventHub: TaskEventHub<DownloadEvent>,
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.configuration = configuration
        self.runtimeRegistry = runtimeRegistry
        self.persistence = persistence
        self.eventHub = eventHub
        self.clock = clock
    }

    package func handleError(
        task: DownloadTask,
        error: SendableUnderlyingError,
        restart: @Sendable (DownloadTask) async -> Void
    ) async {
        if isCancelledTransportError(error) {
            return
        }
        let totalRetryCount = await task.totalRetryCount
        let retryCount = await task.retryCount
        guard totalRetryCount < configuration.maxTotalRetries,
              retryCount < configuration.maxRetryCount
        else {
            await markTaskFailed(task)
            return
        }
        _ = await task.incrementTotalRetryCount()
        _ = await task.incrementRetryCount()

        if configuration.waitsForNetworkChanges, let monitor = configuration.networkMonitor {
            let snapshot = await monitor.currentSnapshot()
            let newSnapshot = await monitor.waitForChange(
                from: snapshot,
                timeout: configuration.networkChangeTimeout
            )
            if newSnapshot != snapshot {
                await task.resetRetryCount()
            }
        }

        if configuration.retryDelay > 0 {
            try? await clock.sleep(for: .seconds(configuration.retryDelay))
        }
        let state = await task.state
        if state != .cancelled {
            await restart(task)
        }
    }

    package func markTaskFailed(_ task: DownloadTask) async {
        await task.updateState(.failed)
        await task.setError(.maxRetriesExceeded)
        await runtimeRegistry.onStateChanged?(task, .failed)
        await runtimeRegistry.onFailed?(task, .maxRetriesExceeded)
        await eventHub.publish(.stateChanged(.failed), for: task.id)
        await eventHub.publish(.failed(.maxRetriesExceeded), for: task.id)
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        await eventHub.finish(taskID: task.id)
        await runtimeRegistry.remove(task)
        await persistence.remove(id: task.id)
    }

    private func isCancelledTransportError(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    }
}
