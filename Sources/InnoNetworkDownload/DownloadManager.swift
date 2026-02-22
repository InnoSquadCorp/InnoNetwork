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
    private let persistence: DownloadTaskPersistence
    private let callbackMirror = DownloadCallbackMirror()

    private let storage = DownloadStorage()

    @available(*, deprecated, message: "Use setOnProgressHandler(_:) to avoid callback registration races.")
    public var onProgress: (@Sendable (DownloadTask, DownloadProgress) async -> Void)? {
        get { callbackMirror.onProgress }
        set {
            callbackMirror.onProgress = newValue
            Task {
                await setOnProgressHandler(newValue)
            }
        }
    }

    @available(*, deprecated, message: "Use setOnStateChangedHandler(_:) to avoid callback registration races.")
    public var onStateChanged: (@Sendable (DownloadTask, DownloadState) async -> Void)? {
        get { callbackMirror.onStateChanged }
        set {
            callbackMirror.onStateChanged = newValue
            Task {
                await setOnStateChangedHandler(newValue)
            }
        }
    }

    @available(*, deprecated, message: "Use setOnCompletedHandler(_:) to avoid callback registration races.")
    public var onCompleted: (@Sendable (DownloadTask, URL) async -> Void)? {
        get { callbackMirror.onCompleted }
        set {
            callbackMirror.onCompleted = newValue
            Task {
                await setOnCompletedHandler(newValue)
            }
        }
    }

    @available(*, deprecated, message: "Use setOnFailedHandler(_:) to avoid callback registration races.")
    public var onFailed: (@Sendable (DownloadTask, DownloadError) async -> Void)? {
        get { callbackMirror.onFailed }
        set {
            callbackMirror.onFailed = newValue
            Task {
                await setOnFailedHandler(newValue)
            }
        }
    }

    public init(configuration: DownloadConfiguration = .default) {
        self.configuration = configuration
        self.delegate = DownloadSessionDelegate()
        self.persistence = DownloadTaskPersistence(sessionIdentifier: configuration.sessionIdentifier)

        let sessionConfig = configuration.makeURLSessionConfiguration()
        self.session = URLSession(
            configuration: sessionConfig,
            delegate: delegate,
            delegateQueue: nil
        )

        super.init()

        delegate.manager = self
        restorePendingDownloads()
    }

    public func setOnProgressHandler(_ callback: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?) async {
        callbackMirror.onProgress = callback
        await storage.setOnProgress(callback)
    }

    public func setOnStateChangedHandler(_ callback: (@Sendable (DownloadTask, DownloadState) async -> Void)?) async {
        callbackMirror.onStateChanged = callback
        await storage.setOnStateChanged(callback)
    }

    public func setOnCompletedHandler(_ callback: (@Sendable (DownloadTask, URL) async -> Void)?) async {
        callbackMirror.onCompleted = callback
        await storage.setOnCompleted(callback)
    }

    public func setOnFailedHandler(_ callback: (@Sendable (DownloadTask, DownloadError) async -> Void)?) async {
        callbackMirror.onFailed = callback
        await storage.setOnFailed(callback)
    }

    @discardableResult
    public func download(url: URL, to destinationURL: URL) async -> DownloadTask {
        let task = DownloadTask(url: url, destinationURL: destinationURL)
        await storage.add(task)
        await persistence.upsert(id: task.id, url: task.url, destinationURL: task.destinationURL)
        await startDownload(task)
        return task
    }

    @discardableResult
    public func download(url: URL, toDirectory directory: URL, fileName: String? = nil) async -> DownloadTask {
        let name = fileName ?? url.lastPathComponent
        let destinationURL = directory.appendingPathComponent(name)
        return await download(url: url, to: destinationURL)
    }

    public func pause(_ task: DownloadTask) async {
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
        await task.updateState(.cancelled)
        await task.setError(.cancelled)
        await storage.onStateChanged?(task, .cancelled)
        await storage.emitEvent(.stateChanged(.cancelled), for: task.id)

        if let urlTask = await storage.urlTask(for: task.id) {
            urlTask.cancel()
        }

        await storage.remove(taskId: task.id)
        await storage.remove(task)
        await persistence.remove(id: task.id)
    }

    public func cancelAll() async {
        for task in await storage.allTasks() {
            await cancel(task)
        }
    }

    public func retry(_ task: DownloadTask) async {
        guard await task.state == .failed else { return }
        await task.reset()
        await persistence.upsert(id: task.id, url: task.url, destinationURL: task.destinationURL)
        await startDownload(task)
    }

    public func task(withId id: String) async -> DownloadTask? {
        await storage.task(withId: id)
    }

    public func allTasks() async -> [DownloadTask] {
        await storage.allTasks()
    }

    public func activeTasks() async -> [DownloadTask] {
        var result: [DownloadTask] = []
        for task in await storage.allTasks() {
            let state = await task.state
            if state == .downloading || state == .waiting {
                result.append(task)
            }
        }
        return result
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
            Task {
                let listenerID = await storage.addEventListener(taskId: taskId) { event in
                    continuation.yield(event)
                }
                continuation.onTermination = { @Sendable _ in
                    Task {
                        await storage.removeEventListener(taskId: taskId, listenerID: listenerID)
                    }
                }
            }
        }
    }

    private func restorePendingDownloads() {
        session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            guard let self else { return }
            Task {
                var restoredTaskIDs = Set<String>()

                for urlTask in downloadTasks {
                    guard let downloadTask = await self.restoreTrackedTask(for: urlTask) else { continue }
                    restoredTaskIDs.insert(downloadTask.id)

                    await self.register(urlTask: urlTask, for: downloadTask)

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

                await self.persistence.prune(keeping: restoredTaskIDs)
            }
        }
    }

    private func restoreTrackedTask(for urlTask: URLSessionDownloadTask) async -> DownloadTask? {
        let taskID: String
        if let existingTaskID = urlTask.taskDescription {
            taskID = existingTaskID
        } else if let record = await persistence.record(forURL: urlTask.originalRequest?.url) {
            taskID = record.id
        } else {
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

    func handleCompletion(taskIdentifier: Int, location: URL?, error: Error?) {
        Task {
            guard let task = await storage.downloadTask(for: taskIdentifier) else { return }

            defer {
                Task { await storage.remove(taskIdentifier: taskIdentifier) }
            }

            if let error {
                await handleError(task: task, error: error)
                return
            }

            guard let location else {
                await handleError(task: task, error: DownloadError.unknown)
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
                await storage.remove(task)
                await persistence.remove(id: task.id)
            } catch {
                await handleError(task: task, error: DownloadError.fileSystemError(error))
            }
        }
    }

    private func handleError(task: DownloadTask, error: Error) async {
        if let urlError = error as? URLError, urlError.code == .cancelled {
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
        await persistence.remove(id: task.id)
    }

    public func handleBackgroundSessionCompletion(_ identifier: String, completion: @escaping @Sendable () -> Void) {
        guard identifier == configuration.sessionIdentifier else {
            completion()
            return
        }
        delegate.backgroundCompletionHandler = completion
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
        eventListeners.removeValue(forKey: task.id)
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

    func remove(taskIdentifier: Int) {
        if let task = identifierToTask.removeValue(forKey: taskIdentifier) {
            taskIdToURLTask.removeValue(forKey: task.id)
            eventListeners.removeValue(forKey: task.id)
        }
    }

    func remove(taskId: String) {
        taskIdToURLTask.removeValue(forKey: taskId)
        identifierToTask = identifierToTask.filter { $0.value.id != taskId }
        eventListeners.removeValue(forKey: taskId)
    }
}

private final class DownloadCallbackMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var _onProgress: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?
    private var _onStateChanged: (@Sendable (DownloadTask, DownloadState) async -> Void)?
    private var _onCompleted: (@Sendable (DownloadTask, URL) async -> Void)?
    private var _onFailed: (@Sendable (DownloadTask, DownloadError) async -> Void)?

    var onProgress: (@Sendable (DownloadTask, DownloadProgress) async -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onProgress
        }
        set {
            lock.lock()
            _onProgress = newValue
            lock.unlock()
        }
    }

    var onStateChanged: (@Sendable (DownloadTask, DownloadState) async -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onStateChanged
        }
        set {
            lock.lock()
            _onStateChanged = newValue
            lock.unlock()
        }
    }

    var onCompleted: (@Sendable (DownloadTask, URL) async -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onCompleted
        }
        set {
            lock.lock()
            _onCompleted = newValue
            lock.unlock()
        }
    }

    var onFailed: (@Sendable (DownloadTask, DownloadError) async -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onFailed
        }
        set {
            lock.lock()
            _onFailed = newValue
            lock.unlock()
        }
    }
}
