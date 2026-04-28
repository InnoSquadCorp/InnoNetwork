import Foundation

package actor DownloadRuntimeRegistry {
    private var tasks: [String: DownloadTask] = [:]
    private var identifierToTask: [Int: DownloadTask] = [:]
    private var taskIdToIdentifier: [String: Int] = [:]
    private var taskIdToURLTask: [String: any DownloadURLTask] = [:]

    private var _onProgress: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?
    private var _onStateChanged: (@Sendable (DownloadTask, DownloadState) async -> Void)?
    private var _onCompleted: (@Sendable (DownloadTask, URL) async -> Void)?
    private var _onFailed: (@Sendable (DownloadTask, DownloadError) async -> Void)?

    package var onProgress: (@Sendable (DownloadTask, DownloadProgress) async -> Void)? { _onProgress }
    package var onStateChanged: (@Sendable (DownloadTask, DownloadState) async -> Void)? { _onStateChanged }
    package var onCompleted: (@Sendable (DownloadTask, URL) async -> Void)? { _onCompleted }
    package var onFailed: (@Sendable (DownloadTask, DownloadError) async -> Void)? { _onFailed }

    package init() {}

    package func setOnProgress(_ callback: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?) {
        _onProgress = callback
    }

    package func setOnStateChanged(_ callback: (@Sendable (DownloadTask, DownloadState) async -> Void)?) {
        _onStateChanged = callback
    }

    package func setOnCompleted(_ callback: (@Sendable (DownloadTask, URL) async -> Void)?) {
        _onCompleted = callback
    }

    package func setOnFailed(_ callback: (@Sendable (DownloadTask, DownloadError) async -> Void)?) {
        _onFailed = callback
    }

    package func add(_ task: DownloadTask) {
        tasks[task.id] = task
    }

    package func remove(_ task: DownloadTask) {
        tasks.removeValue(forKey: task.id)
    }

    package func task(withId id: String) -> DownloadTask? {
        tasks[id]
    }

    package func allTasks() -> [DownloadTask] {
        Array(tasks.values)
    }

    package func setMapping(downloadTask: DownloadTask, for identifier: Int) {
        identifierToTask[identifier] = downloadTask
        taskIdToIdentifier[downloadTask.id] = identifier
    }

    package func setURLTask(_ urlTask: any DownloadURLTask, for taskId: String) {
        taskIdToURLTask[taskId] = urlTask
    }

    package func downloadTask(for identifier: Int) -> DownloadTask? {
        identifierToTask[identifier]
    }

    package func urlTask(for taskId: String) -> (any DownloadURLTask)? {
        taskIdToURLTask[taskId]
    }

    package func taskIdentifier(for taskId: String) -> Int? {
        taskIdToIdentifier[taskId]
    }

    package func detachRuntime(taskIdentifier: Int) {
        guard let task = identifierToTask.removeValue(forKey: taskIdentifier) else { return }
        taskIdToIdentifier.removeValue(forKey: task.id)
    }

    package func removeTaskRuntime(taskId: String) {
        taskIdToURLTask.removeValue(forKey: taskId)
        if let identifier = taskIdToIdentifier.removeValue(forKey: taskId) {
            identifierToTask.removeValue(forKey: identifier)
        } else {
            identifierToTask = identifierToTask.filter { entry in
                let isTarget = entry.value.id == taskId
                if isTarget {
                    taskIdToIdentifier.removeValue(forKey: taskId)
                }
                return !isTarget
            }
        }
    }
}
