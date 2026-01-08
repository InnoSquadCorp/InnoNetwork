import Foundation
import InnoNetwork


public enum DownloadEvent: Sendable {
    case progress(DownloadProgress)
    case stateChanged(DownloadState)
    case completed(URL)
    case failed(DownloadError)
}


public final class DownloadManager: NSObject, Sendable {
    public static let shared = DownloadManager()
    
    private let configuration: DownloadConfiguration
    private let session: URLSession
    private let delegate: DownloadSessionDelegate
    
    private let storage = DownloadStorage()
    
    public var onProgress: (@Sendable (DownloadTask, DownloadProgress) async -> Void)? {
        get { storage.onProgressSync }
        set { storage.onProgressSync = newValue }
    }
    public var onStateChanged: (@Sendable (DownloadTask, DownloadState) async -> Void)? {
        get { storage.onStateChangedSync }
        set { storage.onStateChangedSync = newValue }
    }
    public var onCompleted: (@Sendable (DownloadTask, URL) async -> Void)? {
        get { storage.onCompletedSync }
        set { storage.onCompletedSync = newValue }
    }
    public var onFailed: (@Sendable (DownloadTask, DownloadError) async -> Void)? {
        get { storage.onFailedSync }
        set { storage.onFailedSync = newValue }
    }
    
    public init(configuration: DownloadConfiguration = .default) {
        self.configuration = configuration
        self.delegate = DownloadSessionDelegate()
        
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
    
    private func restorePendingDownloads() {
        session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            guard let self else { return }
            Task {
                for urlTask in downloadTasks {
                    if let originalURL = urlTask.originalRequest?.url,
                       let downloadTask = await self.storage.task(forURL: originalURL) {
                        await self.storage.setMapping(downloadTask: downloadTask, for: urlTask.taskIdentifier)
                    }
                }
            }
        }
    }
    
