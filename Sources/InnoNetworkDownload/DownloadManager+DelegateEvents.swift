import Foundation
import InnoNetwork
import os

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
        case .completion(
            let taskIdentifier,
            let taskDescription,
            let originalRequestURL,
            let currentRequestURL,
            let payload,
            let error
        ):
            await handleCompletion(
                taskIdentifier: taskIdentifier,
                taskDescription: taskDescription,
                originalRequestURL: originalRequestURL,
                currentRequestURL: currentRequestURL,
                payload: payload,
                error: error
            )
        case .restorationBoundary:
            break
        case .backgroundEventsFinished(let completion):
            await handleBackgroundRestoreEventsFinished(completion: completion)
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
        let observedAt = configuration.taskInactivityTimeout == nil ? nil : ContinuousClock().now
        guard
            let lifecycle = await task.applyProgressIfActive(
                progress,
                observedAt: observedAt
            )
        else {
            return
        }
        await eventHub.publishIfCurrent(.progress(progress), for: task.id) {
            await task.lifecycleSnapshot() == lifecycle
        }
        guard await task.lifecycleSnapshot() == lifecycle else { return }
        await callbackDeliveryQueue.enqueueProgress(task, progress)
    }

    func handleCompletion(
        taskIdentifier: Int,
        taskDescription: String? = nil,
        originalRequestURL: URL? = nil,
        currentRequestURL: URL? = nil,
        payload: DownloadCompletionPayload?,
        error: SendableUnderlyingError?
    ) async {
        let mappedTask = await runtimeRegistry.downloadTask(for: taskIdentifier)
        let describedTask: DownloadTask?
        if mappedTask == nil, let taskDescription, !taskDescription.isEmpty {
            describedTask = await runtimeRegistry.task(withId: taskDescription)
        } else {
            describedTask = nil
        }
        guard let task = mappedTask ?? describedTask else {
            await rejectCompletionPayload(payload)
            return
        }

        let hasCorrelatedCompletionURLs =
            originalRequestURL == task.url
            && currentRequestURL.map(admitsDownloadURL) == true

        if mappedTask == nil {
            // taskDescription is process-external metadata. Validate both URL
            // snapshots before consuming any restoration admission flag or
            // installing an identifier mapping. Invalid fallback completions
            // are ignored rather than allowed to mutate the described task.
            guard hasCorrelatedCompletionURLs else {
                await rejectCompletionPayload(payload)
                return
            }
            guard
                await task.prepareForRestoredCompletion(
                    hasSuccessfulPayload: error == nil && payload != nil
                ) != nil
            else {
                // A taskDescription can outlive its concrete URLSession
                // attempt. In particular, a late cancellation from paused
                // attempt A must not be applied to resumed attempt B merely
                // because both share the same logical task ID.
                await rejectCompletionPayload(payload)
                return
            }
            managerState.pendingRestoreFailures.remove(task.id)
            await runtimeRegistry.setMapping(downloadTask: task, for: taskIdentifier)
        }

        // `cancel(byProducingResumeData:)` may invoke the URLSession delegate
        // before its resume-data completion handler. The pause path owns this
        // exact cancellation and will retire the attempt once the payload is
        // available; consuming it here would orphan the still-downloading
        // logical task. Identifier matching is essential because a resumed
        // attempt can exist while an old cancellation callback is still late.
        if let error,
            error.domain == NSURLErrorDomain,
            error.code == URLError.cancelled.rawValue,
            managerState.pausingTaskIdentifiers[task.id] == taskIdentifier
        {
            await rejectCompletionPayload(payload)
            return
        }

        // Terminal paths can await persistence after sealing their event
        // partition. A delegate callback already queued before that boundary
        // must not mutate progress, reopen a partition, or move a staged file
        // after cancellation/failure/completion has won.
        guard !(await task.state).isTerminal else {
            await runtimeRegistry.removeAttemptRuntime(taskIdentifier: taskIdentifier)
            await rejectCompletionPayload(payload)
            return
        }

        // Foreground redirect admission synthesizes this private error with
        // the rejected target and policy reason. Its current URL is expected
        // to fail the ordinary admission check, so route it before replacing
        // those diagnostics with the generic final-URL failure below.
        if let error,
            mappedTask != nil,
            originalRequestURL == task.url,
            DownloadRedirectAdmissionFailure.invalidURLDescription(from: error) != nil
        {
            await runtimeRegistry.removeAttemptRuntime(taskIdentifier: taskIdentifier)
            await rejectCompletionPayload(payload)
            await scheduleFailureHandling(task: task, error: error)
            return
        }

        // Success and ordinary transport errors share the same correlation
        // boundary. A mapped identifier proves runtime ownership, but not that
        // the delegate payload retained the logical source and an admitted
        // final response URL.
        guard originalRequestURL == task.url else {
            await runtimeRegistry.removeAttemptRuntime(taskIdentifier: taskIdentifier)
            await rejectCompletionPayload(payload)
            await scheduleFailureHandling(
                task: task,
                error: DownloadRedirectAdmissionFailure.make(
                    targetURL: originalRequestURL,
                    reason: "The completion's original request did not match the logical download source."
                )
            )
            return
        }
        guard let currentRequestURL, admitsDownloadURL(currentRequestURL) else {
            await runtimeRegistry.removeAttemptRuntime(taskIdentifier: taskIdentifier)
            await rejectCompletionPayload(payload)
            await scheduleFailureHandling(
                task: task,
                error: DownloadRedirectAdmissionFailure.make(
                    targetURL: currentRequestURL,
                    reason: "Rejected or missing final response URL by download admission policy."
                )
            )
            return
        }

        if let error {
            await runtimeRegistry.removeAttemptRuntime(taskIdentifier: taskIdentifier)
            await rejectCompletionPayload(payload)
            await scheduleFailureHandling(task: task, error: error)
            return
        }

        guard let payload else {
            await runtimeRegistry.removeAttemptRuntime(taskIdentifier: taskIdentifier)
            await scheduleFailureHandling(
                task: task,
                error: SendableUnderlyingError(
                    domain: "InnoNetworkDownload",
                    code: -1,
                    message: "Download completed without temporary file location."
                )
            )
            return
        }

        await runtimeRegistry.removeAttemptRuntime(taskIdentifier: taskIdentifier)
        let stagedCompletion: StagedCompletion
        do {
            switch payload {
            case .journaled(let completion):
                stagedCompletion = completion
            case .legacy(let location):
                stagedCompletion = try completionStager.stage(
                    location,
                    taskID: task.id,
                    originalRequestURL: originalRequestURL,
                    currentRequestURL: currentRequestURL
                )
            }
        } catch {
            await scheduleFailureHandling(
                task: task,
                error: SendableUnderlyingError(error)
            )
            return
        }
        do {
            _ = try await transferCoordinator.completeDownload(
                task: task,
                stagedCompletion: stagedCompletion
            )
        } catch {
            // `completeDownload` already published a filesystem failure while
            // retaining the journal. Never route commit I/O through transport
            // retry, which would overwrite the recovery evidence.
        }
    }

    private func rejectCompletionPayload(_ payload: DownloadCompletionPayload?) async {
        guard let payload else { return }
        switch payload {
        case .legacy(let location):
            DownloadCompletionStager.removeIfPresent(location)
        case .journaled(let completion):
            let taskID = completion.manifest.taskID
            if let record = await persistence.record(forID: taskID) {
                if record.lifecycle == .committing {
                    guard let metadata = record.commitMetadata,
                        (try? rejectedCompletionMetadata(
                            completion,
                            destinationURL: record.destinationURL
                        )) == metadata
                    else {
                        // A different durable commit owns this deterministic
                        // key. Preserve its evidence rather than allowing a
                        // stale or forged callback to abandon it.
                        return
                    }
                    do {
                        guard
                            try await persistence.abandonCommit(
                                id: taskID,
                                metadata: metadata
                            )
                        else { return }
                    } catch {
                        Self.logger.fault(
                            "Failed to abandon rejected completion journal \(taskID, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). Recovery evidence was preserved."
                        )
                        return
                    }
                } else if record.lifecycle == .terminal,
                    record.commitOutcome == .finished
                {
                    // A finished receipt may still need the journal if final
                    // destination validation fails on the next launch.
                    return
                }
            }

            do {
                try completionStager.cleanup(completion)
                completionAdmissionGate.release(taskID: taskID)
            } catch {
                Self.logger.fault(
                    "Failed to clean rejected completion journal \(taskID, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). Recovery evidence remains quarantined."
                )
            }
        }
    }

    private func rejectedCompletionMetadata(
        _ completion: StagedCompletion,
        destinationURL: URL
    ) throws -> DownloadTaskPersistence.CommitMetadata {
        try completionStager.validate(completion)
        return DownloadTaskPersistence.CommitMetadata(
            stagingKey: completion.manifest.key,
            originalRequestURL: completion.manifest.originalRequestURL,
            currentRequestURL: completion.manifest.currentRequestURL,
            destinationURL: destinationURL,
            expectedByteCount: completion.manifest.expectedByteCount,
            payloadSHA256: try completionStager.payloadSHA256(for: completion)
        )
    }

    /// Package-test compatibility path. Production delegate events carry a
    /// deterministic journal payload.
    func handleCompletion(
        taskIdentifier: Int,
        taskDescription: String? = nil,
        originalRequestURL: URL? = nil,
        currentRequestURL: URL? = nil,
        location: URL?,
        error: SendableUnderlyingError?
    ) async {
        await handleCompletion(
            taskIdentifier: taskIdentifier,
            taskDescription: taskDescription,
            originalRequestURL: originalRequestURL,
            currentRequestURL: currentRequestURL,
            payload: location.map(DownloadCompletionPayload.legacy),
            error: error
        )
    }

    func scheduleFailureHandling(
        task: DownloadTask,
        error: SendableUnderlyingError
    ) async {
        let jobID = UUID()
        let admission = DownloadFailureAdmissionGate()
        let failureCoordinator = self.failureCoordinator
        let transferCoordinator = self.transferCoordinator
        let job = Task { [weak self] in
            await failureCoordinator.handleError(
                task: task,
                error: error,
                onAdmissionComplete: { admission.complete() }
            ) { task in
                await transferCoordinator.startDownload(task, mode: .automaticRetry)
            }
            await self?.deferredFailureDidFinish(jobID)
        }
        managerState.deferredFailureTasks[jobID] = job
        await admission.wait()
    }

    func scheduleRestoredRetries(
        _ retries: [DownloadRestoredRetry]
    ) {
        guard !isShutdown else { return }
        let failureCoordinator = self.failureCoordinator
        let transferCoordinator = self.transferCoordinator
        for retry in retries {
            let jobID = UUID()
            let job = Task { [weak self] in
                await failureCoordinator.resumePersistedRetry(
                    task: retry.task,
                    plan: retry.plan
                ) { task in
                    await transferCoordinator.startDownload(
                        task,
                        mode: .automaticRetry
                    )
                }
                await self?.deferredFailureDidFinish(jobID)
            }
            managerState.deferredFailureTasks[jobID] = job
        }
    }

    private func deferredFailureDidFinish(_ jobID: UUID) {
        managerState.deferredFailureTasks.removeValue(forKey: jobID)
    }

    func drainDeferredFailureTasks() async {
        while !managerState.deferredFailureTasks.isEmpty {
            let jobs = Array(managerState.deferredFailureTasks.values)
            for job in jobs {
                await job.value
            }
        }
    }
}

private final class DownloadFailureAdmissionGate: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var isComplete = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                if state.isComplete { return true }
                state.continuation = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func complete() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.isComplete else { return nil }
            state.isComplete = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}
