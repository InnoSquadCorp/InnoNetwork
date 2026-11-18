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

    /// Admits one failed attempt: fails the task for deterministic errors or
    /// an exhausted budget, otherwise persists a retry plan and restarts
    /// after its wait.
    ///
    /// - Parameter resumeData: Resume data Foundation attached to the failed
    ///   attempt. When a retry is scheduled it is retained on the task and on
    ///   the durable retry marker so the next attempt continues the transfer
    ///   instead of restarting from byte 0.
    package func handleError(
        task: DownloadTask,
        error: SendableUnderlyingError,
        resumeData: Data? = nil,
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
        if let statusCode = DownloadHTTPStatusFailure.terminalStatusCode(from: error) {
            // The server answered this exact request with a deterministic
            // refusal (expired signature, missing object, ...). Asking again
            // returns the same status, so surface the typed status failure
            // without spending retry budget. Retryable statuses fall through
            // to the ordinary retry path below, and a refusal of a stale
            // resume point to the immediate restart from the source.
            await markTaskFailed(
                task,
                reason: .unacceptableStatusCode(statusCode),
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
        // A stale resume point (a rejected range, or a redirect target that
        // stopped answering) says nothing about the server. The task restarts
        // from the source at once, without resume data, backoff, or retry
        // budget, so it recovers even when no retry is left. The restarted
        // attempt sends no range, so it cannot be stale in turn.
        let restartsFromSource = DownloadHTTPStatusFailure.isStaleResume(error)
        let totalRetryCount = await task.totalRetryCount
        let retryCount = await task.retryCount
        let hasRetryBudget =
            totalRetryCount < configuration.maxTotalRetries
            && retryCount < configuration.maxRetryCount
        guard restartsFromSource || hasRetryBudget else {
            await markTaskFailed(
                task,
                reason: .maxRetriesExceeded(lastError: error),
                onLifecycleAdmissionComplete: onAdmissionComplete
            )
            return
        }
        let updatedTotalRetryCount: Int
        let updatedRetryCount: Int
        if restartsFromSource {
            updatedTotalRetryCount = totalRetryCount
            updatedRetryCount = retryCount
        } else {
            updatedTotalRetryCount = await task.incrementTotalRetryCount()
            updatedRetryCount = await task.incrementRetryCount()
        }
        let retryPlan: DownloadTaskPersistence.RetryPlan
        if restartsFromSource {
            retryPlan = .backoff(retryNotBefore: clock.now())
        } else if configuration.waitsForNetworkChanges,
            NetworkError.isConnectivityFailure(error),
            let monitor = configuration.networkMonitor
        {
            // Only a connectivity failure can be cured by a path change. A
            // retryable HTTP status, a timeout, or a TLS failure on a working
            // network goes straight to backoff instead of idling for the whole
            // `networkChangeTimeout` before every attempt. The table is the
            // core's, so downloads and requests agree on what "offline" means.
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
        // Captured before the retry marker becomes durable: from that write
        // on `pause(_:)` may take the waiting task, and only a task that is
        // still exactly here may be restarted when the wait ends.
        let waitingLifecycle = await task.lifecycleSnapshot()
        // This failure's resume data (or its absence) replaces whatever an
        // earlier attempt left behind. It must be in place before the retry
        // marker becomes durable: from that write on, `pause(_:)` may take
        // the waiting task and persists the task's resume data as its own,
        // so setting it any later would let a pause record a stale blob. A
        // stale resume point restarts from the source, so it keeps none.
        await task.setResumeData(restartsFromSource ? nil : resumeData)
        do {
            // `resume(_:)` starts an attempt before it records the attempt as
            // active, so the failed attempt's record can still be `.resuming`.
            // That record is this attempt's own; leaving it in place would
            // let the resume record a finished attempt as active and leave the
            // task without a transfer.
            let persisted = try await persistence.updateRetryState(
                id: task.id,
                retryCount: updatedRetryCount,
                totalRetryCount: updatedTotalRetryCount,
                retryPlan: retryPlan,
                admitsResumingRecord: true
            )
            guard persisted else {
                // A terminal/cancel path or a newer durable phase won while
                // this delegate failure was being admitted. Do not revive it
                // or surface a second terminal result from this stale job.
                onAdmissionComplete()
                return
            }
            // Attach the blob to the durable marker so a relaunch during the
            // wait continues the transfer. A pause that already replaced the
            // marker has persisted the same blob itself.
            await persistRetainedResumeData(for: task)
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

        await continueRetry(
            task: task,
            plan: retryPlan,
            waitingLifecycle: waitingLifecycle,
            restart: restart
        )
    }

    /// Continues a durable retry plan reconstructed during launch restoration.
    /// The caller owns task registration and tracks this async job through the
    /// manager's deferred-failure registry so shutdown can drain it safely.
    ///
    /// The restart is claimed against `retry.waitingLifecycle`, which
    /// restoration took before it admitted any public command. A pause,
    /// resume, or cancellation issued after launch changes the task's
    /// lifecycle, so this job ends without restarting it, however late the
    /// job itself starts.
    package func resumePersistedRetry(
        _ retry: DownloadRestoredRetry,
        restart: @Sendable (DownloadTask) async -> Void
    ) async {
        await continueRetry(
            task: retry.task,
            plan: retry.plan,
            waitingLifecycle: retry.waitingLifecycle,
            restart: restart
        )
    }

    /// Waits out `plan` and restarts `task`, provided the task is still the
    /// one that entered the wait. `waitingLifecycle` is that task's snapshot
    /// from before the retry became durable; a pause, resume, cancellation,
    /// or manual retry issued during the wait changes it, and this job then
    /// ends without rewriting the newer durable phase or starting a transfer.
    private func continueRetry(
        task: DownloadTask,
        plan: DownloadTaskPersistence.RetryPlan,
        waitingLifecycle: DownloadTaskLifecycleSnapshot,
        restart: @Sendable (DownloadTask) async -> Void
    ) async {
        var activePlan = plan

        if activePlan.phase == .waitingForNetwork {
            // A pause, resume, cancellation, or manual retry may have taken
            // the task before this job started, as when a restored retry's
            // task is paused at launch. Such a job must not wait for a
            // network change that may never come.
            guard await task.lifecycleSnapshot() == waitingLifecycle else { return }
            let baseline = activePlan.networkBaseline?.value
            var observedNetworkChange = false
            if let monitor = configuration.networkMonitor {
                let timeout: TimeInterval?
                if let deadline = activePlan.networkWaitDeadline {
                    let remaining = deadline.timeIntervalSince(clock.now())
                    guard remaining.isFinite else {
                        await markInvalidRetryDeadline(task)
                        return
                    }
                    if remaining <= 0 {
                        timeout = 0
                    } else {
                        timeout = remaining
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
                    observedNetworkChange = true
                }
            }
            // The task can also be taken during the wait. One actor turn checks
            // that this retry still owns it and, after a network change,
            // resets the consecutive retry count, so a newer attempt's count
            // is never reset.
            let ownsTask: Bool
            if observedNetworkChange {
                ownsTask = await task.resetRetryCount(ifMatching: waitingLifecycle)
            } else {
                ownsTask = await task.lifecycleSnapshot() == waitingLifecycle
            }
            guard ownsTask else { return }

            let backoffPlan = makeBackoffPlan(
                retryCount: await task.retryCount
            )
            guard
                await rewriteOwnMarker(
                    task: task,
                    replacing: activePlan,
                    with: backoffPlan,
                    waitingLifecycle: waitingLifecycle
                )
            else { return }
            activePlan = backoffPlan
        }

        if activePlan.phase == .backoff,
            let deadline = activePlan.retryNotBefore
        {
            let remaining = deadline.timeIntervalSince(clock.now())
            guard remaining.isFinite else {
                await markInvalidRetryDeadline(task)
                return
            }
            if remaining > 0 {
                let sleepResult = await lifecycleGate.raceWithShutdown {
                    do {
                        try await clock.sleep(forSeconds: remaining)
                        return true
                    } catch {
                        return false
                    }
                }
                guard case .value(true) = sleepResult else { return }
            }
        }

        if Task.isCancelled { return }
        // Claim the next attempt atomically against the snapshot this retry
        // was scheduled for. `pause(_:)` uses the same snapshot to take a
        // waiting task, so the claim fails once the task has been paused,
        // resumed into a newer attempt, or finished. A retry scheduled for
        // an already paused task has nothing to restart either.
        guard !waitingLifecycle.state.isTerminal,
            waitingLifecycle.state != .paused,
            await task.advanceAttempt(ifMatching: waitingLifecycle) != nil
        else {
            return
        }
        await restart(task)
    }

    /// Attaches the task's retained resume data to its durable retry marker
    /// through the same resume-state transition a pause uses, so a relaunch
    /// during the wait can still continue the transfer.
    ///
    /// Best effort by design: the retry itself is already durable. If this
    /// write fails or a newer phase has replaced the marker, the only loss
    /// is that a relaunched retry restarts from the source URL.
    /// Makes `backoffPlan` durable in place of this retry's own marker, the
    /// `.retryPending` record that carries `activePlan`.
    ///
    /// The store decides again, in the same write, whether the marker is
    /// still this retry's: the ownership check before it is a separate step.
    /// The retained resume data is best effort, as it is when the marker is
    /// first written. A write that cannot take the blob, for example on a
    /// nearly full disk, is repeated with the plan alone, and this process
    /// continues from the blob it holds; only a relaunch would start over. A
    /// write can also reach the log and still throw from a later step, so a
    /// refused repeat first checks whether the marker already carries
    /// `backoffPlan`.
    ///
    /// - Returns: Whether this retry still owns the task and may continue.
    private func rewriteOwnMarker(
        task: DownloadTask,
        replacing activePlan: DownloadTaskPersistence.RetryPlan,
        with backoffPlan: DownloadTaskPersistence.RetryPlan,
        waitingLifecycle: DownloadTaskLifecycleSnapshot
    ) async -> Bool {
        let retryCount = await task.retryCount
        let totalRetryCount = await task.totalRetryCount
        do {
            return try await persistence.rewriteRetryPlan(
                id: task.id,
                replacing: activePlan,
                with: backoffPlan,
                retryCount: retryCount,
                totalRetryCount: totalRetryCount,
                resumeData: await task.resumeData
            )
        } catch {
            Self.logger.error(
                "Failed to persist the retry plan of task \(task.id, privacy: .private(mask: .hash)) with its resume data: \(String(describing: error), privacy: .private(mask: .hash)). Persisting the plan alone; a relaunched retry will restart from the source URL."
            )
        }
        do {
            let rewritten = try await persistence.rewriteRetryPlan(
                id: task.id,
                replacing: activePlan,
                with: backoffPlan,
                retryCount: retryCount,
                totalRetryCount: totalRetryCount,
                resumeData: nil
            )
            if rewritten { return true }
            let record = await persistence.record(forID: task.id)
            return record?.lifecycle == .retryPending && record?.retryPlan == backoffPlan
        } catch {
            // Only a retry that still owns the task reports the storage
            // failure. A pause and a resume may have handed the task to a
            // newer attempt in the meantime.
            await markTaskFailed(
                task,
                reason: .fileSystemError(SendableUnderlyingError(error)),
                ifMatching: waitingLifecycle
            )
            return false
        }
    }

    private func persistRetainedResumeData(for task: DownloadTask) async {
        guard let resumeData = await task.resumeData else { return }
        do {
            _ = try await persistence.transitionResumeState(
                id: task.id,
                from: .retryPending,
                to: .retryPending,
                resumeData: resumeData
            )
        } catch {
            Self.logger.error(
                "Failed to persist retry resume data for task \(task.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). A relaunched retry will restart from the source URL."
            )
        }
    }

    private func makeBackoffPlan(
        retryCount: Int
    ) -> DownloadTaskPersistence.RetryPlan {
        let delay = computeRetryDelay(retryCount: retryCount)
        return .backoff(
            retryNotBefore: clock.now().addingTimeInterval(delay)
        )
    }

    private func markInvalidRetryDeadline(_ task: DownloadTask) async {
        await markTaskFailed(
            task,
            reason: .fileSystemError(
                SendableUnderlyingError(
                    domain: "InnoNetwork.DownloadRestoration", code: 1,
                    message: "The persisted retry deadline is not finite.")))
    }

    /// Computes the sleep interval before the next restart. When
    /// `configuration.exponentialBackoff` is disabled the configured
    /// fixed `retryDelay` is returned directly. When
    /// enabled the base delay grows as `retryDelay * 2^(retryCount - 1)`,
    /// then the returned delay is sampled from `base ± jitter`, clamped to
    /// `[0, effectiveCap]`. "Uncapped" generated delays retain the historical
    /// retry-plan envelope; restored finite deadlines are not shortened to it.
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
        let transition = await task.transitionToFailureFinalizing(error: reason)
        await finalizeFailure(
            task,
            reason: reason,
            transition: transition,
            onLifecycleAdmissionComplete: onLifecycleAdmissionComplete
        )
    }

    /// Fails `task` only while its lifecycle still matches `expected`, so a
    /// job that has lost the task to a pause, a resume, or a newer attempt
    /// cannot fail it.
    func markTaskFailed(
        _ task: DownloadTask,
        reason: DownloadError,
        ifMatching expected: DownloadTaskLifecycleSnapshot
    ) async {
        let transition = await task.transitionToFailureFinalizing(error: reason, ifMatching: expected)
        await finalizeFailure(task, reason: reason, transition: transition, onLifecycleAdmissionComplete: {})
    }

    private func finalizeFailure(
        _ task: DownloadTask,
        reason: DownloadError,
        transition: DownloadTerminalTransitionResult,
        onLifecycleAdmissionComplete: @escaping @Sendable () -> Void
    ) async {
        guard transition == .transitioned else {
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
