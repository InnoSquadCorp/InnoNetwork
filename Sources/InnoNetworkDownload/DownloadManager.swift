import Foundation
import InnoNetwork
import OSLog
import os

private enum DownloadPersistenceStateError: Error {
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

public struct DownloadEventSubscription: Hashable, Sendable {
    fileprivate let taskId: String
    fileprivate let listenerID: UUID

    public var id: UUID { listenerID }
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

    /// Recommended throwing factory for constructing a `DownloadManager`.
    ///
    /// Equivalent to ``init(configuration:)``, but discoverable via type-level
    /// autocomplete and consistent with the `make(...)` style used elsewhere
    /// in the package (e.g., `URLQueryEncoder`, observability builders). Use
    /// this when factory-style construction reads more clearly at the call
    /// site.
    ///
    /// - Parameter configuration: The configuration to bind. Pass
    ///   ``DownloadConfiguration/safeDefaults(sessionIdentifier:)`` with a
    ///   unique identifier when multiple managers must coexist in the same
    ///   process.
    /// - Returns: A new `DownloadManager` ready to receive download requests.
    /// - Throws: ``DownloadManagerError/duplicateSessionIdentifier(_:)`` if
    ///   another manager has already claimed the same session identifier, or
    ///   an error from creating, locking, or reading the persistence store.
    ///   A transient store-access failure preserves the existing state so a
    ///   later initialization attempt can restore it.
    public static func make(
        configuration: DownloadConfiguration = .safeDefaults()
    ) throws -> DownloadManager {
        try DownloadManager(configuration: configuration)
    }

    private static let activeSessionIdentifiers = OSAllocatedUnfairLock(initialState: Set<String>())

    // Several stored properties below drop `private` (defaulting to `internal`)
    // so the same-module extension files split out of this actor can read
    // them. The actor's public API surface is unchanged — `internal` keeps
    // them hidden from external modules.
    let configuration: DownloadConfiguration
    private let session: any DownloadURLSession
    private let delegate: DownloadSessionDelegate
    let backgroundCompletionStore: BackgroundCompletionStore
    let persistence: DownloadTaskPersistence
    let completionStager: DownloadCompletionStager
    let completionAdmissionGate: DownloadCompletionAdmissionGate

    let runtimeRegistry: DownloadRuntimeRegistry
    let callbackDeliveryQueue: DownloadCallbackDeliveryQueue
    let restoreBarrier: RestoreBarrier
    private let invalidationBarrier: InvalidationBarrier
    private let shutdownBarrier: InvalidationBarrier
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
    nonisolated private let lifecycleGate: DownloadLifecycleGate
    let eventHub: TaskEventHub<DownloadEvent>
    private let delegateEventChannel: DownloadDelegateEventChannel
    /// Background task that polls in-flight downloads and cancels any that
    /// have not received a progress callback for at least
    /// ``DownloadConfiguration/taskInactivityTimeout``. `nil` when the
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
    nonisolated private let delegateConsumerTaskHandle =
        OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Runs the one-shot persistence restoration; cancelled in ``shutdown()``
    /// to prevent late completions from racing the invalidation barrier.
    nonisolated private let restorationTaskHandle =
        OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Retry/network-change waits are detached from the single delegate FIFO
    /// so one failed download cannot block unrelated completion commits or
    /// the app's background-session completion callback.
    var deferredFailureTasks: [UUID: Task<Void, Never>] = [:]
    /// Counts public lifecycle mutations that were admitted before shutdown
    /// closed the latch. Teardown waits for them before sweeping runtime state
    /// and invalidating the session, so an operation suspended in persistence
    /// cannot register a new URL task after shutdown returns.
    private var shutdownTrackedOperationCount = 0
    private var shutdownTrackedOperationWaiters: [CheckedContinuation<Void, Never>] = []

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
    /// identifier must be unique within the process; use
    /// ``make(configuration:)`` when callers want the duplicate-identifier
    /// error surfaced through a factory-style API.
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

    public func setOnProgressHandler(_ callback: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        await runtimeRegistry.setOnProgress(callback)
    }

    public func setOnStateChangedHandler(_ callback: (@Sendable (DownloadTask, DownloadState) async -> Void)?) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        await runtimeRegistry.setOnStateChanged(callback)
        await drainPendingRestoreCompletionsToHandlers()
        await drainPendingRestoreFailuresToHandlers()
    }

