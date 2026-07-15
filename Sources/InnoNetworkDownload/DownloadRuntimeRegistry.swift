import Foundation
import os

/// Marks execution inside a public download callback.
///
/// A callback may legitimately call `DownloadManager.shutdown()`. The active
/// token lets shutdown hand teardown to its dedicated worker and return from
/// the reentrant call instead of awaiting the callback that invoked it.
enum DownloadUserCallbackContext {
    @TaskLocal static var token: DownloadUserCallbackToken?
}


/// A TaskLocal token is inherited by unstructured child tasks. Active state is
/// kept in lock-backed storage so children that outlive a handler stop being
/// classified as reentrant as soon as that handler returns.
final class DownloadUserCallbackToken: Sendable {
    let managerID: UUID
    let taskID: String
    let parent: DownloadUserCallbackToken?
    private let active = OSAllocatedUnfairLock<Bool>(initialState: true)

    init(managerID: UUID, taskID: String, parent: DownloadUserCallbackToken?) {
        self.managerID = managerID
        self.taskID = taskID
        self.parent = parent
    }

    private var isActive: Bool {
        active.withLock { $0 }
    }

    func deactivate() {
        active.withLock { $0 = false }
    }

    /// Returns the innermost active callback task for this manager.
    ///
    /// Inline admission callbacks install another token above their caller, so
    /// walking from `self` toward `parent` identifies the callback that is
    /// currently making a synchronous lifecycle request. Inactive inherited
    /// tokens are skipped so child tasks that outlive a callback do not create
    /// false delivery dependencies.
    func activeTaskID(for managerID: UUID) -> String? {
        var candidate: DownloadUserCallbackToken? = self
        while let token = candidate {
            if token.managerID == managerID, token.isActive {
                return token.taskID
            }
            candidate = token.parent
        }
        return nil
    }

    func containsActiveCallback(for managerID: UUID) -> Bool {
        activeTaskID(for: managerID) != nil
    }

    func containsActiveCallback(for managerID: UUID, taskID: String) -> Bool {
        var candidate: DownloadUserCallbackToken? = self
        while let token = candidate {
            if token.managerID == managerID,
                token.taskID == taskID,
                token.isActive
            {
                return true
            }
            candidate = token.parent
        }
        return false
    }
}