    @discardableResult
    public func download(url: URL, to destinationURL: URL) async -> DownloadTask {
        let task = DownloadTask(url: url, destinationURL: destinationURL)
        await storage.add(task)
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
            urlTask.cancel { [weak self] resumeData in
                Task {
                    await task.setResumeData(resumeData)
                    await task.updateState(.paused)
                    await self?.storage.onStateChanged?(task, .paused)
                }
            }
        }
    }
    
    public func resume(_ task: DownloadTask) async {
        guard await task.state == .paused else { return }
        
        if let resumeData = await task.resumeData {
            let urlTask = session.downloadTask(withResumeData: resumeData)
            await storage.setMapping(downloadTask: task, for: urlTask.taskIdentifier)
            await storage.setURLTask(urlTask, for: task.id)
            await task.updateState(.downloading)
            await task.setResumeData(nil)
            await storage.onStateChanged?(task, .downloading)
            urlTask.resume()
        } else {
            await startDownload(task)
        }
    }
    
    public func cancel(_ task: DownloadTask) async {
        await task.updateState(.cancelled)
        await task.setError(.cancelled)
        await storage.onStateChanged?(task, .cancelled)
        
        if let urlTask = await storage.urlTask(for: task.id) {
            urlTask.cancel()
        }
        
        await storage.remove(taskId: task.id)
        await storage.remove(task)
    }
    
    public func cancelAll() async {
        for task in await storage.allTasks() {
            await cancel(task)
        }
    }
    
    public func retry(_ task: DownloadTask) async {
        guard await task.state == .failed else { return }
        await task.reset()
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
    
    public func events(for task: DownloadTask) -> AsyncStream<DownloadEvent> {
        AsyncStream { [storage] continuation in
            let taskId = task.id
            
            Task {
                await storage.addEventListener(taskId: taskId) { event in
                    continuation.yield(event)
                }
            }
            
            continuation.onTermination = { @Sendable _ in
                Task {
                    await storage.removeEventListener(taskId: taskId)
                }
            }
        }
    }
    
    private func startDownload(_ task: DownloadTask) async {
        await task.updateState(.waiting)
        await storage.onStateChanged?(task, .waiting)
        
        let urlTask = session.downloadTask(with: task.url)
        await storage.setMapping(downloadTask: task, for: urlTask.taskIdentifier)
        await storage.setURLTask(urlTask, for: task.id)
        
        await task.updateState(.downloading)
        await storage.onStateChanged?(task, .downloading)
        urlTask.resume()
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
            
            if let error = error {
                await handleError(task: task, error: error)
                return
            }
            
            guard let location = location else {
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
                await storage.emitEvent(.completed(task.destinationURL), for: task.id)
                await storage.remove(task)
            } catch {
                await handleError(task: task, error: DownloadError.fileSystemError(error))
            }
        }
    }
    
    private func handleError(task: DownloadTask, error: Error) async {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return
        }

        let retryCount = await task.incrementRetryCount()

        if retryCount < configuration.maxRetryCount {
            if configuration.waitsForNetworkChanges, let monitor = configuration.networkMonitor {
                let snapshot = await monitor.currentSnapshot()
                _ = await monitor.waitForChange(from: snapshot, timeout: configuration.networkChangeTimeout)
            }
            try? await Task.sleep(nanoseconds: UInt64(configuration.retryDelay * 1_000_000_000))
            let state = await task.state
            if state != .cancelled {
                await startDownload(task)
            }
        } else {
            await task.updateState(.failed)
            await task.setError(.maxRetriesExceeded)
            await storage.onStateChanged?(task, .failed)
            await storage.onFailed?(task, .maxRetriesExceeded)
            await storage.emitEvent(.failed(.maxRetriesExceeded), for: task.id)
        }
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
    private var eventListeners: [String: @Sendable (DownloadEvent) -> Void] = [:]
    
    private var _onProgress: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?
    private var _onStateChanged: (@Sendable (DownloadTask, DownloadState) async -> Void)?
    private var _onCompleted: (@Sendable (DownloadTask, URL) async -> Void)?
    private var _onFailed: (@Sendable (DownloadTask, DownloadError) async -> Void)?
    
    var onProgress: (@Sendable (DownloadTask, DownloadProgress) async -> Void)? { _onProgress }
    var onStateChanged: (@Sendable (DownloadTask, DownloadState) async -> Void)? { _onStateChanged }
    var onCompleted: (@Sendable (DownloadTask, URL) async -> Void)? { _onCompleted }
    var onFailed: (@Sendable (DownloadTask, DownloadError) async -> Void)? { _onFailed }
    
    nonisolated var onProgressSync: (@Sendable (DownloadTask, DownloadProgress) async -> Void)? {
        get { nil }
        set { Task { await self.setOnProgress(newValue) } }
    }
    nonisolated var onStateChangedSync: (@Sendable (DownloadTask, DownloadState) async -> Void)? {
        get { nil }
        set { Task { await self.setOnStateChanged(newValue) } }
    }
    nonisolated var onCompletedSync: (@Sendable (DownloadTask, URL) async -> Void)? {
        get { nil }
        set { Task { await self.setOnCompleted(newValue) } }
    }
    nonisolated var onFailedSync: (@Sendable (DownloadTask, DownloadError) async -> Void)? {
        get { nil }
        set { Task { await self.setOnFailed(newValue) } }
    }
    
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
    
    func addEventListener(taskId: String, listener: @escaping @Sendable (DownloadEvent) -> Void) {
        eventListeners[taskId] = listener
    }
    
    func removeEventListener(taskId: String) {
        eventListeners.removeValue(forKey: taskId)
    }
    
    func emitEvent(_ event: DownloadEvent, for taskId: String) {
        eventListeners[taskId]?(event)
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
    
    func task(forURL url: URL) -> DownloadTask? {
        tasks.values.first { $0.url == url }
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
        }
    }
    
    func remove(taskId: String) {
        taskIdToURLTask.removeValue(forKey: taskId)
        identifierToTask = identifierToTask.filter { $0.value.id != taskId }
    }
}
