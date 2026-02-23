import Foundation
import InnoNetwork


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


public final class DownloadManager: NSObject, Sendable {
    public static let shared = DownloadManager()

    private let configuration: DownloadConfiguration
    private let session: URLSession
    private let delegate: DownloadSessionDelegate
    private let backgroundCompletionStore: BackgroundCompletionStore
    private let persistence: DownloadTaskPersistence

    private let storage = DownloadStorage()
    private let restoreBarrier = RestoreBarrier()

    public init(configuration: DownloadConfiguration = .default) {
        self.configuration = configuration
        let callbacks = DownloadSessionDelegateCallbacks()
        let backgroundCompletionStore = BackgroundCompletionStore()
        self.delegate = DownloadSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore
        )
        self.backgroundCompletionStore = backgroundCompletionStore
        self.persistence = DownloadTaskPersistence(sessionIdentifier: configuration.sessionIdentifier)

        let sessionConfig = configuration.makeURLSessionConfiguration()
        self.session = URLSession(
            configuration: sessionConfig,
            delegate: delegate,
            delegateQueue: nil
        )

        super.init()

        callbacks.setHandlers(
            onProgress: { [weak self] taskIdentifier, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite in
                self?.handleProgress(
                    taskIdentifier: taskIdentifier,
                    bytesWritten: bytesWritten,
                    totalBytesWritten: totalBytesWritten,
                    totalBytesExpectedToWrite: totalBytesExpectedToWrite
                )
            },
            onCompletion: { [weak self] taskIdentifier, location, error in
                self?.handleCompletion(
                    taskIdentifier: taskIdentifier,
                    location: location,
                    error: error
                )
            }
        )

