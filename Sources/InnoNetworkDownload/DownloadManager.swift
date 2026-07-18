import Foundation
import InnoNetwork
import OSLog
import os

enum DownloadPersistenceStateError: Error {
    case missingPausingRecord(String)
    case missingResumingRecord(String)
    case failedToFinalizeResumingRecord(String)
}

public enum DownloadEvent: Sendable {
    case progress(DownloadProgress)
    case stateChanged(DownloadState)
    case completed(URL)
    case failed(DownloadError)
}

public enum DownloadManagerError: Error, Sendable, Equatable {
    case duplicateSessionIdentifier(String)
}

extension DownloadManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateSessionIdentifier(let identifier):
            return
                "DownloadManager sessionIdentifier '\(identifier)' is already in use. Use a unique sessionIdentifier for multiple managers."
        }
    }
}


/// Manager for the download lifecycle.
///
/// ## Isolation contract
///
/// `DownloadManager` is a `public actor`. All mutable state lives inside the
/// actor's isolation, plus isolated or lock-backed collaborators:
///
/// 1. **`DownloadRuntimeRegistry`** — actor that owns the live mapping
///    between `DownloadTask`, `URLSessionDownloadTask`, and runtime
///    callbacks.
/// 2. **`DownloadTaskPersistence`** — actor that owns the on-disk task log.
/// 3. **`BackgroundCompletionStore`** — lock-backed storage that synchronously
///    registers the system-supplied background completion handler.
/// 4. **`DownloadCallbackDeliveryQueue`** — actor that preserves per-task app
///    callback order without holding the Foundation delegate FIFO.
///
/// Foundation-driven delegate callbacks (URL session's serial queue) cross
/// into the actor through a single delegate-event stream. The synchronous
/// callbacks only enqueue immutable events, and one consumer task drains them
/// into the actor so progress/completion ordering follows delegate order. App
/// callbacks then move to their per-task delivery lane; the system background
/// completion handler therefore does not wait for arbitrary app code.
///
/// `handleBackgroundSessionCompletion(_:completion:)` is `nonisolated` so
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
/// (a synchronous Foundation entry point) can call it without `await`.
public actor DownloadManager {
    // Internal so the same-module extension files (DownloadManager+DelegateEvents,
    // DownloadManager+InactivityWatchdog, DownloadManager+RestorationDrain) can
    // share the same os.log category. Not part of the public API surface.
    static let logger = Logger(subsystem: "innosquad.network.download", category: "DownloadManager")

    private static let activeSessionIdentifiers = OSAllocatedUnfairLock(initialState: Set<String>())

    // Several stored properties below drop `private` (defaulting to `internal`)
    // so the same-module extension files split out of this actor can read
    // them. The actor's public API surface is unchanged — `internal` keeps
    // them hidden from external modules.
    let configuration: DownloadConfiguration
    let session: any DownloadURLSession
    private let delegate: DownloadSessionDelegate
    let backgroundCompletionStore: BackgroundCompletionStore
    let persistence: DownloadTaskPersistence
    let completionStager: DownloadCompletionStager
    let completionAdmissionGate: DownloadCompletionAdmissionGate

    let runtimeRegistry: DownloadRuntimeRegistry
    let callbackDeliveryQueue: DownloadCallbackDeliveryQueue
    let restoreBarrier: RestoreBarrier
    let invalidationBarrier: InvalidationBarrier
    let shutdownBarrier: InvalidationBarrier
    let transferCoordinator: DownloadTransferCoordinator
    let restoreCoordinator: DownloadRestoreCoordinator
    let failureCoordinator: DownloadFailureCoordinator
    var pendingRestoreFailures: Set<String> = []
    var drainingRestoreFailureTaskIDs: Set<String> = []
    var restoreFailureDrainWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Durable `.terminal(.finished)` receipts reconstructed at launch remain
    /// registered until an app callback or event consumer has accepted the
    /// recovered completion. This prevents the same receipt from replaying on
    /// every launch while avoiding removal before any consumer can observe it.
    var pendingRestoreCompletions: Set<String> = []
    var drainingRestoreCompletionTaskIDs: Set<String> = []
    /// Background sessions can enqueue completion delegates after the
    /// `getAllTasks` snapshot. Keep synthetic missing-task failures provisional
    /// until Foundation's real `urlSessionDidFinishEvents` boundary arrives.
    var provisionalBackgroundRestoreFailureIDs: Set<String> = []
    var backgroundRestoreSnapshotPrepared = false
    var backgroundRestoreBoundaryPending = false
    var backgroundRestoreEventsFinished = false
    var pendingBackgroundSessionCompletions: [@Sendable () -> Void] = []
    /// Tracks the one-shot shutdown latch. Kept `nonisolated` (and behind
    /// an `OSAllocatedUnfairLock`) so the `deinit` warning path and the
    /// actor-isolated ``shutdown()`` agree on a single state without
    /// requiring re-entry into the actor — mirrors the pattern in
    /// `InnoNetworkWebSocket.WebSocketManager`.
    nonisolated let lifecycleGate: DownloadLifecycleGate
    let eventHub: TaskEventHub<DownloadEvent>
    let delegateEventChannel: DownloadDelegateEventChannel
    /// Background task that polls in-flight downloads and cancels any that
    /// have not received a progress callback for at least
    /// `taskInactivityTimeout` from ``DownloadTransferPack``. `nil` when the
    /// configuration disables the watchdog.
    var inactivityWatchdogTask: Task<Void, Never>?
    /// Serializes pause production per logical task while the manager actor is
    /// reentrant at `cancelByProducingResumeData()` and persistence awaits.
    var pausingTaskIDs: Set<String> = []
    /// Serializes resume setup per logical task while persistence and opaque
    /// resume-data validation suspend the manager actor.
    var resumingTaskIDs: Set<String> = []
    /// Pins the concrete URLSession attempt whose cancellation belongs to an
    /// in-flight pause. The delegate may report that cancellation before
    /// `cancelByProducingResumeData()` resumes; matching it by identifier keeps
    /// a later resumed attempt from being mistaken for the one being paused.
    var pausingTaskIdentifiers: [String: Int] = [:]
    /// Drains delegate events into actor-isolated handlers; finished and
    /// awaited in ``shutdown()`` so buffered completion files are consumed
    /// before teardown returns. Stored behind a nonisolated lock because it
    /// is assigned from the nonisolated init.
    nonisolated let delegateConsumerTaskHandle =
        OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Runs the one-shot persistence restoration; cancelled in ``shutdown()``
    /// to prevent late completions from racing the invalidation barrier.
    nonisolated let restorationTaskHandle =
        OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Retry/network-change waits are detached from the single delegate FIFO
    /// so one failed download cannot block unrelated completion commits or
    /// the app's background-session completion callback.
    var deferredFailureTasks: [UUID: Task<Void, Never>] = [:]
    /// Counts public lifecycle mutations that were admitted before shutdown
    /// closed the latch. Teardown waits for them before sweeping runtime state
    /// and invalidating the session, so an operation suspended in persistence
    /// cannot register a new URL task after shutdown returns.
    var shutdownTrackedOperationCount = 0
    var shutdownTrackedOperationWaiters: [CheckedContinuation<Void, Never>] = []

    // Internal so extension files in this module can pattern-match on the
    // payload when implementing the delegate-event consumer.
    enum DelegateEvent: Sendable {
        case progress(
            taskIdentifier: Int,
            bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        )
        case completion(
            taskIdentifier: Int,
            taskDescription: String?,
            originalRequestURL: URL?,
            currentRequestURL: URL?,
            payload: DownloadCompletionPayload?,
            error: SendableUnderlyingError?
        )
        case restorationBoundary
        case backgroundEventsFinished(completion: (@Sendable () -> Void)?)
    }

    /// Creates a download manager bound to `configuration.sessionIdentifier`.
    ///
    /// Each manager owns an actor-isolated runtime registry, append-log
    /// persistence store, event hub, and background `URLSession`. The session
    /// identifier must be unique within the process. This throwing initializer
    /// surfaces duplicate-identifier and persistence setup failures directly.
    ///
    /// - Parameter configuration: Session, retry, event, and persistence
    ///   settings for this download domain.
    /// - Throws: ``DownloadManagerError/duplicateSessionIdentifier(_:)`` if
    ///   another live manager has already claimed the same session identifier,
    ///   or the underlying persistence directory cannot be created, locked,
    ///   or read. Transient access failures preserve existing state so a later
    ///   initialization attempt can restore it.
    public init(configuration: DownloadConfiguration = .safeDefaults()) throws {
        try self.init(
            configuration: configuration,
            persistence: try DownloadTaskPersistence(
                sessionIdentifier: configuration.sessionIdentifier,
                baseDirectoryURL: configuration.persistenceBaseDirectoryURL,
                fsyncPolicy: configuration.persistenceFsyncPolicy,
                compactionPolicy: configuration.persistenceCompactionPolicy
            )
        )
    }

    package init(
        configuration: DownloadConfiguration = .safeDefaults(),
        persistence: DownloadTaskPersistence,
        clock: any InnoNetworkClock = SystemClock()
    ) throws {
        // Claim the session identifier before constructing the URLSession so a
        // duplicate-identifier failure cannot leak a delegate-attached session
        // (its deinit would otherwise outlive the throwing init).
        try Self.registerSessionIdentifier(configuration.sessionIdentifier)

        let callbacks = DownloadSessionDelegateCallbacks()
        let backgroundCompletionStore = BackgroundCompletionStore()
        let completionStager = DownloadCompletionStager(
            directoryURL: DownloadCompletionStager.directoryURL(for: configuration)
        )
        let completionAdmissionGate = DownloadCompletionAdmissionGate()
        completionStager.removeStaleFiles()
        let delegate = DownloadSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore,
            completionStager: completionStager,
            completionAdmissionGate: completionAdmissionGate,
            allowsInsecureHTTP: configuration.allowsInsecureHTTP
        )

        let sessionConfig = configuration.makeURLSessionConfiguration()
        let urlSession = URLSession(
            configuration: sessionConfig,
            delegate: delegate,
            delegateQueue: nil
        )

        try self.init(
            configuration: configuration,
            persistence: persistence,
            urlSession: urlSession,
            delegate: delegate,
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore,
            completionStager: completionStager,
            registersSessionIdentifier: false,
            clock: clock
        )
    }

    /// Package-level designated initializer allowing tests to inject a
    /// `DownloadURLSession` stub.
    package init(
        configuration: DownloadConfiguration,
        persistence: DownloadTaskPersistence,
        urlSession: any DownloadURLSession,
        delegate: DownloadSessionDelegate,
        callbacks: DownloadSessionDelegateCallbacks,
        backgroundCompletionStore: BackgroundCompletionStore,
        completionStager: DownloadCompletionStager? = nil,
        registersSessionIdentifier: Bool = true,
        clock: any InnoNetworkClock = SystemClock()
    ) throws {
        let completionStager =
            completionStager
            ?? DownloadCompletionStager(
                directoryURL: DownloadCompletionStager.directoryURL(for: configuration)
            )
        let completionAdmissionGate = delegate.completionAdmissionGate
        let delegateEventChannel = DownloadDelegateEventChannel()
        let invalidationBarrier = InvalidationBarrier()
        let shutdownBarrier = InvalidationBarrier()
        let runtimeRegistry = DownloadRuntimeRegistry()
        let callbackDeliveryQueue = DownloadCallbackDeliveryQueue(
            runtimeRegistry: runtimeRegistry
        )
        let restoreBarrier = RestoreBarrier()
        let lifecycleGate = DownloadLifecycleGate()
        let eventHub = TaskEventHub<DownloadEvent>(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .downloadTask
        )
        let transferCoordinator = DownloadTransferCoordinator(
            session: urlSession,
            runtimeRegistry: runtimeRegistry,
            callbackDeliveryQueue: callbackDeliveryQueue,
            persistence: persistence,
            eventHub: eventHub,
            lifecycleGate: lifecycleGate,
            completionStager: completionStager,
            completionAdmissionGate: completionAdmissionGate
        )
        let restoreCoordinator = DownloadRestoreCoordinator(
            configuration: configuration,
            session: urlSession,
            runtimeRegistry: runtimeRegistry,
            persistence: persistence,
            transferCoordinator: transferCoordinator,
            completionStager: completionStager,
            completionAdmissionGate: completionAdmissionGate
        )
        let failureCoordinator = DownloadFailureCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry,
            callbackDeliveryQueue: callbackDeliveryQueue,
            persistence: persistence,
            eventHub: eventHub,
            lifecycleGate: lifecycleGate,
            clock: clock
        )
        if registersSessionIdentifier {
            try Self.registerSessionIdentifier(configuration.sessionIdentifier)
        }
        callbacks.setInvalidationHandler {
            [identifier = configuration.sessionIdentifier, invalidationBarrier, lifecycleGate] _ in
            // Explicit shutdown holds the claim through delegate drain and
            // the authoritative persistence sweep. The deinit fallback has no
            // such worker, so it releases when Foundation invalidates.
            if !lifecycleGate.isShutdown {
                Self.unregisterSessionIdentifier(identifier)
            }
            Task {
                await invalidationBarrier.complete()
            }
        }
        self.configuration = configuration
        self.delegate = delegate
        self.backgroundCompletionStore = backgroundCompletionStore
        self.persistence = persistence
        self.completionStager = completionStager
        self.completionAdmissionGate = completionAdmissionGate
        self.runtimeRegistry = runtimeRegistry
        self.callbackDeliveryQueue = callbackDeliveryQueue
        self.restoreBarrier = restoreBarrier
        self.lifecycleGate = lifecycleGate
        self.invalidationBarrier = invalidationBarrier
        self.shutdownBarrier = shutdownBarrier
        self.transferCoordinator = transferCoordinator
        self.restoreCoordinator = restoreCoordinator
        self.failureCoordinator = failureCoordinator
        self.eventHub = eventHub
        self.session = urlSession
        self.delegateEventChannel = delegateEventChannel

        // Delegate boundary: URL session's serial delegate queue invokes the
        // closures below synchronously. They enqueue value events into one
        // channel. Its single consumer awaits actor-isolated handling in FIFO
        // order; pending progress is coalesced per task while completions stay
        // lossless.
        callbacks.setHandlers(
            onProgress: {
                [delegateEventChannel] taskIdentifier, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite
                in
                delegateEventChannel.sendProgress(
                    taskIdentifier: taskIdentifier,
                    bytesWritten: bytesWritten,
                    totalBytesWritten: totalBytesWritten,
                    totalBytesExpectedToWrite: totalBytesExpectedToWrite
                )
            },
            onCompletion: {
                [delegateEventChannel]
                taskIdentifier,
                taskDescription,
                originalRequestURL,
                currentRequestURL,
                payload,
                error in
                delegateEventChannel.sendCompletion(
                    taskIdentifier: taskIdentifier,
                    taskDescription: taskDescription,
                    originalRequestURL: originalRequestURL,
                    currentRequestURL: currentRequestURL,
                    payload: payload,
                    error: error
                )
            },
            onBackgroundEventsFinished: { [delegateEventChannel] completion in
                delegateEventChannel.sendBackgroundEventsFinished(completion: completion)
            }
        )
        let consumerTask: Task<Void, Never> = Task { [weak self, delegateEventChannel, restoreBarrier] in
            _ = try? await restoreBarrier.wait()
            while let event = await delegateEventChannel.next() {
                if Task.isCancelled {
                    DownloadManager.removeStagedLocationIfNeeded(from: event)
                    continue
                }
                await DownloadManager.consumeDelegateEvent(event, manager: self)
            }
        }
        delegateConsumerTaskHandle.withLock { $0 = consumerTask }

        // Restoration runs on a detached Task so the actor init returns
        // immediately. waitForRestore() gates every public entry point on the
        // restoreBarrier, so callers that issue downloads before restoration
        // completes block until the barrier opens.
        let restoreTask: Task<Void, Never> = Task { [weak self, restoreBarrier, delegateEventChannel] in
            guard let self else {
                await restoreBarrier.complete()
                return
            }
            let restoreResult = await self.restoreCoordinator.restorePendingDownloads()
            // The regular delegate consumer waits on restoreBarrier. Drain a
            // FIFO snapshot here first so staged completions delivered during
            // session reattachment cannot be discarded before their logical
            // tasks are registered. The boundary separates later live events.
            delegateEventChannel.sendRestorationBoundary()
            while let event = await delegateEventChannel.next() {
                if case .restorationBoundary = event { break }
                if Task.isCancelled {
                    DownloadManager.removeStagedLocationIfNeeded(from: event)
                } else {
                    await self.handleDelegateEvent(event)
                }
            }
            if !Task.isCancelled, !self.isShutdown {
                if self.configuration.sessionMode == .background {
                    await self.prepareBackgroundRestoreBoundary(restoreResult)
                } else {
                    // Foreground URLSession delegate callbacks are in-process;
                    // the FIFO marker is the complete restoration snapshot.
                    for task in await self.runtimeRegistry.allTasks() {
                        await task.endRestoredSuccessAdmission()
                    }
                    let pending = await self.remainingRestoreFailures(
                        from: restoreResult.failedTaskIDs
                    )
                    await self.recordPendingRestoreCompletions(
                        restoreResult.completedTaskIDs
                    )
                    await self.recordPendingRestoreFailures(pending)
                    await self.scheduleRestoredRetries(
                        restoreResult.deferredRetries
                    )
                }
            }
            // Always release callers, including the shutdown path that
            // cancelled restoration while Foundation task enumeration was in
            // flight. `RestoreBarrier.complete()` is idempotent.
            await restoreBarrier.complete()
        }
        restorationTaskHandle.withLock { $0 = restoreTask }

        if let timeout = configuration.taskInactivityTimeout {
            Task { [weak self] in
                await self?.startInactivityWatchdog(timeout: timeout)
            }
        }
    }

    static func consumeDelegateEvent(_ event: DelegateEvent, manager: DownloadManager?) async {
        guard let manager else {
            removeStagedLocationIfNeeded(from: event)
            return
        }
        await manager.handleDelegateEvent(event)
    }

    /// Releases resources carried by a delegate event that cannot be consumed.
    /// Deterministic production journals deliberately remain on disk:
    /// persistence restoration is the only authority allowed to commit or
    /// discard them after shutdown, channel rejection, or manager loss. A
    /// synchronously claimed UIKit completion handler is returned on the main
    /// actor so an invalidated manager cannot strand the system wake-up.
    static func removeStagedLocationIfNeeded(from event: DelegateEvent) {
        switch event {
        case .completion(_, _, _, _, let payload, _):
            guard let payload else { return }
            switch payload {
            case .journaled:
                break
            case .legacy(let location):
                DownloadCompletionStager.removeIfPresent(location)
            }
        case .backgroundEventsFinished(let completion):
            guard let completion else { return }
            Task { @MainActor in
                completion()
            }
        case .progress, .restorationBoundary:
            break
        }
    }

    public func retry(_ task: DownloadTask) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else { return }
        guard await runtimeRegistry.owns(task) else { return }
        await waitForRestoreFailureDrain(taskID: task.id)
        await task.waitForFailureFinalization()
        guard await claimDestructiveLifecycle(taskID: task.id) else { return }
        await task.endRestoredSuccessAdmission()
        provisionalBackgroundRestoreFailureIDs.remove(task.id)
        pendingRestoreFailures.remove(task.id)
        // A rejected task remains public so the caller can inspect its typed
        // failure. Re-check before resetting it: otherwise `retry(_:)` could
        // turn that terminal object into a transport-policy bypass.
        guard admitsDownloadURL(task.url) else { return }
        guard let retryLifecycle = await task.beginManualRetry() else { return }
        await runtimeRegistry.add(task)
        // The failed attempt atomically closes its event partition. Wait for
        // that partition to detach before the same logical task ID publishes
        // a new generation; otherwise a fast retry can send its waiting and
        // downloading events into the still-closed predecessor partition.
        await eventHub.finishAndWaitForClosure(taskID: task.id)
        guard await task.lifecycleSnapshot() == retryLifecycle, !isShutdown else { return }
        await transferCoordinator.startDownload(task, mode: .manualRetry)
    }

    func admitsDownloadURL(_ url: URL) -> Bool {
        do {
            try NetworkURLAdmission.validate(
                url,
                policy: .http(allowsInsecure: configuration.allowsInsecureHTTP)
            )
            return true
        } catch {
            return false
        }
    }

    private func isCommitRecoveryProtected(taskID: String) async -> Bool {
        if await completionAdmissionGate.hasJournalAfterStaging(taskID: taskID) {
            return true
        }
        if let record = await persistence.record(forID: taskID),
            record.lifecycle == .committing
        {
            completionAdmissionGate.registerJournal(taskID: taskID)
            return true
        }
        if let record = await persistence.record(forID: taskID),
            record.lifecycle == .terminal,
            record.commitOutcome == .finished
        {
            completionAdmissionGate.registerJournal(taskID: taskID)
            return true
        }
        do {
            let hasArtifacts = try completionStager.hasArtifacts(forTaskID: taskID)
            if hasArtifacts {
                completionAdmissionGate.registerJournal(taskID: taskID)
            }
            return hasArtifacts
        } catch {
            Self.logger.fault(
                "Failed to inspect completion journal for task \(taskID, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash)). Lifecycle mutation is denied to preserve recovery evidence."
            )
            return true
        }
    }

    func claimDestructiveLifecycle(taskID: String) async -> Bool {
        guard await completionAdmissionGate.claimDestructiveLifecycle(taskID: taskID) else {
            return false
        }
        guard !(await isCommitRecoveryProtected(taskID: taskID)) else {
            return false
        }
        return true
    }

    func commitRecoveryProtectedTaskIDs(
        in records: [DownloadTaskPersistence.Record],
        additionalTaskIDs: Set<String> = []
    ) async -> Set<String> {
        var protected = Set<String>()
        let taskIDs = Set(records.map(\.id)).union(additionalTaskIDs)
        protected.reserveCapacity(taskIDs.count)
        for taskID in taskIDs {
            if !(await claimDestructiveLifecycle(taskID: taskID)) {
                protected.insert(taskID)
            }
        }
        return protected
    }

    func admitsResumedURLTask(
        _ urlTask: any DownloadURLTask,
        expectedURL: URL
    ) -> Bool {
        guard
            let originalURL = urlTask.originalRequest?.url,
            let currentURL = urlTask.currentRequest?.url,
            originalURL == expectedURL,
            currentURL == expectedURL
        else {
            return false
        }
        return admitsDownloadURL(originalURL) && admitsDownloadURL(currentURL)
    }

    /// Wired into the host app's
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// entry point. That method is synchronous, so this entry point is
    /// `nonisolated` to avoid forcing callers to await.
    public nonisolated func handleBackgroundSessionCompletion(
        _ identifier: String, completion: @escaping @Sendable () -> Void
    ) {
        guard configuration.sessionMode == .background,
            identifier == configuration.sessionIdentifier
        else {
            completion()
            return
        }
        backgroundCompletionStore.set(completion)
    }

    deinit {
        delegateEventChannel.finish()
        if !isShutdown {
            // Apps that drop the manager without calling `shutdown()` get a
            // visible warning so the leak shows up in os_log instead of as
            // a silent background session lingering past the manager's
            // lifetime. We can't `await shutdown()` from `deinit`, so the
            // best we can do is finish the session and rely on Foundation
            // to drain in-flight transfers in the background.
            Self.logger.warning(
                "DownloadManager deinit reached without shutdown() — call shutdown() explicitly for bounded teardown of session '\(self.configuration.sessionIdentifier, privacy: .public)'"
            )
        }
        // URLSession retains its delegate until explicitly invalidated; without
        // this call the underlying session and its DownloadSessionDelegate (and
        // every callback closure they retain) outlive the manager. Background
        // sessions also stay registered with the OS. `finishTasksAndInvalidate`
        // lets in-flight transfers complete before tearing down, and is
        // idempotent against any earlier ``shutdown()`` call. Apps that need
        // bounded teardown latency should call `shutdown()` explicitly so the
        // session identifier is released before this fallback runs.
        session.finishTasksAndInvalidate()
    }

    private static func registerSessionIdentifier(_ identifier: String) throws {
        let inserted = activeSessionIdentifiers.withLock { identifiers in
            identifiers.insert(identifier).inserted
        }
        guard inserted else {
            throw DownloadManagerError.duplicateSessionIdentifier(identifier)
        }
    }

    static func unregisterSessionIdentifier(_ identifier: String) {
        _ = activeSessionIdentifiers.withLock { identifiers in
            identifiers.remove(identifier)
        }
    }

}
