import Foundation
import InnoNetwork
import OSLog
import os

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
/// actor's isolation, plus three actor-typed collaborators:
///
/// 1. **`DownloadRuntimeRegistry`** — actor that owns the live mapping
///    between `DownloadTask`, `URLSessionDownloadTask`, and runtime
///    callbacks.
/// 2. **`DownloadTaskPersistence`** — actor that owns the on-disk task log.
/// 3. **`BackgroundCompletionStore`** — actor that holds the system-supplied
///    background completion handler.
///
/// Foundation-driven delegate callbacks (URL session's serial queue) cross
/// into the actor through a single delegate-event stream. The synchronous
/// callbacks only enqueue immutable events, and one consumer task drains them
/// into the actor so progress/completion ordering follows delegate order.
///
/// `handleBackgroundSessionCompletion(_:completion:)` is `nonisolated` so
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
/// (a synchronous Foundation entry point) can call it without `await`.
public actor DownloadManager {
    private static let logger = Logger(subsystem: "innosquad.network.download", category: "DownloadManager")

    /// Recommended throwing factory for constructing a `DownloadManager`.
    ///
    /// Equivalent to ``init(configuration:)``, but discoverable via type-level
    /// autocomplete and consistent with the `make(...)` style used elsewhere
    /// in the package (e.g., `URLQueryEncoder`, observability builders). Use
    /// this when you need explicit failure handling instead of relying on
    /// ``shared``'s fallback behavior.
    ///
    /// - Parameter configuration: The configuration to bind. Pass
    ///   ``DownloadConfiguration/safeDefaults(sessionIdentifier:)`` with a
    ///   unique identifier when multiple managers must coexist in the same
    ///   process.
    /// - Returns: A new `DownloadManager` ready to receive download requests.
    /// - Throws: ``DownloadManagerError/duplicateSessionIdentifier(_:)`` if
    ///   another manager has already claimed the same session identifier.
    public static func make(
        configuration: DownloadConfiguration = .default
    ) throws -> DownloadManager {
        try DownloadManager(configuration: configuration)
    }

    private static let activeSessionIdentifiers = OSAllocatedUnfairLock(initialState: Set<String>())

    private let configuration: DownloadConfiguration
    private let session: any DownloadURLSession
    private let delegate: DownloadSessionDelegate
    private let backgroundCompletionStore: BackgroundCompletionStore
    private let persistence: DownloadTaskPersistence

    private let runtimeRegistry = DownloadRuntimeRegistry()
    private let restoreBarrier = RestoreBarrier()
    private var pendingRestoreFailures: Set<String> = []
    private var isShutdown = false
    private let eventHub: TaskEventHub<DownloadEvent>
    private let delegateEvents: AsyncStream<DelegateEvent>
    private let delegateEventContinuation: AsyncStream<DelegateEvent>.Continuation

    private enum DelegateEvent: Sendable {
        case progress(
            taskIdentifier: Int,
            bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        )
        case completion(
            taskIdentifier: Int,
            location: URL?,
            error: SendableUnderlyingError?
        )
    }

    private var transferCoordinator: DownloadTransferCoordinator {
        DownloadTransferCoordinator(
            session: session,
            runtimeRegistry: runtimeRegistry,
            persistence: persistence,
            eventHub: eventHub
        )
    }

    private var restoreCoordinator: DownloadRestoreCoordinator {
        DownloadRestoreCoordinator(
            configuration: configuration,
            session: session,
            runtimeRegistry: runtimeRegistry,
            persistence: persistence,
            transferCoordinator: transferCoordinator
        )
    }

    private var failureCoordinator: DownloadFailureCoordinator {
        DownloadFailureCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry,
            persistence: persistence,
            eventHub: eventHub
        )
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
    ///   another live manager has already claimed the same session identifier.
    public init(configuration: DownloadConfiguration = .default) throws {
        try self.init(
            configuration: configuration,
            persistence: DownloadTaskPersistence(
                sessionIdentifier: configuration.sessionIdentifier,
                baseDirectoryURL: configuration.persistenceBaseDirectoryURL,
                fsyncPolicy: configuration.persistenceFsyncPolicy,
                compactionPolicy: configuration.persistenceCompactionPolicy
            )
        )
    }

    package init(
        configuration: DownloadConfiguration = .default,
        persistence: DownloadTaskPersistence
    ) throws {
        let callbacks = DownloadSessionDelegateCallbacks()
        let backgroundCompletionStore = BackgroundCompletionStore()
        let delegate = DownloadSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore
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
            backgroundCompletionStore: backgroundCompletionStore
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
        backgroundCompletionStore: BackgroundCompletionStore
    ) throws {
        // Delegate events drive task lifecycle (suspend/resume/finish); dropping
        // any of them would leave the actor wedged in an intermediate state,
        // so this stream is intentionally `.unbounded`. The producer is the
        // URLSession delegate, which yields a bounded number of events per
        // task, so buffer growth is naturally bounded by the active task set.
        let (delegateEvents, delegateEventContinuation) = AsyncStream<DelegateEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        try Self.registerSessionIdentifier(configuration.sessionIdentifier)
        callbacks.setInvalidationHandler { [identifier = configuration.sessionIdentifier] _ in
            Self.unregisterSessionIdentifier(identifier)
        }
        self.configuration = configuration
        self.delegate = delegate
        self.backgroundCompletionStore = backgroundCompletionStore
        self.persistence = persistence
        self.eventHub = TaskEventHub(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .downloadTask
        )
        self.session = urlSession
        self.delegateEvents = delegateEvents
        self.delegateEventContinuation = delegateEventContinuation

        // Delegate boundary: URL session's serial delegate queue invokes the
        // closures below synchronously. They enqueue value events into one
        // stream, and the single consumer task below awaits actor-isolated
        // handling in FIFO order.
        callbacks.setHandlers(
            onProgress: {
                [delegateEventContinuation] taskIdentifier, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite
                in
                delegateEventContinuation.yield(
                    .progress(
                        taskIdentifier: taskIdentifier,
                        bytesWritten: bytesWritten,
                        totalBytesWritten: totalBytesWritten,
                        totalBytesExpectedToWrite: totalBytesExpectedToWrite
                    ))
            },
            onCompletion: { [delegateEventContinuation] taskIdentifier, location, error in
                delegateEventContinuation.yield(
                    .completion(
                        taskIdentifier: taskIdentifier,
                        location: location,
                        error: error
                    ))
            }
        )
        Task { [weak self, delegateEvents] in
            for await event in delegateEvents {
                if Task.isCancelled { break }
                await self?.handleDelegateEvent(event)
            }
        }

        // Restoration runs on a detached Task so the actor init returns
        // immediately. waitForRestore() gates every public entry point on the
        // restoreBarrier, so callers that issue downloads before restoration
        // completes block until the barrier opens.
        Task { [weak self] in
            guard let self else { return }
            let pending = await self.restoreCoordinator.restorePendingDownloads()
            await self.recordPendingRestoreFailures(pending)
            await self.restoreBarrier.complete()
        }
    }

    public func setOnProgressHandler(_ callback: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?) async {
        await runtimeRegistry.setOnProgress(callback)
    }

    public func setOnStateChangedHandler(_ callback: (@Sendable (DownloadTask, DownloadState) async -> Void)?) async {
        await runtimeRegistry.setOnStateChanged(callback)
        await drainPendingRestoreFailuresToHandlers()
    }

    public func setOnCompletedHandler(_ callback: (@Sendable (DownloadTask, URL) async -> Void)?) async {
        await runtimeRegistry.setOnCompleted(callback)
    }

    public func setOnFailedHandler(_ callback: (@Sendable (DownloadTask, DownloadError) async -> Void)?) async {
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
        guard await waitForRestore() else {
            // Preserve API shape for cancellation-aware callers without mutating manager state.
            return DownloadTask(url: url, destinationURL: destinationURL)
        }
        let task = DownloadTask(url: url, destinationURL: destinationURL)
        await runtimeRegistry.add(task)
        await transferCoordinator.startDownload(task)
        return task
    }

    @discardableResult
    public func download(url: URL, toDirectory directory: URL, fileName: String? = nil) async -> DownloadTask {
        guard await waitForRestore() else {
            let name = fileName ?? url.lastPathComponent
            let destinationURL = directory.appendingPathComponent(name)
            return DownloadTask(url: url, destinationURL: destinationURL)
        }
        let name = fileName ?? url.lastPathComponent
        let destinationURL = directory.appendingPathComponent(name)
        return await download(url: url, to: destinationURL)
    }

    public func pause(_ task: DownloadTask) async {
        guard await waitForRestore() else { return }
        guard await task.state == .downloading else { return }

        if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
            let resumeData = await urlTask.cancelByProducingResumeData()
            do {
                try await persistence.updateResumeData(id: task.id, resumeData: resumeData)
            } catch {
                await transferCoordinator.markTaskFailedForPersistence(task, error: error)
                return
            }
            await task.setResumeData(resumeData)
            await task.updateState(.paused)
            await runtimeRegistry.onStateChanged?(task, .paused)
            await eventHub.publish(.stateChanged(.paused), for: task.id)
        }
    }

    public func resume(_ task: DownloadTask) async {
        guard await waitForRestore() else { return }
        guard await task.state == .paused else { return }

        if let resumeData = await task.resumeData {
            do {
                try await persistence.upsert(id: task.id, url: task.url, destinationURL: task.destinationURL)
            } catch {
                await transferCoordinator.markTaskFailedForPersistence(task, error: error)
                return
            }
            let urlTask = session.makeDownloadTask(withResumeData: resumeData)
            await transferCoordinator.register(urlTask: urlTask, for: task)
            await task.updateState(.downloading)
            await task.setResumeData(nil)
            do {
                try await persistence.updateResumeData(id: task.id, resumeData: nil)
            } catch {
                Self.logger.fault(
                    "Failed to clear resumeData for task \(task.id, privacy: .private(mask: .hash)) on resume: \(String(describing: error), privacy: .private(mask: .hash))"
                )
                urlTask.cancel()
                await transferCoordinator.markTaskFailedForPersistence(task, error: error)
                return
            }
            await runtimeRegistry.onStateChanged?(task, .downloading)
            await eventHub.publish(.stateChanged(.downloading), for: task.id)
            urlTask.resume()
        } else {
            await transferCoordinator.startDownload(task)
        }
    }

    public func cancel(_ task: DownloadTask) async {
        guard await waitForRestore() else { return }
        // Drive the state transition only when we're leaving a non-terminal
        // state. Calling `cancel` again on an already-terminal task (for
        // example, after the first attempt's persistence removal failed)
        // continues into the cleanup path below so callers can drain the
        // registry without triggering an illegal-transition assertion.
        if !(await task.state).isTerminal {
            await task.updateState(.cancelled)
            await task.setError(.cancelled)
            await runtimeRegistry.onStateChanged?(task, .cancelled)
            await eventHub.publish(.stateChanged(.cancelled), for: task.id)

            if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
                urlTask.cancel()
            }
        }

        do {
            try await persistence.remove(id: task.id)
        } catch {
            Self.logger.fault(
                "Failed to remove cancelled task \(task.id, privacy: .private(mask: .hash)) from persistence: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            return
        }
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        await eventHub.finish(taskID: task.id)
        await runtimeRegistry.remove(task)
    }

    public func cancelAll() async {
        guard await waitForRestore() else { return }
        for task in await runtimeRegistry.allTasks() {
            await cancel(task)
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
    ///
    /// In tests and apps that own the manager instance directly, prefer
    /// `shutdown()` over relying on `deinit` — Foundation will hold the
    /// session (and thus the manager and its closures) alive until invalidate
    /// completes, which can take longer than the surrounding scope.
    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true

        delegateEventContinuation.finish()

        // Cancel every in-flight URLSession task before invalidating, then
        // close the per-task event partition so listeners receive a clean
        // end-of-stream signal instead of hanging indefinitely. We do not
        // await the URLSession-level cancellation (it's fire-and-forget by
        // contract); `invalidateAndCancel()` below drains the rest.
        for task in await runtimeRegistry.allTasks() {
            if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
                urlTask.cancel()
            }
            await runtimeRegistry.removeTaskRuntime(taskId: task.id)
            await eventHub.finish(taskID: task.id)
        }

        // `invalidateAndCancel()` (not `finishTasksAndInvalidate()`) is the
        // correct call here: any pending transfers should die immediately so
        // the OS releases the session identifier and the delegate.
        session.invalidateAndCancel()
    }

    public func retry(_ task: DownloadTask) async {
        guard await waitForRestore() else { return }
        guard await task.state == .failed else { return }
        await task.reset()
        await transferCoordinator.startDownload(task)
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
        let listenerID = await eventHub.addListener(taskID: task.id, listener: listener)
        return DownloadEventSubscription(taskId: task.id, listenerID: listenerID)
    }

    public func removeEventListener(_ subscription: DownloadEventSubscription) async {
        await eventHub.removeListener(taskID: subscription.taskId, listenerID: subscription.listenerID)
    }

    public func events(for task: DownloadTask) async -> AsyncStream<DownloadEvent> {
        let stream = await eventHub.stream(for: task.id)
        await flushPendingRestoreFailureIfNeeded(taskID: task.id)
        return stream
    }

    private func recordPendingRestoreFailures(_ taskIDs: [String]) async {
        pendingRestoreFailures.formUnion(taskIDs)
        // If callers wired handlers up before restoration completed, flush
        // immediately so they observe the failure without needing to also
        // subscribe through `events(for:)`.
        await drainPendingRestoreFailuresToHandlers()
    }

    private func flushPendingRestoreFailureIfNeeded(taskID: String) async {
        guard pendingRestoreFailures.remove(taskID) != nil else { return }
        await drainRestoreFailure(taskID: taskID)
    }

    private func drainPendingRestoreFailuresToHandlers() async {
        let onState = await runtimeRegistry.onStateChanged
        let onFailed = await runtimeRegistry.onFailed
        guard onState != nil || onFailed != nil else { return }
        let ids = pendingRestoreFailures
        pendingRestoreFailures.removeAll()
        for id in ids {
            await drainRestoreFailure(taskID: id)
        }
    }

    private func drainRestoreFailure(taskID: String) async {
        let task = await runtimeRegistry.task(withId: taskID)
        if let task {
            await runtimeRegistry.onStateChanged?(task, .failed)
            await runtimeRegistry.onFailed?(task, .restorationMissingSystemTask)
        }
        await eventHub.publish(.stateChanged(.failed), for: taskID)
        await eventHub.publish(.failed(.restorationMissingSystemTask), for: taskID)
        await eventHub.finish(taskID: taskID)
        if let task {
            await runtimeRegistry.remove(task)
        }
    }

    private func waitForRestore() async -> Bool {
        do {
            try await restoreBarrier.wait()
            try Task.checkCancellation()
            return true
        } catch {
            return false
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
        await runtimeRegistry.onProgress?(task, progress)
        await eventHub.publish(.progress(progress), for: task.id)
    }

    private func handleDelegateEvent(_ event: DelegateEvent) async {
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

    /// Wired into the host app's
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// entry point. That method is synchronous, so this entry point is
    /// `nonisolated` to avoid forcing callers to await.
    public nonisolated func handleBackgroundSessionCompletion(
        _ identifier: String, completion: @escaping @Sendable () -> Void
    ) {
        guard identifier == configuration.sessionIdentifier else {
            completion()
            return
        }
        let store = backgroundCompletionStore
        Task {
            guard let completionToRun = await store.set(completion) else { return }
            await MainActor.run {
                completionToRun()
            }
        }
    }

    deinit {
        delegateEventContinuation.finish()
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
}

private actor RestoreBarrier {
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
            Task {
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