        Task { [self] in
            await self.restorePendingDownloads()
            await self.restoreBarrier.complete()
        }
    }

    public func setOnProgressHandler(_ callback: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?) async {
        await storage.setOnProgress(callback)
    }

    public func setOnStateChangedHandler(_ callback: (@Sendable (DownloadTask, DownloadState) async -> Void)?) async {
        await storage.setOnStateChanged(callback)
    }

    public func setOnCompletedHandler(_ callback: (@Sendable (DownloadTask, URL) async -> Void)?) async {
        await storage.setOnCompleted(callback)
    }

    public func setOnFailedHandler(_ callback: (@Sendable (DownloadTask, DownloadError) async -> Void)?) async {
        await storage.setOnFailed(callback)
    }

    @discardableResult
    public func download(url: URL, to destinationURL: URL) async -> DownloadTask {
        await waitForRestore()
        let task = DownloadTask(url: url, destinationURL: destinationURL)
        await storage.add(task)
        await startDownload(task)
        return task
    }

    @discardableResult
    public func download(url: URL, toDirectory directory: URL, fileName: String? = nil) async -> DownloadTask {
        await waitForRestore()
        let name = fileName ?? url.lastPathComponent
        let destinationURL = directory.appendingPathComponent(name)
        return await download(url: url, to: destinationURL)
    }

    public func pause(_ task: DownloadTask) async {
        await waitForRestore()
        guard await task.state == .downloading else { return }

        if let urlTask = await storage.urlTask(for: task.id) {
            let resumeData = await urlTask.cancelByProducingResumeData()
            await task.setResumeData(resumeData)
            await task.updateState(.paused)
            await storage.onStateChanged?(task, .paused)
            await storage.emitEvent(.stateChanged(.paused), for: task.id)
        }
    }

    public func resume(_ task: DownloadTask) async {
        await waitForRestore()
        guard await task.state == .paused else { return }

        if let resumeData = await task.resumeData {
            await persistence.upsert(id: task.id, url: task.url, destinationURL: task.destinationURL)
            let urlTask = session.downloadTask(withResumeData: resumeData)
            await register(urlTask: urlTask, for: task)
            await task.updateState(.downloading)
            await task.setResumeData(nil)
            await storage.onStateChanged?(task, .downloading)
            await storage.emitEvent(.stateChanged(.downloading), for: task.id)
            urlTask.resume()
        } else {
            await startDownload(task)
        }
    }

    public func cancel(_ task: DownloadTask) async {
        await waitForRestore()
        await task.updateState(.cancelled)
        await task.setError(.cancelled)
        await storage.onStateChanged?(task, .cancelled)
        await storage.emitEvent(.stateChanged(.cancelled), for: task.id)

        if let urlTask = await storage.urlTask(for: task.id) {
            urlTask.cancel()
        }

        await storage.removeTaskAndListeners(taskId: task.id)
        await storage.remove(task)
        await persistence.remove(id: task.id)
    }

    public func cancelAll() async {
        await waitForRestore()
        for task in await storage.allTasks() {
            await cancel(task)
        }
    }

    public func retry(_ task: DownloadTask) async {
        await waitForRestore()
        guard await task.state == .failed else { return }
        await task.reset()
        await startDownload(task)
    }

    public func task(withId id: String) async -> DownloadTask? {
        await waitForRestore()
        return await storage.task(withId: id)
    }

    public func allTasks() async -> [DownloadTask] {
        await waitForRestore()
        return await storage.allTasks()
    }

    public func activeTasks() async -> [DownloadTask] {
        await waitForRestore()
        var result: [DownloadTask] = []
        for task in await storage.allTasks() {
            let state = await task.state
            if state == .downloading || state == .waiting {
                result.append(task)
            }
        }
        return result
    }

    func runtimeTaskIdentifier(for task: DownloadTask) async -> Int? {
        await storage.taskIdentifier(for: task.id)
    }

    func listenerCount(for task: DownloadTask) async -> Int {
        await storage.eventListenerCount(for: task.id)
    }

    public func addEventListener(
        for task: DownloadTask,
        listener: @escaping @Sendable (DownloadEvent) -> Void
    ) async -> DownloadEventSubscription {
        let listenerID = await storage.addEventListener(taskId: task.id, listener: listener)
        return DownloadEventSubscription(taskId: task.id, listenerID: listenerID)
    }

    public func removeEventListener(_ subscription: DownloadEventSubscription) async {
        await storage.removeEventListener(taskId: subscription.taskId, listenerID: subscription.listenerID)
    }

    public func events(for task: DownloadTask) -> AsyncStream<DownloadEvent> {
        AsyncStream { [storage] continuation in
            let taskId = task.id
            let registrationTask = Task {
                await storage.addEventListener(taskId: taskId) { event in
                    continuation.yield(event)
                }
            }
            continuation.onTermination = { @Sendable _ in
                Task {
                    let listenerID = await registrationTask.value
                    await storage.removeEventListener(taskId: taskId, listenerID: listenerID)
                }
            }
        }
    }

    private func waitForRestore() async {
        await restoreBarrier.wait()
    }

    private func fetchDownloadTasks() async -> [URLSessionDownloadTask] {
        await withCheckedContinuation { continuation in
            session.getTasksWithCompletionHandler { _, _, downloadTasks in
                continuation.resume(returning: downloadTasks)
            }
        }
    }

    private func restorePendingDownloads() async {
        let downloadTasks = await fetchDownloadTasks()
        var restoredTaskIDs = Set<String>()

        for urlTask in downloadTasks {
            guard let downloadTask = await restoreTrackedTask(for: urlTask) else { continue }
            restoredTaskIDs.insert(downloadTask.id)

            await register(urlTask: urlTask, for: downloadTask)

            let state: DownloadState
            switch urlTask.state {
            case .running:
                state = .downloading
            case .suspended:
                state = .paused
            case .canceling:
                state = .cancelled
            case .completed:
                state = .completed
            @unknown default:
                state = .waiting
            }
            await downloadTask.updateState(state)
        }

        await persistence.prune(keeping: restoredTaskIDs)
    }

    private func restoreTrackedTask(for urlTask: URLSessionDownloadTask) async -> DownloadTask? {
        guard let taskID = urlTask.taskDescription else {
            return nil
        }

        if let existing = await storage.task(withId: taskID) {
            return existing
        }

        guard let record = await persistence.record(forID: taskID) else { return nil }
        let restoredTask = DownloadTask(url: record.url, destinationURL: record.destinationURL, id: record.id)
        await storage.add(restoredTask)
        return restoredTask
    }

    private func startDownload(_ task: DownloadTask) async {
        await task.updateState(.waiting)
        await storage.onStateChanged?(task, .waiting)
        await storage.emitEvent(.stateChanged(.waiting), for: task.id)
        await persistence.upsert(id: task.id, url: task.url, destinationURL: task.destinationURL)

        let urlTask = session.downloadTask(with: task.url)
        await register(urlTask: urlTask, for: task)

        await task.updateState(.downloading)
        await storage.onStateChanged?(task, .downloading)
        await storage.emitEvent(.stateChanged(.downloading), for: task.id)
        urlTask.resume()
    }

    private func register(urlTask: URLSessionDownloadTask, for task: DownloadTask) async {
        urlTask.taskDescription = task.id
        await storage.setMapping(downloadTask: task, for: urlTask.taskIdentifier)
        await storage.setURLTask(urlTask, for: task.id)
    }

    func handleProgress(taskIdentifier: Int, bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task {
            guard let task = await storage.downloadTask(for: taskIdentifier) else { return }

            let progress = DownloadProgress(
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
            await task.updateProgress(progress)
            await storage.onProgress?(task, progress)
            await storage.emitEvent(.progress(progress), for: task.id)
        }
    }

    func handleCompletion(taskIdentifier: Int, location: URL?, error: SendableUnderlyingError?) {
        Task {
            guard let task = await storage.downloadTask(for: taskIdentifier) else { return }

            if let error {
                await storage.detachRuntime(taskIdentifier: taskIdentifier)
                await handleError(task: task, error: error)
                return
            }

            guard let location else {
                await storage.detachRuntime(taskIdentifier: taskIdentifier)
                await handleError(
                    task: task,
                    error: SendableUnderlyingError(
                        domain: "InnoNetworkDownload",
                        code: -1,
                        message: "Download completed without temporary file location."
                    )
                )
                return
            }

            do {
                let fileManager = FileManager.default

                if fileManager.fileExists(atPath: task.destinationURL.path) {
                    try fileManager.removeItem(at: task.destinationURL)
                }

                let directory = task.destinationURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: directory.path) {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                }

                try fileManager.moveItem(at: location, to: task.destinationURL)

                await task.updateState(.completed)
                await storage.onStateChanged?(task, .completed)
                await storage.onCompleted?(task, task.destinationURL)
                await storage.emitEvent(.stateChanged(.completed), for: task.id)
                await storage.emitEvent(.completed(task.destinationURL), for: task.id)
                await storage.removeTaskAndListeners(taskId: task.id)
                await storage.remove(task)
                await persistence.remove(id: task.id)
            } catch {
                await storage.detachRuntime(taskIdentifier: taskIdentifier)
                await handleError(
                    task: task,
                    error: SendableUnderlyingError(error)
                )
            }
        }
    }

    private func isCancelledTransportError(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    }

    private func handleError(task: DownloadTask, error: SendableUnderlyingError) async {
        if isCancelledTransportError(error) {
            return
        }
        let totalRetryCount = await task.incrementTotalRetryCount()
        guard totalRetryCount <= configuration.maxTotalRetries else {
            await markTaskFailed(task)
            return
        }

        let retryCount = await task.incrementRetryCount()
        guard retryCount <= configuration.maxRetryCount else {
            await markTaskFailed(task)
            return
        }

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

        try? await Task.sleep(nanoseconds: UInt64(configuration.retryDelay * 1_000_000_000))
        let state = await task.state
        if state != .cancelled {
            await startDownload(task)
        }
    }

    private func markTaskFailed(_ task: DownloadTask) async {
        await task.updateState(.failed)
        await task.setError(.maxRetriesExceeded)
        await storage.onStateChanged?(task, .failed)
        await storage.onFailed?(task, .maxRetriesExceeded)
        await storage.emitEvent(.stateChanged(.failed), for: task.id)
        await storage.emitEvent(.failed(.maxRetriesExceeded), for: task.id)
        await storage.removeTaskAndListeners(taskId: task.id)
        await storage.remove(task)
        await persistence.remove(id: task.id)
    }

    public func handleBackgroundSessionCompletion(_ identifier: String, completion: @escaping @Sendable () -> Void) {
        guard identifier == configuration.sessionIdentifier else {
            completion()
            return
        }
        Task {
            await backgroundCompletionStore.set(completion)
        }
    }
}


