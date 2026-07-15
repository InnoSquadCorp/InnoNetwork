import Foundation
import OSLog

package struct DownloadFailureCoordinator {
    private static let maximumSupportedDelay: TimeInterval = Double(Int64.max)
    private static let logger = Logger(subsystem: "innosquad.network.download", category: "Persistence")

    let configuration: DownloadConfiguration
    let runtimeRegistry: DownloadRuntimeRegistry
    let callbackDeliveryQueue: DownloadCallbackDeliveryQueue
    let persistence: DownloadTaskPersistence
    let eventHub: TaskEventHub<DownloadEvent>
    let lifecycleGate: DownloadLifecycleGate
    let clock: any InnoNetworkClock

    package init(
        configuration: DownloadConfiguration,
        runtimeRegistry: DownloadRuntimeRegistry,
        callbackDeliveryQueue: DownloadCallbackDeliveryQueue? = nil,
        persistence: DownloadTaskPersistence,
        eventHub: TaskEventHub<DownloadEvent>,
        lifecycleGate: DownloadLifecycleGate = DownloadLifecycleGate(),
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.configuration = configuration
        self.runtimeRegistry = runtimeRegistry
        self.callbackDeliveryQueue =
            callbackDeliveryQueue
            ?? DownloadCallbackDeliveryQueue(runtimeRegistry: runtimeRegistry)
        self.persistence = persistence
        self.eventHub = eventHub
        self.lifecycleGate = lifecycleGate
        self.clock = clock
    }

    package func handleError(
        task: DownloadTask,
        error: SendableUnderlyingError,
        onAdmissionComplete: @escaping @Sendable () -> Void = {},
        restart: @Sendable (DownloadTask) async -> Void
    ) async {
        if let invalidURL = DownloadRedirectAdmissionFailure.invalidURLDescription(from: error) {
            // Redirect admission is deterministic for this task and policy.
            // Retrying the same source would produce the same rejected target,
            // so surface the typed URL failure without spending retry budget.
            await markTaskFailed(
                task,
                reason: .invalidURL(invalidURL),
                onLifecycleAdmissionComplete: onAdmissionComplete
            )
            return
        }
        if isCancelledTransportError(error) {
            await runtimeRegistry.removeTaskRuntime(taskId: task.id)
            // Explicit pause/cancel paths already move the logical task out
            // of `.downloading` before their delegate cancellation arrives.
            // An otherwise-unowned cancellation must flow through normal
            // retry/failure handling; returning here would strand a live
            // logical task with no URLSession task behind it.
            let state = await task.state
            if state.isTerminal || state == .paused {
                onAdmissionComplete()
                return
            }
        }
        if Self.isDeterministicFilesystemError(error) {
            // EACCES/EPERM/ENOSPC/EROFS and the matching Cocoa file-write
            // errors describe writer-side conditions that will not heal
            // with another network attempt — the destination directory is
            // unwritable, the volume is full, or the filesystem is
            // read-only. Retrying just burns the configured budget while
            // re-downloading bytes we cannot persist. Mark the task
            // failed immediately so callers see the actionable error
            // instead of a timeout-style retry-exhausted trail.
            await markTaskFailed(
                task,
                reason: .fileSystemError(error),
                onLifecycleAdmissionComplete: onAdmissionComplete
            )
            return
        }
        let totalRetryCount = await task.totalRetryCount
        let retryCount = await task.retryCount
        guard totalRetryCount < configuration.maxTotalRetries,
            retryCount < configuration.maxRetryCount
        else {
            await markTaskFailed(
                task,
                reason: .maxRetriesExceeded,
                onLifecycleAdmissionComplete: onAdmissionComplete
            )
            return
        }
        let updatedTotalRetryCount = await task.incrementTotalRetryCount()
        let updatedRetryCount = await task.incrementRetryCount()
        let retryPlan: DownloadTaskPersistence.RetryPlan
        if configuration.waitsForNetworkChanges,
            let monitor = configuration.networkMonitor
        {
            let baseline = await monitor.currentSnapshot()
            let deadline = configuration.networkChangeTimeout.map {
                clock.now().addingTimeInterval(
                    clampDelay($0, upperBound: Self.maximumSupportedDelay)
                )
            }
            retryPlan = .waitingForNetwork(
                baseline: baseline,
                deadline: deadline
            )
        } else {
            retryPlan = makeBackoffPlan(retryCount: updatedRetryCount)
        }
        do {
            let persisted = try await persistence.updateRetryState(
                id: task.id,
                retryCount: updatedRetryCount,
                totalRetryCount: updatedTotalRetryCount,
                retryPlan: retryPlan
            )
            guard persisted else {
                // A terminal/cancel path or a newer durable phase won while
                // this delegate failure was being admitted. Do not revive it
                // or surface a second terminal result from this stale job.
                onAdmissionComplete()
                return
            }
        } catch {
            await markTaskFailed(
                task,
                reason: .fileSystemError(SendableUnderlyingError(error)),
                onLifecycleAdmissionComplete: onAdmissionComplete
            )
            return
        }
        // Everything before this point is bounded lifecycle admission. The
        // caller may now continue draining unrelated delegate completions;
        // network-change waits, backoff, and restart happen out of band.
        onAdmissionComplete()

        await resumePersistedRetry(
            task: task,
            plan: retryPlan,
            restart: restart
        )
    }

    /// Continues a durable retry plan reconstructed during launch restoration.
    /// The caller owns task registration and tracks this async job through the
    /// manager's deferred-failure registry so shutdown can drain it safely.
    package func resumePersistedRetry(
        task: DownloadTask,
        plan: DownloadTaskPersistence.RetryPlan,
        restart: @Sendable (DownloadTask) async -> Void
    ) async {
        var activePlan = plan

        if activePlan.phase == .waitingForNetwork {
            let baseline = activePlan.networkBaseline?.value
            if let monitor = configuration.networkMonitor {
                let timeout: TimeInterval?
                if let deadline = activePlan.networkWaitDeadline {
                    let remaining = deadline.timeIntervalSince(clock.now())
                    if remaining <= 0 {
                        timeout = 0
                    } else {
                        timeout = clampDelay(
                            remaining,
                            upperBound: Self.maximumSupportedDelay
                        )
                    }
                } else {
                    timeout = nil
                }

                let changeResult = await lifecycleGate.raceWithShutdown {
                    await monitor.waitForChange(
                        from: baseline,
                        timeout: timeout
                    )
                }
                guard case .value(let newSnapshot) = changeResult else { return }
                if let newSnapshot, newSnapshot != baseline {
                    await task.resetRetryCount()
                }
            }

            let backoffPlan = makeBackoffPlan(
                retryCount: await task.retryCount
            )
            do {
                let persisted = try await persistence.updateRetryState(
                    id: task.id,
                    retryCount: await task.retryCount,
                    totalRetryCount: await task.totalRetryCount,
                    retryPlan: backoffPlan
                )
                guard persisted else { return }
            } catch {
                await markTaskFailed(
                    task,
                    reason: .fileSystemError(SendableUnderlyingError(error))
                )
                return
            }
            activePlan = backoffPlan
        }

        if activePlan.phase == .backoff,
            let deadline = activePlan.retryNotBefore
        {
            let remaining = deadline.timeIntervalSince(clock.now())
            if remaining > 0 {
                let boundedRemaining = clampDelay(
                    remaining,
                    upperBound: Self.maximumSupportedDelay
                )
                let sleepResult = await lifecycleGate.raceWithShutdown {
                    do {
                        try await clock.sleep(for: .seconds(boundedRemaining))
                        return true
                    } catch {
                        return false
                    }
                }
                guard case .value(true) = sleepResult else { return }
            }
        }

        if Task.isCancelled { return }
        let lifecycle = await task.lifecycleSnapshot()
        guard !lifecycle.state.isTerminal,
            await task.advanceAttempt(ifMatching: lifecycle) != nil
        else {
            return
        }
        await restart(task)
    }

    private func makeBackoffPlan(
        retryCount: Int
    ) -> DownloadTaskPersistence.RetryPlan {
        let delay = computeRetryDelay(retryCount: retryCount)
        return .backoff(
            retryNotBefore: clock.now().addingTimeInterval(delay)
        )
    }

    /// Computes the sleep interval before the next restart. When
    /// `configuration.exponentialBackoff` is disabled the configured
    /// fixed `retryDelay` is returned directly. When
    /// enabled the base delay grows as `retryDelay * 2^(retryCount - 1)`,
    /// then the returned delay is sampled from `base ± jitter`, clamped to
    /// `[0, effectiveCap]`. "Uncapped" configurations are still bounded to
    /// the runtime's maximum representable sleep duration.
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
        if fixedDelay >= effectiveCap
            || baseDelayWouldOverflowCap(
                initialDelay: fixedDelay,
                retryCount: retryCount,
                cap: effectiveCap
            )
        {
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

    package func markTaskFailed(
        _ task: DownloadTask,
        reason: DownloadError,
        onLifecycleAdmissionComplete: @escaping @Sendable () -> Void = {}
    ) async {
        guard await task.transitionToFailureFinalizing(error: reason) == .transitioned else {
            onLifecycleAdmissionComplete()
            return
        }
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        do {
            try await persistence.markTerminal(task: task)
        } catch {
            Self.logger.fault(
                "Failed to persist terminal marker for task \(task.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
        var removedFromPersistence = false
        do {
            try await persistence.remove(id: task.id)
            removedFromPersistence = true
        } catch {
            Self.logger.fault(
                "Failed to remove failed task \(task.id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
        if removedFromPersistence {
            // Finish old-generation cleanup before publishing a retryable
            // terminal event. A listener may call retry immediately.
            await runtimeRegistry.remove(task)
        }
        let failedLifecycle = await task.lifecycleSnapshot()
        await eventHub.publishIfCurrent(.stateChanged(.failed), for: task.id) {
            await task.lifecycleSnapshot() == failedLifecycle
        }
        await eventHub.publishTerminalAndFinish(
            .failed(reason),
            for: task.id
        )
        await task.finishFailureFinalization()
        // Delegate ordering depends only on durable state and terminal-event
        // admission. App callbacks may suspend arbitrarily and therefore stay
        // in the deferred failure job after this boundary.
        onLifecycleAdmissionComplete()
        await callbackDeliveryQueue.enqueueStateChanged(task, .failed)
        await callbackDeliveryQueue.enqueueFailed(task, reason)
    }

    private func isCancelledTransportError(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    }

    /// Returns `true` when the underlying error encodes a writer-side
    /// filesystem condition that cannot be cleared by re-attempting the
    /// transport: no permission to write at the destination, no space on
    /// the volume, the volume is read-only, or the Cocoa file-write layer
    /// already reported the equivalent classification.
    static func isDeterministicFilesystemError(_ error: SendableUnderlyingError) -> Bool {
        #if canImport(Darwin)
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case EACCES, EPERM, ENOSPC, EROFS:
                return true
            default:
                break
            }
        }
        #endif
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case CocoaError.fileWriteOutOfSpace.rawValue,
                CocoaError.fileWriteNoPermission.rawValue,
                CocoaError.fileWriteVolumeReadOnly.rawValue,
                CocoaError.fileWriteFileExists.rawValue,
                CocoaError.fileWriteInapplicableStringEncoding.rawValue:
                return true
            default:
                return false
            }
        }
        // URLSession surfaces destination-side filesystem failures through
        // its own domain (`NSURLErrorDomain`) when the background daemon
        // cannot finalize the downloaded payload — e.g. the destination
        // path is no longer writable, the volume is full, or the payload
        // exceeds a configured ceiling. These describe writer-side state
        // that another network attempt cannot improve, so classify them
        // as fatal alongside the POSIX / Cocoa cases above.
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case URLError.cannotCreateFile.rawValue,
                URLError.cannotWriteToFile.rawValue,
                URLError.cannotMoveFile.rawValue,
                URLError.cannotRemoveFile.rawValue,
                URLError.noPermissionsToReadFile.rawValue,
                URLError.dataLengthExceedsMaximum.rawValue:
                return true
            default:
                return false
            }
        }
        return false
    }
}
