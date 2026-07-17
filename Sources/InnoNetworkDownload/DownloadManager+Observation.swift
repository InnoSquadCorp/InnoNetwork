import Foundation

extension DownloadManager {
    public func setOnProgressHandler(
        _ callback: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?
    ) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        await runtimeRegistry.setOnProgress(callback)
    }

    public func setOnStateChangedHandler(
        _ callback: (@Sendable (DownloadTask, DownloadState) async -> Void)?
    ) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        await runtimeRegistry.setOnStateChanged(callback)
        await drainPendingRestoreCompletionsToHandlers()
        await drainPendingRestoreFailuresToHandlers()
    }

    public func setOnCompletedHandler(
        _ callback: (@Sendable (DownloadTask, URL) async -> Void)?
    ) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        await runtimeRegistry.setOnCompleted(callback)
        await drainPendingRestoreCompletionsToHandlers()
    }

    public func setOnFailedHandler(
        _ callback: (@Sendable (DownloadTask, DownloadError) async -> Void)?
    ) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }
        await runtimeRegistry.setOnFailed(callback)
        await drainPendingRestoreFailuresToHandlers()
    }

    /// Waits until launch restoration has reconciled persisted download tasks
    /// with the background URLSession.
    public func waitForRestoration() async -> Bool {
        await waitForRestore()
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

    func addEventListener(
        for task: DownloadTask,
        listener: @escaping @Sendable (DownloadEvent) async -> Void
    ) async {
        guard await runtimeRegistry.owns(task) else { return }
        _ = await eventHub.addListener(taskID: task.id, listener: listener)
        if !provisionalBackgroundRestoreFailureIDs.contains(task.id),
            let terminal = await task.terminalEvent()
        {
            await eventHub.publishTerminalAndFinish(terminal, for: task.id)
            await acknowledgeRestoredCompletionIfNeeded(taskID: task.id)
        }
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
}
