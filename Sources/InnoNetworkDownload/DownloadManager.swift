import Foundation
import InnoNetwork
import os
import OSLog


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
            return "DownloadManager sessionIdentifier '\(identifier)' is already in use. Use a unique sessionIdentifier for multiple managers."
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
/// into the actor through unstructured Tasks: each closure inside
/// `DownloadSessionDelegateCallbacks` schedules `Task { [weak self] in await
/// self?.handleX(...) }` so synchronous delegate dispatch never touches
/// actor-isolated state directly.
///
/// `handleBackgroundSessionCompletion(_:completion:)` is `nonisolated` so
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
/// (a synchronous Foundation entry point) can call it without `await`.
public actor DownloadManager {
    /// Shared `DownloadManager` for apps that need a single download domain.
    ///
    /// Initialized lazily with ``DownloadConfiguration/default``. If the
    /// default session identifier is already claimed by another
    /// `DownloadManager` in the same process, the shared instance falls back
    /// to a process-unique identifier (logged via OSLog `.fault`) and an
    /// `assertionFailure` is raised in DEBUG builds so the misuse is caught
    /// during development. Production callers that need explicit failure
    /// handling should construct managers via ``make(configuration:)`` instead
    /// of relying on `shared`.
    public static let shared: DownloadManager = {
        do {
            return try DownloadManager(configuration: .default)
        } catch DownloadManagerError.duplicateSessionIdentifier(let claimedIdentifier) {
            let fallbackIdentifier = "\(claimedIdentifier).fallback.\(UUID().uuidString)"
            let fallbackConfig = DownloadConfiguration.safeDefaults(
                sessionIdentifier: fallbackIdentifier
            )
            let logger = Logger(subsystem: "innosquad.network.download", category: "DownloadManager")
            logger.fault("""
                DownloadManager.shared could not bind session identifier \
                \(claimedIdentifier, privacy: .public): another DownloadManager already \
                owns it. Falling back to \(fallbackIdentifier, privacy: .public). Use \
                DownloadManager.make(configuration:) to construct managers with explicit \
                session identifiers.
                """)
            assertionFailure("""
                DownloadManager.shared bound a fallback session identifier '\(fallbackIdentifier)'. \
                Use DownloadManager.make(configuration:) and pass an explicit identifier instead \
                of relying on `.shared` when multiple managers coexist.
                """)
            do {
                return try DownloadManager(configuration: fallbackConfig)
            } catch {
                // Even the fallback failed — extremely unlikely because the
                // fallback identifier is freshly UUID-prefixed. Crash so the
                // problem surfaces rather than silently returning a broken
                // singleton.
                fatalError("DownloadManager.shared cannot initialize with fallback identifier: \(error.localizedDescription)")
            }
        } catch {
            // Any other initialization failure is structural (e.g., persistence
            // directory inaccessible) and not something a fallback identifier
            // would fix. Surface it.
            fatalError("DownloadManager.shared cannot initialize with .default configuration: \(error.localizedDescription)")
        }
    }()

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
    private let eventHub: TaskEventHub<DownloadEvent>

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

    public init(configuration: DownloadConfiguration = .default) throws {
        try self.init(
            configuration: configuration,
            persistence: DownloadTaskPersistence(sessionIdentifier: configuration.sessionIdentifier)
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
        try Self.registerSessionIdentifier(configuration.sessionIdentifier)
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

        // Delegate boundary: URL session's serial delegate queue invokes the
        // closures below synchronously. Each closure hops into an unstructured
        // Task so the actor-isolated handleX methods are awaited rather than
        // called inline (which would violate isolation). [weak self] keeps a
        // late callback after the manager is dropped from segfaulting.
        callbacks.setHandlers(
            onProgress: { [weak self] taskIdentifier, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite in
                Task { [weak self] in
                    await self?.handleProgress(
                        taskIdentifier: taskIdentifier,
                        bytesWritten: bytesWritten,
                        totalBytesWritten: totalBytesWritten,
                        totalBytesExpectedToWrite: totalBytesExpectedToWrite
                    )
                }
            },
            onCompletion: { [weak self] taskIdentifier, location, error in
                Task { [weak self] in
                    await self?.handleCompletion(
                        taskIdentifier: taskIdentifier,
                        location: location,
                        error: error
                    )
                }
            }
        )

        // Restoration runs on a detached Task so the actor init returns
        // immediately. waitForRestore() gates every public entry point on the
        // restoreBarrier, so callers that issue downloads before restoration
        // completes block until the barrier opens.
        Task { [weak self] in
            guard let self else { return }
            await self.restoreCoordinator.restorePendingDownloads()
            await self.restoreBarrier.complete()
        }
    }

    public func setOnProgressHandler(_ callback: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?) async {
        await runtimeRegistry.setOnProgress(callback)
    }

    public func setOnStateChangedHandler(_ callback: (@Sendable (DownloadTask, DownloadState) async -> Void)?) async {
        await runtimeRegistry.setOnStateChanged(callback)
    }

    public func setOnCompletedHandler(_ callback: (@Sendable (DownloadTask, URL) async -> Void)?) async {
        await runtimeRegistry.setOnCompleted(callback)
    }

    public func setOnFailedHandler(_ callback: (@Sendable (DownloadTask, DownloadError) async -> Void)?) async {
        await runtimeRegistry.setOnFailed(callback)
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
            await persistence.upsert(id: task.id, url: task.url, destinationURL: task.destinationURL)
            let urlTask = session.makeDownloadTask(withResumeData: resumeData)
            await transferCoordinator.register(urlTask: urlTask, for: task)
            await task.updateState(.downloading)
            await task.setResumeData(nil)
            await runtimeRegistry.onStateChanged?(task, .downloading)
            await eventHub.publish(.stateChanged(.downloading), for: task.id)
            urlTask.resume()
        } else {
            await transferCoordinator.startDownload(task)
        }
    }

    public func cancel(_ task: DownloadTask) async {
        guard await waitForRestore() else { return }
        await task.updateState(.cancelled)
        await task.setError(.cancelled)
        await runtimeRegistry.onStateChanged?(task, .cancelled)
        await eventHub.publish(.stateChanged(.cancelled), for: task.id)

        if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
            urlTask.cancel()
        }

        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        await eventHub.finish(taskID: task.id)
        await runtimeRegistry.remove(task)
        await persistence.remove(id: task.id)
    }

    public func cancelAll() async {
        guard await waitForRestore() else { return }
        for task in await runtimeRegistry.allTasks() {
            await cancel(task)
        }
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
        await eventHub.stream(for: task.id)
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

    func handleProgress(taskIdentifier: Int, bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) async {
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
    public nonisolated func handleBackgroundSessionCompletion(_ identifier: String, completion: @escaping @Sendable () -> Void) {
        guard identifier == configuration.sessionIdentifier else {
            completion()
            return
        }
        let store = backgroundCompletionStore
        Task {
            await store.set(completion)
        }
    }

    deinit {
        Self.unregisterSessionIdentifier(configuration.sessionIdentifier)
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