    public func setOnCompletedHandler(_ callback: (@Sendable (DownloadTask, URL) async -> Void)?) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        await runtimeRegistry.setOnCompleted(callback)
        await drainPendingRestoreCompletionsToHandlers()
    }

    public func setOnFailedHandler(_ callback: (@Sendable (DownloadTask, DownloadError) async -> Void)?) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        await runtimeRegistry.setOnFailed(callback)
        await drainPendingRestoreFailuresToHandlers()
    }

    /// Waits until launch restoration has reconciled persisted download tasks
    /// with the background URLSession.
    ///
    /// Public download operations call this internally before mutating task
    /// state, but apps that need to coordinate their own startup UI can await
    /// the same barrier explicitly.
    ///
    /// - Returns: `true` when restoration completed, or `false` if the waiting
    ///   task was cancelled.
    public func waitForRestoration() async -> Bool {
        await waitForRestore()
    }

    @discardableResult
    public func download(url: URL, to destinationURL: URL) async -> DownloadTask {
        let task = DownloadTask(url: url, destinationURL: destinationURL)
        guard beginShutdownTrackedOperation() else { return task }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else {
            // Preserve API shape for cancellation-aware callers without mutating manager state.
            return task
        }
        guard admitsDownloadURL(url) else {
            await runtimeRegistry.add(task)
            await failureCoordinator.markTaskFailed(
                task,
                reason: .invalidURL("Rejected by URL admission policy")
            )
            return task
        }
        await runtimeRegistry.add(task)
        await transferCoordinator.startDownload(task, mode: .initial)
        return task
    }

    @discardableResult
    public func download(url: URL, toDirectory directory: URL, fileName: String? = nil) async -> DownloadTask {
        let destinationURL = Self.resolvedDirectoryDownloadDestination(
            sourceURL: url,
            directory: directory,
            fileName: fileName
        )
        guard await waitForRestore() else {
            return DownloadTask(url: url, destinationURL: destinationURL)
        }
        return await download(url: url, to: destinationURL)
    }

    private static func resolvedDirectoryDownloadDestination(
        sourceURL: URL,
        directory: URL,
        fileName: String?
    ) -> URL {
        let rawName = fileName ?? sourceURL.lastPathComponent
        let name = safeDirectoryDownloadFileName(rawName) ?? "download-\(UUID().uuidString)"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    private static func safeDirectoryDownloadFileName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeDirectoryDownloadPathComponent(name) else { return nil }
        guard isSafeDirectoryDownloadPathComponent(name.precomposedStringWithCompatibilityMapping) else { return nil }
        return name
    }

    private static func isSafeDirectoryDownloadPathComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard name.contains("/") == false, name.contains("\\") == false, name.contains(":") == false else {
            return false
        }
        guard name.unicodeScalars.contains(where: { $0.value == 0 }) == false else { return false }
        return true
    }

    public func pause(_ task: DownloadTask) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else { return }
        guard await runtimeRegistry.owns(task) else { return }
        guard pausingTaskIDs.insert(task.id).inserted else { return }
        defer { pausingTaskIDs.remove(task.id) }

        let expectedLifecycle = await task.lifecycleSnapshot()
        guard expectedLifecycle.state == .downloading else { return }
        guard let urlTask = await runtimeRegistry.urlTask(for: task.id) else { return }
        let expectedTaskIdentifier = urlTask.taskIdentifier
        pausingTaskIdentifiers[task.id] = expectedTaskIdentifier
        defer { pausingTaskIdentifiers.removeValue(forKey: task.id) }

        do {
            let markedPausing = try await persistence.transitionResumeState(
                id: task.id,
                fromAny: [.active, .resuming, nil],
                to: .pausing,
                // A retained blob belongs to the preceding attempt and must
                // never be mistaken for resume data produced by this pause.
                resumeData: nil
            )
            guard markedPausing else {
                throw DownloadPersistenceStateError.missingPausingRecord(task.id)
            }
        } catch is CancellationError {
            let persistence = self.persistence
            _ = await Task.detached {
                try? await persistence.transitionResumeState(
                    id: task.id,
                    from: .pausing,
                    to: .active,
                    resumeData: nil
                )
            }.value
            return
        } catch {
            urlTask.cancel()
            _ = await transferCoordinator.markTaskFailedForPersistence(
                task,
                error: error,
                ifMatching: expectedLifecycle
            )
            await runtimeRegistry.removeAttemptRuntime(taskIdentifier: expectedTaskIdentifier)
            return
        }

        guard await task.lifecycleSnapshot() == expectedLifecycle,
            let currentURLTask = await runtimeRegistry.urlTask(for: task.id),
            currentURLTask.taskIdentifier == expectedTaskIdentifier
        else {
            _ = try? await persistence.transitionResumeState(
                id: task.id,
                from: .pausing,
                to: .active,
                resumeData: nil,
            )
            return
        }

        let resumeDataResult = await lifecycleGate.raceOnlyWithShutdown {
            await urlTask.cancelByProducingResumeData()
        }
        guard case .value(let resumeData) = resumeDataResult else { return }

        // Linearize pause against the delegate's synchronous ownership transfer.
        // If didFinishDownloading already owns or established a deterministic
        // journal, completion wins and the still-registered task consumes the
        // queued journal event. Otherwise this closes the retired concrete
        // attempt before its mapping and resume state are finalized.
        guard await claimDestructiveLifecycle(taskID: task.id) else { return }
        await task.endRestoredSuccessAdmission()

        guard await task.lifecycleSnapshot() == expectedLifecycle,
            let currentURLTask = await runtimeRegistry.urlTask(for: task.id),
            currentURLTask.taskIdentifier == expectedTaskIdentifier
        else {
            // The physical attempt has already been cancelled. Keeping the
            // durable `.pausing` marker is the crash-safe outcome: restoration
            // reconstructs a paused handle and restarts from the admitted URL.
            return
        }

        // The attempt is cancelled regardless of when URLSession delivers its
        // cancellation delegate event. Retire only this identifier: actor
        // reentrancy may already have allowed a newer runtime to register.
        await runtimeRegistry.removeAttemptRuntime(taskIdentifier: expectedTaskIdentifier)

        do {
            let persistence = self.persistence
            let markedPaused = try await Task.detached {
                try await persistence.transitionResumeState(
                    id: task.id,
                    from: .pausing,
                    to: .paused,
                    resumeData: resumeData,
                )
            }.value
            guard markedPaused else {
                throw DownloadPersistenceStateError.missingPausingRecord(task.id)
            }
        } catch {
            await transferCoordinator.markTaskFailedForPersistence(task, error: error)
            return
        }

        guard await task.transitionToPaused(resumeData: resumeData, ifMatching: expectedLifecycle) else {
            // Do not rewrite `.paused` to `.active`: there is no longer a live
            // URLSession task. A terminal winner normally removes the record;
            // if cleanup fails, leaving the recoverable pause is safer than an
            // active record with no system attempt.
            return
        }

        let pausedLifecycle = await task.lifecycleSnapshot()
        await eventHub.publishIfCurrent(.stateChanged(.paused), for: task.id) {
            await task.lifecycleSnapshot() == pausedLifecycle
        }
        await callbackDeliveryQueue.enqueueStateChanged(task, .paused)
    }

    public func resume(_ task: DownloadTask) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else { return }
        guard await runtimeRegistry.owns(task) else { return }
        guard resumingTaskIDs.insert(task.id).inserted else { return }
        defer { resumingTaskIDs.remove(task.id) }
        let pausedLifecycle = await task.lifecycleSnapshot()
        guard pausedLifecycle.state == .paused else { return }
        guard await claimDestructiveLifecycle(taskID: task.id) else { return }
        await task.endRestoredSuccessAdmission()
        guard admitsDownloadURL(task.url) else {
            await failureCoordinator.markTaskFailed(
                task,
                reason: .invalidURL("Rejected by URL admission policy")
            )
            return
        }
        do {
            try DownloadDestinationPreflight.validate(task.destinationURL)
        } catch {
            await transferCoordinator.markTaskFailedForPersistence(
                task,
                error: error,
                ifMatching: pausedLifecycle
            )
            return
        }

        // A paused logical task must never retain a concrete attempt. Clean up
        // any legacy/restoration drift before creating a replacement so late
        // callbacks from that attempt cannot race the resumed generation.
        if let staleURLTask = await runtimeRegistry.urlTask(for: task.id) {
            staleURLTask.cancel()
            await runtimeRegistry.removeAttemptRuntime(taskIdentifier: staleURLTask.taskIdentifier)
        }

        let retainedResumeData = await task.resumeData
        guard await task.lifecycleSnapshot() == pausedLifecycle else { return }
        do {
            let markedResuming = try await persistence.transitionResumeState(
                id: task.id,
                fromAny: [.paused, .pausing, .resuming, nil],
                to: .resuming,
                resumeData: retainedResumeData,
            )
            guard markedResuming else {
                throw DownloadPersistenceStateError.missingResumingRecord(task.id)
            }
            guard let record = await persistence.record(forID: task.id),
                record.lifecycle == .resuming,
                record.resumeData == retainedResumeData
            else {
                throw DownloadPersistenceStateError.missingResumingRecord(task.id)
            }
        } catch is CancellationError {
            let persistence = self.persistence
            _ = await Task.detached {
                try? await persistence.transitionResumeState(
                    id: task.id,
                    from: .resuming,
                    to: .paused,
                    resumeData: retainedResumeData
                )
            }.value
            return
        } catch {
            await transferCoordinator.markTaskFailedForPersistence(task, error: error)
            return
        }
        guard await task.lifecycleSnapshot() == pausedLifecycle else { return }
        if let resumeData = retainedResumeData {
            let urlTask = session.makeDownloadTask(withResumeData: resumeData)
            guard admitsResumedURLTask(urlTask, expectedURL: task.url) else {
                // Resume data is opaque and can carry a different request
                // than the persisted logical task. Never start or register an
                // untrusted task; discard the blob and restart from the URL
                // that already passed admission.
                urlTask.cancel()
                await task.setResumeData(nil)
                do {
                    let discardedOpaqueData = try await persistence.transitionResumeState(
                        id: task.id,
                        from: .resuming,
                        to: .resuming,
                        resumeData: nil,
                    )
                    guard discardedOpaqueData else {
                        throw DownloadPersistenceStateError.missingResumingRecord(task.id)
                    }
                } catch is CancellationError {
                    await task.setResumeData(retainedResumeData)
                    let persistence = self.persistence
                    _ = await Task.detached {
                        try? await persistence.transitionResumeState(
                            id: task.id,
                            from: .resuming,
                            to: .paused,
                            resumeData: retainedResumeData
                        )
                    }.value
                    return
                } catch {
                    await transferCoordinator.markTaskFailedForPersistence(task, error: error)
                    return
                }
                guard await task.lifecycleSnapshot() == pausedLifecycle else { return }
                guard await task.advanceAttempt(ifMatching: pausedLifecycle) != nil else {
                    return
                }
                await transferCoordinator.startDownload(
                    task,
                    mode: .resumingPersistedPause
                )
                return
            }
            guard
                let downloadingLifecycle = await task.startNextAttempt(
                    transitioningTo: .downloading,
                    ifMatching: pausedLifecycle
                )
            else {
                urlTask.cancel()
                return
            }
            await transferCoordinator.register(urlTask: urlTask, for: task)
            guard await task.lifecycleSnapshot() == downloadingLifecycle else {
                urlTask.cancel()
                await runtimeRegistry.removeAttemptRuntime(taskIdentifier: urlTask.taskIdentifier)
                return
            }
            await eventHub.publishIfCurrent(.stateChanged(.downloading), for: task.id) {
                await task.lifecycleSnapshot() == downloadingLifecycle
            }
            guard await task.lifecycleSnapshot() == downloadingLifecycle else {
                urlTask.cancel()
                await runtimeRegistry.removeAttemptRuntime(taskIdentifier: urlTask.taskIdentifier)
                return
            }
            await callbackDeliveryQueue.enqueueStateChangedAndWait(task, .downloading)
            guard
                await task.resume(
                    urlTask,
                    ifMatching: downloadingLifecycle,
                    lifecycleGate: lifecycleGate
                )
            else {
                urlTask.cancel()
                await runtimeRegistry.removeAttemptRuntime(taskIdentifier: urlTask.taskIdentifier)
                return
            }
            do {
                let persistence = self.persistence
                let finalizedResume = try await Task.detached {
                    try await persistence.transitionResumeState(
                        id: task.id,
                        from: .resuming,
                        to: .active,
                        resumeData: nil
                    )
                }.value
                if !finalizedResume {
                    let record = await persistence.record(forID: task.id)
                    let currentState = await task.state
                    if record?.lifecycle == .pausing || record?.lifecycle == .paused
                        || currentState.isTerminal
                    {
                        // A concurrent pause/cancel owns the concrete attempt
                        // and its durable phase. Never clobber it back to active.
                        return
                    }
                    throw DownloadPersistenceStateError.failedToFinalizeResumingRecord(task.id)
                }
            } catch {
                Self.logger.fault(
                    "Failed to finalize active persistence for task \(task.id, privacy: .private(mask: .hash)) on resume: \(String(describing: error), privacy: .private(mask: .hash))"
                )
                urlTask.cancel()
                await runtimeRegistry.removeAttemptRuntime(taskIdentifier: urlTask.taskIdentifier)
                await transferCoordinator.markTaskFailedForPersistence(task, error: error)
                return
            }
            await task.setResumeData(nil)
        } else {
            guard await task.advanceAttempt(ifMatching: pausedLifecycle) != nil else { return }
            await transferCoordinator.startDownload(
                task,
                mode: .resumingPersistedPause
            )
        }
    }

    public func cancel(_ task: DownloadTask) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else { return }
        guard await runtimeRegistry.owns(task) else { return }
        await task.waitForFailureFinalization()
        guard await claimDestructiveLifecycle(taskID: task.id) else { return }
        await task.endRestoredSuccessAdmission()
        provisionalBackgroundRestoreFailureIDs.remove(task.id)
        pendingRestoreFailures.remove(task.id)
        // Drive the state transition only when we're leaving a non-terminal
        // state. Calling `cancel` again on an already-terminal task (for
        // example, after the first attempt's persistence removal failed)
        // continues into the cleanup path below so callers can drain the
        // registry without triggering an illegal-transition assertion.
        let transition = await task.requestCancellationClaimingPersistenceCleanup()
        guard transition != .busy else { return }
        let didTransition = transition == .transitioned
        await task.waitForStartPersistenceClaimRelease()
        do {
            try await persistence.markTerminal(task: task)
        } catch {
            Self.logger.fault(
                "Failed to persist cancellation tombstone for task \(task.id, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
        if didTransition {
            await eventHub.publishTerminalAndFinish(
                .stateChanged(.cancelled),
                for: task.id
            )

            if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
                urlTask.cancel()
            }
        }
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)

        do {
            try await persistence.remove(id: task.id)
        } catch {
            Self.logger.fault(
                "Failed to remove cancelled task \(task.id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            if didTransition {
                await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
            }
            await task.releaseTerminalPersistenceCleanupClaim()
            return
        }
        await runtimeRegistry.remove(task)
        if didTransition {
            await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
        }
        await task.releaseTerminalPersistenceCleanupClaim()
    }

    public func cancelAll() async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        guard await waitForRestore() else { return }
        let allTasks = await runtimeRegistry.allTasks()
        var tasks: [DownloadTask] = []
        tasks.reserveCapacity(allTasks.count)
        for task in allTasks {
            if await claimDestructiveLifecycle(taskID: task.id) {
                tasks.append(task)
            }
        }
        guard !tasks.isEmpty else { return }
        for task in tasks {
            await task.waitForFailureFinalization()
        }
        pendingRestoreFailures.subtract(tasks.map(\.id))
        provisionalBackgroundRestoreFailureIDs.subtract(tasks.map(\.id))
        for task in tasks {
            await task.endRestoredSuccessAdmission()
        }

        // Phase 1: drive every state transition + URL-task cancel up front,
        // before touching persistence. Each task's state snapshot/transition
        // is an independent actor exchange, so a TaskGroup lets the runtime
        // dispatcher hand them out in any order; the per-task work itself
        // still serializes inside `DownloadTask` and `runtimeRegistry`.
        //
        // Only tasks we actually transitioned receive `.cancelled` events and
        // callbacks. Already-terminal tasks are still included in persistence
        // cleanup so a second `cancelAll()` can recover from an earlier bulk
        // remove failure without reporting a spurious state change.
        var transitionedIDs: Set<String> = []
        var removableIDs: Set<String> = []
        transitionedIDs.reserveCapacity(tasks.count)
        removableIDs.reserveCapacity(tasks.count)

        await withTaskGroup(of: (String, DownloadTerminalTransitionResult).self) { group in
            for task in tasks {
                group.addTask {
                    let result = await task.requestCancellationClaimingPersistenceCleanup()
                    return (task.id, result)
                }
            }
            for await (id, result) in group {
                switch result {
                case .transitioned:
                    transitionedIDs.insert(id)
                    removableIDs.insert(id)
                case .alreadyTerminal:
                    removableIDs.insert(id)
                case .busy:
                    break
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for task in tasks where removableIDs.contains(task.id) {
                group.addTask {
                    await task.waitForStartPersistenceClaimRelease()
                }
            }
        }

        do {
            try await persistence.markTerminal(tasks: tasks, ids: removableIDs)
        } catch {
            Self.logger.fault(
                "cancelAll terminal-marker write failed for \(removableIDs.count, privacy: .public) ids: \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }

        for task in tasks where transitionedIDs.contains(task.id) {
            await eventHub.publishTerminalAndFinish(
                .stateChanged(.cancelled),
                for: task.id
            )
            if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
                urlTask.cancel()
            }
        }
        for task in tasks where removableIDs.contains(task.id) {
            await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        }

        // Phase 2: a single bulk persistence remove takes the directory
        // lock once and emits one fsync regardless of `tasks.count`. The
        // pre-fix loop paid O(N) lock acquisitions and could spend seconds
        // on a 100-task cancel storm.
        do {
            try await persistence.remove(ids: removableIDs)
        } catch {
            Self.logger.fault(
                "cancelAll persistence bulk-remove failed for \(removableIDs.count, privacy: .public) ids: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            for task in tasks where transitionedIDs.contains(task.id) {
                await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
            }
            for task in tasks where removableIDs.contains(task.id) {
                await task.releaseTerminalPersistenceCleanupClaim()
            }
            return
        }

        for task in tasks where removableIDs.contains(task.id) {
            await runtimeRegistry.remove(task)
            if transitionedIDs.contains(task.id) {
                await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
            }
            await task.releaseTerminalPersistenceCleanupClaim()
        }
    }

    /// Tears down the manager: cancels every in-flight transfer, finishes
    /// outstanding event streams, and invalidates the underlying URLSession.
    ///
    /// `shutdown()` is the supported lifecycle exit point. It releases the
    /// background session identifier, drops the URLSession's strong reference
    /// to its delegate, and stops the delegate-event consumer task. After
    /// `shutdown()` returns, treat the manager as terminal and create a fresh
    /// instance for new transfer work; diagnostic getters may still reflect
    /// last-known in-memory task state. A fresh manager can claim the same
    /// `sessionIdentifier`. Calling `shutdown()` multiple times is safe.
    /// A call made from one of this manager's async callbacks starts teardown
    /// and returns so the callback can unwind instead of waiting on its own
    /// restoration or delegate worker. A later external call still waits for
    /// the complete shutdown boundary.
    ///
    /// In tests and apps that own the manager instance directly, prefer
    /// `shutdown()` over relying on `deinit` — Foundation will hold the
    /// session (and thus the manager and its closures) alive until invalidate
    /// completes, which can take longer than the surrounding scope.
    public func shutdown() async {
        let callbackToken = DownloadUserCallbackContext.token
        let isReentrantCallback =
            callbackToken?.containsActiveCallback(
                for: runtimeRegistry.callbackContextID
            ) == true

        if markShutdownIfNeeded() {
            // Teardown must never run on the restoration/delegate worker that
            // may currently be invoking the callback above. A dedicated task
            // owns all joins; TaskLocal callback ancestry is inherited so
            // nested callbacks retain correct reentrancy classification.
            Task { [self] in
                await performShutdown()
            }
        }

        guard !isReentrantCallback else { return }
        await shutdownBarrier.wait()
    }

    private func performShutdown() async {
        let inactivityWatchdogTask = inactivityWatchdogTask
        inactivityWatchdogTask?.cancel()
        self.inactivityWatchdogTask = nil

        let delegateConsumerTask = delegateConsumerTaskHandle.withLock { task -> Task<Void, Never>? in
            let current = task
            task = nil
            return current
        }

        let restorationTask = restorationTaskHandle.withLock { task -> Task<Void, Never>? in
            let current = task
            task = nil
            return current
        }
        restorationTask?.cancel()
        // Restoration owns URL-task adoption and persistence reconciliation.
        // Drain it before removing runtime mappings or invalidating the
        // session so a late restore continuation cannot repopulate a terminal
        // manager.
        await restorationTask?.value

        delegateEventChannel.finish()
        // Cancel an in-progress retry wait immediately. The consumer keeps
        // draining the already-accepted channel after cancellation; legacy
        // temporary files are removed while deterministic production journals
        // remain available to the next manager's restoration pass.
        delegateConsumerTask?.cancel()
        // Completion locations already accepted into the channel are
        // library-owned staging files. The cancelled consumer still drains
        // them through its explicit preservation/cleanup branch.
        // Let every lifecycle mutation admitted before shutdown finish before
        // the final task snapshot. This closes the persistence-suspension race
        // where `startDownload` could otherwise register a URL task after the
        // session had already been invalidated.
        await waitForShutdownTrackedOperationsToDrain()
        await inactivityWatchdogTask?.value

        // Seal every durable row before invalidating the session. If the
        // process is killed between URLSession cancellation and the later
        // cleanup sweep, a fresh manager must observe terminal tombstones,
        // not runnable active/retry/pause records.
        let preInvalidationRecords = await persistence.allRecords()
        let preInvalidationProtectedTaskIDs = await commitRecoveryProtectedTaskIDs(
            in: preInvalidationRecords
        )
        let preInvalidationTaskIDs = Set(preInvalidationRecords.map(\.id))
            .subtracting(preInvalidationProtectedTaskIDs)
        do {
            try await persistence.markTerminal(ids: preInvalidationTaskIDs)
        } catch {
            Self.logger.fault(
                "shutdown pre-invalidation terminal-marker write failed for \(preInvalidationTaskIDs.count, privacy: .public) ids: \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }

        // No admitted public mutation can create another task past this
        // point. Invalidate promptly so Foundation releases pending receives
        // even when an already-admitted delegate callback is waiting for user
        // code; shutdown still awaits that consumer below.
        session.invalidateAndCancel()

        // Drain all delegate events accepted before `finish()`. Completion
        // locations are library-owned staging files, and the consumer either
        // commits them or deletes them before the terminal sweep begins.
        await delegateConsumerTask?.value
        await drainDeferredFailureTasks()

        // Cancel every in-flight URLSession task before invalidating, then
        // close the per-task event partition so listeners receive a clean
        // end-of-stream signal instead of hanging indefinitely. We do not
        // await the URLSession-level cancellation (it's fire-and-forget by
        // contract); `invalidateAndCancel()` below drains the rest.
        let tasks = await runtimeRegistry.allTasks()
        // Include runtime-only tasks and any row discovered while the
        // pre-invalidation seal was being written. Terminal is absorbing in
        // persistence, so this second pass cannot be undone by a stale retry.
        let persistedRecords = await persistence.allRecords()
        let protectedTaskIDs = preInvalidationProtectedTaskIDs.union(
            await commitRecoveryProtectedTaskIDs(
                in: persistedRecords,
                additionalTaskIDs: Set(tasks.map(\.id))
            )
        )
        let persistedTaskIDs = Set(persistedRecords.map(\.id))
        let shutdownTaskIDs = persistedTaskIDs.union(tasks.map(\.id))
            .subtracting(protectedTaskIDs)
        do {
            try await persistence.markTerminal(ids: shutdownTaskIDs)
        } catch {
            Self.logger.fault(
                "shutdown terminal-marker write failed for \(shutdownTaskIDs.count, privacy: .public) ids: \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }

        var cancelledTasks: [DownloadTask] = []
        for task in tasks {
            if protectedTaskIDs.contains(task.id) {
                if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
                    urlTask.cancel()
                }
                await eventHub.finish(taskID: task.id)
                await runtimeRegistry.removeTaskRuntime(taskId: task.id)
                continue
            }
            let transition = await task.transitionToTerminal(.cancelled, error: .cancelled)
            if transition == .transitioned {
                await eventHub.publishTerminalAndFinish(
                    .stateChanged(.cancelled),
                    for: task.id
                )
                cancelledTasks.append(task)
            }
            if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
                urlTask.cancel()
            }
            await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        }

        // Sweep the sealed persistence snapshot as well as live task IDs.
        do {
            try await persistence.remove(ids: shutdownTaskIDs)
        } catch {
            Self.logger.fault(
                "shutdown persistence bulk-remove failed for \(shutdownTaskIDs.count, privacy: .public) ids: \(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
        for task in tasks {
            await runtimeRegistry.remove(task)
        }

        // Invoke manager callbacks only after terminal events are admitted and
        // partitions are sealed. Reentrant shutdown now returns immediately,
        // while external shutdown callers retain the strong callback-drain
        // boundary established by the final barrier below.
        for task in cancelledTasks {
            await callbackDeliveryQueue.enqueueStateChanged(task, .cancelled)
        }

        // `invalidateAndCancel()` (not `finishTasksAndInvalidate()`) above is
        // the correct lifecycle boundary: pending transfers die immediately
        // and the OS releases the session identifier and delegate.
        await invalidationBarrier.wait()
        // App callbacks never hold the delegate FIFO or Foundation's
        // background-events completion. They remain part of the strong
        // external shutdown contract, however: stop callback admission only
        // after every lifecycle producer and the session have drained, then
        // wait for all callbacks accepted before that boundary.
        await callbackDeliveryQueue.finishAndDrain()
        Self.unregisterSessionIdentifier(configuration.sessionIdentifier)
        await shutdownBarrier.complete()
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

    private func claimDestructiveLifecycle(taskID: String) async -> Bool {
        guard await completionAdmissionGate.claimDestructiveLifecycle(taskID: taskID) else {
            return false
        }
        guard !(await isCommitRecoveryProtected(taskID: taskID)) else {
            return false
        }
        return true
    }

    private func commitRecoveryProtectedTaskIDs(
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

    private func admitsResumedURLTask(
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

    public func task(withId id: String) async -> DownloadTask? {
        guard await waitForRestore() else { return nil }
        return await runtimeRegistry.task(withId: id)
    }

    public func allTasks() async -> [DownloadTask] {
        guard await waitForRestore() else { return [] }
        return await runtimeRegistry.allTasks()
    }

    public func activeTasks() async -> [DownloadTask] {
        guard await waitForRestore() else { return [] }
        var result: [DownloadTask] = []
        for task in await runtimeRegistry.allTasks() {
            let state = await task.state
            if state == .downloading || state == .waiting {
                result.append(task)
            }
        }
        return result
    }

    func runtimeTaskIdentifier(for task: DownloadTask) async -> Int? {
        await runtimeRegistry.taskIdentifier(for: task.id)
    }

    func cancelRuntimeURLTask(for task: DownloadTask) async {
        if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
            urlTask.cancel()
        }
    }

    func listenerCount(for task: DownloadTask) async -> Int {
        await eventHub.listenerCount(taskID: task.id)
    }

    public func addEventListener(
        for task: DownloadTask,
        listener: @escaping @Sendable (DownloadEvent) async -> Void
    ) async -> DownloadEventSubscription {
        guard await runtimeRegistry.owns(task) else {
            return DownloadEventSubscription(taskId: "", listenerID: UUID())
        }
        let listenerID = await eventHub.addListener(taskID: task.id, listener: listener)
        if !provisionalBackgroundRestoreFailureIDs.contains(task.id),
            let terminal = await task.terminalEvent()
        {
            await eventHub.publishTerminalAndFinish(terminal, for: task.id)
            await acknowledgeRestoredCompletionIfNeeded(taskID: task.id)
        }
        return DownloadEventSubscription(taskId: task.id, listenerID: listenerID)
    }

    public func removeEventListener(_ subscription: DownloadEventSubscription) async {
        await eventHub.removeListener(taskID: subscription.taskId, listenerID: subscription.listenerID)
    }

    public func events(for task: DownloadTask) async -> AsyncStream<DownloadEvent> {
        guard await runtimeRegistry.owns(task) else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        let stream = await eventHub.stream(for: task.id)
        await flushPendingRestoreFailureIfNeeded(taskID: task.id)
        if !provisionalBackgroundRestoreFailureIDs.contains(task.id),
            let terminal = await task.terminalEvent()
        {
            await eventHub.publishTerminalAndFinish(terminal, for: task.id)
            await acknowledgeRestoredCompletionIfNeeded(taskID: task.id)
        }
        return stream
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

    private static func unregisterSessionIdentifier(_ identifier: String) {
        _ = activeSessionIdentifiers.withLock { identifiers in
            identifiers.remove(identifier)
        }
    }

    nonisolated var isShutdown: Bool {
        lifecycleGate.isShutdown
    }

    func beginShutdownTrackedOperation() -> Bool {
        guard !isShutdown else { return false }
        shutdownTrackedOperationCount += 1
        return true
    }

    func finishShutdownTrackedOperation() {
        precondition(shutdownTrackedOperationCount > 0)
        shutdownTrackedOperationCount -= 1
        guard shutdownTrackedOperationCount == 0 else { return }
        let waiters = shutdownTrackedOperationWaiters
        shutdownTrackedOperationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForShutdownTrackedOperationsToDrain() async {
        guard shutdownTrackedOperationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            if shutdownTrackedOperationCount == 0 {
                continuation.resume()
            } else {
                shutdownTrackedOperationWaiters.append(continuation)
            }
        }
    }

    /// Atomically flips the shutdown latch. Returns `true` when this call
    /// is the one that observed the latch transitioning from `false` to
    /// `true`; returns `false` if another caller (or this one re-entering)
    /// had already shut the manager down. Callers that get `false` must
    /// await ``invalidationBarrier`` instead of running the teardown path
    /// a second time.
    nonisolated private func markShutdownIfNeeded() -> Bool {
        lifecycleGate.beginShutdown()
    }
}


/// Lock-backed lifecycle admission shared with transport coordinators.
///
/// The final check and `resume()` are performed under the same lock used by
/// shutdown admission. A task therefore resumes-before-shutdown (and is swept)
/// or is cancelled without ever resuming; it cannot start after the latch has
/// closed.
package enum DownloadLifecycleRaceResult<Value: Sendable>: Sendable {
    case value(Value)
    case shutdown
}


package final class DownloadLifecycleGate: Sendable {
    private struct State: Sendable {
        var isShutdown = false
        var shutdownHandlers: [UUID: @Sendable () -> Void] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isShutdown: Bool {
        state.withLock { $0.isShutdown }
    }

    func beginShutdown() -> Bool {
        let result = state.withLock { state -> (Bool, [@Sendable () -> Void]) in
            guard !state.isShutdown else { return (false, []) }
            state.isShutdown = true
            let handlers = Array(state.shutdownHandlers.values)
            state.shutdownHandlers.removeAll(keepingCapacity: false)
            return (true, handlers)
        }
        for handler in result.1 {
            handler()
        }
        return result.0
    }

    func resumeIfOpen(_ task: any DownloadURLTask) -> Bool {
        state.withLock { state in
            guard !state.isShutdown else { return false }
            task.resume()
            return true
        }
    }

    package func raceWithShutdown<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> DownloadLifecycleRaceResult<Value> {
        let gate = DownloadLifecycleRaceGate<Value>()
        guard
            let handlerID = registerShutdownHandler({
                gate.complete(.shutdown)
            })
        else {
            return .shutdown
        }

        let operationTask = Task {
            let value = await operation()
            gate.complete(.value(value))
        }
        let result = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            gate.complete(.shutdown)
        }

        removeShutdownHandler(handlerID)
        if case .shutdown = result {
            operationTask.cancel()
        }
        return result
    }

    /// Once an operation has initiated an irreversible transport transition,
    /// caller cancellation must not abandon its durable reconciliation. This
    /// variant still exits promptly for manager shutdown, but shields the
    /// operation from cancellation of the public API caller.
    package func raceOnlyWithShutdown<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> DownloadLifecycleRaceResult<Value> {
        let gate = DownloadLifecycleRaceGate<Value>()
        guard
            let handlerID = registerShutdownHandler({
                gate.complete(.shutdown)
            })
        else {
            return .shutdown
        }

        let operationTask = Task {
            let value = await operation()
            gate.complete(.value(value))
        }
        let result = await gate.wait()

        removeShutdownHandler(handlerID)
        if case .shutdown = result {
            operationTask.cancel()
        }
        return result
    }

    private func registerShutdownHandler(
        _ handler: @escaping @Sendable () -> Void
    ) -> UUID? {
        let id = UUID()
        let registered = state.withLock { state in
            guard !state.isShutdown else { return false }
            state.shutdownHandlers[id] = handler
            return true
        }
        guard registered else {
            handler()
            return nil
        }
        return id
    }

    private func removeShutdownHandler(_ id: UUID) {
        state.withLock { state in
            _ = state.shutdownHandlers.removeValue(forKey: id)
        }
    }
}


private final class DownloadLifecycleRaceGate<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<DownloadLifecycleRaceResult<Value>, Never>?
        var result: DownloadLifecycleRaceResult<Value>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async -> DownloadLifecycleRaceResult<Value> {
        await withCheckedContinuation { continuation in
            let immediateResult = state.withLock { state -> DownloadLifecycleRaceResult<Value>? in
                if let result = state.result {
                    return result
                }
                state.continuation = continuation
                return nil
            }
            if let immediateResult {
                continuation.resume(returning: immediateResult)
            }
        }
    }

    func complete(_ result: DownloadLifecycleRaceResult<Value>) {
        let continuation = state.withLock {
            state -> CheckedContinuation<DownloadLifecycleRaceResult<Value>, Never>? in
            guard case .none = state.result else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

actor RestoreBarrier {
    private var isCompleted = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        guard !isCompleted else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if isCompleted {
                    continuation.resume(returning: ())
                    return
                }
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { [weak self] in
                guard let self else { return }
                await self.cancelWaiter(waiterID)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
    }

    func complete() {
        guard !isCompleted else { return }
        isCompleted = true
        for waiter in waiters.values {
            waiter.resume(returning: ())
        }
        waiters.removeAll(keepingCapacity: false)
    }
}


private actor InvalidationBarrier {
    private var isCompleted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isCompleted else { return }
        await withCheckedContinuation { continuation in
            if isCompleted {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func complete() {
        guard !isCompleted else { return }
        isCompleted = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll(keepingCapacity: false)
    }
}