package actor DownloadRuntimeRegistry {
    /// Distinguishes callback reentrancy for this manager from callbacks that
    /// happen to be running for another manager on the same task.
    package nonisolated let callbackContextID = UUID()
    /// Stable ownership token for every logical handle admitted to this
    /// registry. It is intentionally distinct from callbackContextID so the
    /// two contracts cannot be coupled accidentally.
    package nonisolated let ownershipID = UUID()

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

    package var hasRestoreFailureHandler: Bool {
        _onStateChanged != nil || _onFailed != nil
    }

    package var hasRestoreCompletionHandler: Bool {
        _onStateChanged != nil || _onCompleted != nil
    }

    package func notifyProgress(_ task: DownloadTask, _ progress: DownloadProgress) async {
        guard let callback = prepareProgressCallback(task, progress) else { return }
        await callback()
    }

    package func notifyStateChanged(_ task: DownloadTask, _ state: DownloadState) async {
        guard let callback = prepareStateChangedCallback(task, state) else { return }
        await callback()
    }

    package func notifyCompleted(_ task: DownloadTask, _ location: URL) async {
        guard let callback = prepareCompletedCallback(task, location) else { return }
        await callback()
    }

    package func notifyFailed(_ task: DownloadTask, _ error: DownloadError) async {
        guard let callback = prepareFailedCallback(task, error) else { return }
        await callback()
    }

    package func prepareProgressCallback(
        _ task: DownloadTask,
        _ progress: DownloadProgress
    ) -> (@Sendable () async -> Void)? {
        guard let callback = _onProgress else { return nil }
        return { [self] in
            await invokeUserCallback(taskID: task.id) {
                await callback(task, progress)
            }
        }
    }

    package func prepareStateChangedCallback(
        _ task: DownloadTask,
        _ state: DownloadState
    ) -> (@Sendable () async -> Void)? {
        guard let callback = _onStateChanged else { return nil }
        return { [self] in
            await invokeUserCallback(taskID: task.id) {
                await callback(task, state)
            }
        }
    }

    package func prepareCompletedCallback(
        _ task: DownloadTask,
        _ location: URL
    ) -> (@Sendable () async -> Void)? {
        guard let callback = _onCompleted else { return nil }
        return { [self] in
            await invokeUserCallback(taskID: task.id) {
                await callback(task, location)
            }
        }
    }

    package func prepareFailedCallback(
        _ task: DownloadTask,
        _ error: DownloadError
    ) -> (@Sendable () async -> Void)? {
        guard let callback = _onFailed else { return nil }
        return { [self] in
            await invokeUserCallback(taskID: task.id) {
                await callback(task, error)
            }
        }
    }

    private func invokeUserCallback(
        taskID: String,
        _ operation: @Sendable () async -> Void
    ) async {
        let token = DownloadUserCallbackToken(
            managerID: callbackContextID,
            taskID: taskID,
            parent: DownloadUserCallbackContext.token
        )
        await DownloadUserCallbackContext.$token.withValue(token) {
            await operation()
        }
        token.deactivate()
    }

    @discardableResult
    package func add(_ task: DownloadTask) async -> Bool {
        guard await task.claimOwnership(ownershipID) else { return false }
        tasks[task.id] = task
        return true
    }

    package func remove(_ task: DownloadTask) {
        guard let registered = tasks[task.id], registered === task else { return }
        tasks.removeValue(forKey: task.id)
    }

    package func owns(_ task: DownloadTask) async -> Bool {
        await task.isOwned(by: ownershipID)
    }

    package func task(withId id: String) -> DownloadTask? {
        tasks[id]
    }

    package func allTasks() -> [DownloadTask] {
        Array(tasks.values)
    }

    package func setMapping(downloadTask: DownloadTask, for identifier: Int) {
        if let previousIdentifier = taskIdToIdentifier[downloadTask.id],
            previousIdentifier != identifier
        {
            identifierToTask.removeValue(forKey: previousIdentifier)
        }
        if let displacedTask = identifierToTask[identifier], displacedTask !== downloadTask {
            if taskIdToIdentifier[displacedTask.id] == identifier {
                taskIdToIdentifier.removeValue(forKey: displacedTask.id)
            }
            if taskIdToURLTask[displacedTask.id]?.taskIdentifier == identifier {
                taskIdToURLTask.removeValue(forKey: displacedTask.id)
            }
        }
        identifierToTask[identifier] = downloadTask
        taskIdToIdentifier[downloadTask.id] = identifier
    }

    /// Installs the complete logical-task ↔ concrete-attempt relationship in
    /// one actor-isolated operation. Returning the displaced attempt lets the
    /// caller retire its physical URLSession task after the registry has
    /// already made the new attempt authoritative.
    package func register(
        urlTask: any DownloadURLTask,
        for downloadTask: DownloadTask
    ) -> (any DownloadURLTask)? {
        let identifier = urlTask.taskIdentifier
        let displacedURLTask = taskIdToURLTask[downloadTask.id]

        if let previousIdentifier = taskIdToIdentifier[downloadTask.id],
            previousIdentifier != identifier
        {
            identifierToTask.removeValue(forKey: previousIdentifier)
        }
        if let displacedTask = identifierToTask[identifier], displacedTask !== downloadTask {
            if taskIdToIdentifier[displacedTask.id] == identifier {
                taskIdToIdentifier.removeValue(forKey: displacedTask.id)
            }
            if taskIdToURLTask[displacedTask.id]?.taskIdentifier == identifier {
                taskIdToURLTask.removeValue(forKey: displacedTask.id)
            }
        }

        identifierToTask[identifier] = downloadTask
        taskIdToIdentifier[downloadTask.id] = identifier
        taskIdToURLTask[downloadTask.id] = urlTask

        guard displacedURLTask?.taskIdentifier != identifier else { return nil }
        return displacedURLTask
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

    /// Drops only the identifier ↔ task pairing while leaving the
    /// `taskId → URLTask` handle in place. Callers that are also
    /// retiring the URLTask must follow up with
    /// ``removeTaskRuntime(taskId:)`` (or call it instead) to avoid
    /// leaving the URLTask handle pinned in memory.
    package func detachRuntime(taskIdentifier: Int) {
        guard let task = identifierToTask.removeValue(forKey: taskIdentifier) else { return }
        if taskIdToIdentifier[task.id] == taskIdentifier {
            taskIdToIdentifier.removeValue(forKey: task.id)
        }
    }

    /// Removes one concrete URLSession attempt without touching a newer
    /// attempt registered for the same logical download task.
    package func removeAttemptRuntime(taskIdentifier: Int) {
        let mappedTask = identifierToTask.removeValue(forKey: taskIdentifier)
        let taskIDsWithURLTask = taskIdToURLTask.compactMap { taskID, urlTask in
            urlTask.taskIdentifier == taskIdentifier ? taskID : nil
        }
        let affectedTaskIDs = Set(taskIDsWithURLTask + [mappedTask?.id].compactMap { $0 })

        for taskID in affectedTaskIDs {
            if taskIdToIdentifier[taskID] == taskIdentifier {
                taskIdToIdentifier.removeValue(forKey: taskID)
            }
            if taskIdToURLTask[taskID]?.taskIdentifier == taskIdentifier {
                taskIdToURLTask.removeValue(forKey: taskID)
            }
        }
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