private actor DownloadStorage {
    private var tasks: [String: DownloadTask] = [:]
    private var identifierToTask: [Int: DownloadTask] = [:]
    private var taskIdToURLTask: [String: URLSessionDownloadTask] = [:]
    private var eventListeners: [String: [UUID: @Sendable (DownloadEvent) -> Void]] = [:]

    private var _onProgress: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?
    private var _onStateChanged: (@Sendable (DownloadTask, DownloadState) async -> Void)?
    private var _onCompleted: (@Sendable (DownloadTask, URL) async -> Void)?
    private var _onFailed: (@Sendable (DownloadTask, DownloadError) async -> Void)?

    var onProgress: (@Sendable (DownloadTask, DownloadProgress) async -> Void)? { _onProgress }
    var onStateChanged: (@Sendable (DownloadTask, DownloadState) async -> Void)? { _onStateChanged }
    var onCompleted: (@Sendable (DownloadTask, URL) async -> Void)? { _onCompleted }
    var onFailed: (@Sendable (DownloadTask, DownloadError) async -> Void)? { _onFailed }

    func setOnProgress(_ callback: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?) {
        _onProgress = callback
    }

    func setOnStateChanged(_ callback: (@Sendable (DownloadTask, DownloadState) async -> Void)?) {
        _onStateChanged = callback
    }

    func setOnCompleted(_ callback: (@Sendable (DownloadTask, URL) async -> Void)?) {
        _onCompleted = callback
    }

    func setOnFailed(_ callback: (@Sendable (DownloadTask, DownloadError) async -> Void)?) {
        _onFailed = callback
    }

    func addEventListener(taskId: String, listener: @escaping @Sendable (DownloadEvent) -> Void) -> UUID {
        let listenerID = UUID()
        var listeners = eventListeners[taskId] ?? [:]
        listeners[listenerID] = listener
        eventListeners[taskId] = listeners
        return listenerID
    }

    func removeEventListener(taskId: String, listenerID: UUID) {
        guard var listeners = eventListeners[taskId] else { return }
        listeners.removeValue(forKey: listenerID)
        if listeners.isEmpty {
            eventListeners.removeValue(forKey: taskId)
        } else {
            eventListeners[taskId] = listeners
        }
    }

    func emitEvent(_ event: DownloadEvent, for taskId: String) {
        guard let listeners = eventListeners[taskId] else { return }
        for listener in listeners.values {
            listener(event)
        }
    }

    func add(_ task: DownloadTask) {
        tasks[task.id] = task
    }

    func remove(_ task: DownloadTask) {
        tasks.removeValue(forKey: task.id)
    }

    func task(withId id: String) -> DownloadTask? {
        tasks[id]
    }

    func allTasks() -> [DownloadTask] {
        Array(tasks.values)
    }

    func setMapping(downloadTask: DownloadTask, for identifier: Int) {
        identifierToTask[identifier] = downloadTask
    }

    func setURLTask(_ urlTask: URLSessionDownloadTask, for taskId: String) {
        taskIdToURLTask[taskId] = urlTask
    }

    func downloadTask(for identifier: Int) -> DownloadTask? {
        identifierToTask[identifier]
    }

    func urlTask(for taskId: String) -> URLSessionDownloadTask? {
        taskIdToURLTask[taskId]
    }

    func taskIdentifier(for taskId: String) -> Int? {
        identifierToTask.first { $0.value.id == taskId }?.key
    }

    func eventListenerCount(for taskId: String) -> Int {
        eventListeners[taskId]?.count ?? 0
    }

    func detachRuntime(taskIdentifier: Int) {
        identifierToTask.removeValue(forKey: taskIdentifier)
    }

    func removeTaskRuntime(taskId: String) {
        taskIdToURLTask.removeValue(forKey: taskId)
        identifierToTask = identifierToTask.filter { $0.value.id != taskId }
    }

    func removeTaskAndListeners(taskId: String) {
        removeTaskRuntime(taskId: taskId)
        eventListeners.removeValue(forKey: taskId)
    }
}


private actor RestoreBarrier {
    private var isCompleted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isCompleted else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
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
