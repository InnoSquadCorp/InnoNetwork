import Foundation


package struct DownloadFailureCoordinator {
    private static let maximumSupportedDelay: TimeInterval = Double(Int64.max)

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
        let maximumSupportedDelay = Self.maximumSupportedDelay
        let fixedDelay = clampDelay(configuration.retryDelay, upperBound: maximumSupportedDelay)

        guard configuration.exponentialBackoff else {
            return fixedDelay
        }

        guard fixedDelay > 0 else { return 0 }

        let effectiveCap: TimeInterval
        if configuration.maxRetryDelay > 0 {
            effectiveCap = clampDelay(configuration.maxRetryDelay, upperBound: maximumSupportedDelay)
        } else {
            // "Uncapped" user configuration is still bounded by what
            // `Duration.seconds(...)` can represent safely at runtime.
            effectiveCap = maximumSupportedDelay
        }

        let base: TimeInterval
        if fixedDelay >= effectiveCap || baseDelayWouldOverflowCap(
            initialDelay: fixedDelay,
            retryCount: retryCount,
            cap: effectiveCap
        ) {
            base = effectiveCap
        } else {
            let exponent = Double(max(retryCount - 1, 0))
            base = min(fixedDelay * pow(2.0, exponent), effectiveCap)
        }

        let jitter = abs(base * configuration.retryJitterRatio)
        let lowerBound = max(0.0, base - jitter)
        let upperBound = min(effectiveCap, base + jitter)
        guard lowerBound < upperBound else { return lowerBound }
        return Double.random(in: lowerBound...upperBound)
    }

    private func clampDelay(_ delay: TimeInterval, upperBound: TimeInterval) -> TimeInterval {
        if delay.isNaN {
            return 0
        }
        guard delay.isFinite else {
            return upperBound
        }
        return min(max(0.0, delay), upperBound)
    }

    private func baseDelayWouldOverflowCap(
        initialDelay: TimeInterval,
        retryCount: Int,
        cap: TimeInterval
    ) -> Bool {
        guard initialDelay > 0, cap > 0 else { return false }

        let exponent = max(retryCount - 1, 0)
        guard exponent > 0 else {
            return initialDelay >= cap
        }

        return log2(initialDelay) + Double(exponent) >= log2(cap)
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
