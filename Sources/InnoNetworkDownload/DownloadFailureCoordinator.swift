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

        let delay = computeRetryDelay(retryCount: await task.retryCount)
        if delay > 0 {
            try? await clock.sleep(for: .seconds(delay))
        }
        let state = await task.state
        if state != .cancelled {
            await restart(task)
        }
    }

    /// Computes the sleep interval before the next restart. When
    /// `configuration.exponentialBackoff` is disabled the configured
    /// fixed `retryDelay` is returned directly (pre-4.3 behavior). When
    /// enabled the delay grows as `retryDelay * 2^(retryCount - 1)` with
    /// jitter applied and clamped to `maxRetryDelay` if the cap is active.
    private func computeRetryDelay(retryCount: Int) -> TimeInterval {
        guard configuration.exponentialBackoff else {
            return configuration.retryDelay
        }
        let exponent = Double(max(retryCount - 1, 0))
        let base = configuration.retryDelay * pow(2.0, exponent)
        let jitter = abs(base * configuration.retryJitterRatio)
        let unclamped = max(0.0, base + Double.random(in: (-jitter)...(jitter)))
        if configuration.maxRetryDelay > 0 {
            return min(unclamped, configuration.maxRetryDelay)
        }
        return unclamped
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
