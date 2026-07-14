import Foundation
import os

/// Marks execution inside a public WebSocket callback.
///
/// A callback can legitimately initiate manager shutdown. The marker lets
/// `WebSocketManager.shutdown()` avoid awaiting the worker that is currently
/// invoking it; an external shutdown caller still waits for full teardown.
enum WebSocketUserCallbackContext {
    @TaskLocal static var token: WebSocketUserCallbackToken?
}

/// A TaskLocal value is inherited by unstructured child tasks. Keeping the
/// callback's active lifetime in shared lock-backed storage means a child that
/// outlives its handler stops being classified as reentrant as soon as the
/// handler returns.
final class WebSocketUserCallbackToken: Sendable {
    let managerID: UUID
    let runtimeWorkerID: UUID?
    let parent: WebSocketUserCallbackToken?
    private let active = OSAllocatedUnfairLock<Bool>(initialState: true)

    init(managerID: UUID, runtimeWorkerID: UUID?, parent: WebSocketUserCallbackToken?) {
        self.managerID = managerID
        self.runtimeWorkerID = runtimeWorkerID
        self.parent = parent
    }

    var isActive: Bool {
        active.withLock { $0 }
    }

    func deactivate() {
        active.withLock { $0 = false }
    }

    func containsActiveCallback(for managerID: UUID) -> Bool {
        var candidate: WebSocketUserCallbackToken? = self
        while let token = candidate {
            if token.managerID == managerID, token.isActive {
                return true
            }
            candidate = token.parent
        }
        return false
    }

    func firstActiveRuntimeWorkerID() -> UUID? {
        var candidate: WebSocketUserCallbackToken? = self
        while let token = candidate {
            if token.isActive, let runtimeWorkerID = token.runtimeWorkerID {
                return runtimeWorkerID
            }
            candidate = token.parent
        }
        return nil
    }

}

enum WebSocketRuntimeWorkerContext {
    @TaskLocal static var workerID: UUID?
    @TaskLocal static var selfDrainDisabled = false

    static var currentWorkerID: UUID? {
        guard !selfDrainDisabled else { return nil }
        return workerID ?? WebSocketUserCallbackContext.token?.firstActiveRuntimeWorkerID()
    }
}

private struct WebSocketRuntimeWorker {
    let id: UUID
    let task: Task<Void, Never>
}

package struct WebSocketRuntimeCallbackContext: Sendable {
    package let task: WebSocketTask
    package let generation: Int
}

private struct WebSocketUserCallbackAdmission: Sendable {
    let token: WebSocketUserCallbackToken
    let runtimeWorkerID: UUID?
}

struct WebSocketPreparedUserCallback: Sendable {
    fileprivate let admission: WebSocketUserCallbackAdmission
    fileprivate let operation: @Sendable () async -> Void
}

struct WebSocketPreparedWorkerCallback: Sendable {
    let isCurrentWorker: Bool
    let callback: WebSocketPreparedUserCallback?
}

package actor WebSocketRuntimeRegistry {
    /// Distinguishes callback reentrancy for this manager from callbacks that
    /// happen to be running for another WebSocketManager on the same task.
    package nonisolated let callbackContextID = UUID()

    private var tasks: [String: WebSocketTask] = [:]
    private var identifierToTask: [Int: WebSocketTask] = [:]
    private var identifierToGeneration: [Int: Int] = [:]
    private var taskIdToIdentifier: [String: Int] = [:]
    private var taskIdToURLTask: [String: any WebSocketURLTask] = [:]
    private var heartbeatTasks: [String: WebSocketRuntimeWorker] = [:]
    private var messageListenerTasks: [String: WebSocketRuntimeWorker] = [:]
    private var reconnectTasks: [String: WebSocketRuntimeWorker] = [:]
    private var closeHandshakeTasks: [String: WebSocketRuntimeWorker] = [:]
    /// Set when ``markShutdownStartedAndSnapshot()`` runs. Once true, ``add(_:)``
    /// refuses new task registrations so concurrent `connect()`/`retry()` callers
    /// cannot leak orphan tasks past the terminal cleanup sweep performed by
    /// `WebSocketManager.shutdown()`.
    private var shutdownStarted = false

    private var _onConnected: (@Sendable (WebSocketTask, String?) async -> Void)?
    private var _onDisconnected: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?
    private var _onMessage: (@Sendable (WebSocketTask, Data) async -> Void)?
    private var _onString: (@Sendable (WebSocketTask, String) async -> Void)?
    private var _onError: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?
    private var _onPong: (@Sendable (WebSocketTask, WebSocketPongContext) async -> Void)?
    private var activeUserCallbackCount = 0
    private var activeUserCallbackRuntimeWorkerCounts: [UUID: Int] = [:]
    private var userCallbackDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var callbackRegistrationClosed = false

    package init() {}

    package func setOnConnected(_ callback: (@Sendable (WebSocketTask, String?) async -> Void)?) {
        guard !callbackRegistrationClosed else { return }
        _onConnected = callback
    }

    package func setOnDisconnected(_ callback: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?) {
        guard !callbackRegistrationClosed else { return }
        _onDisconnected = callback
    }

    package func setOnMessage(_ callback: (@Sendable (WebSocketTask, Data) async -> Void)?) {
        guard !callbackRegistrationClosed else { return }
        _onMessage = callback
    }

    package func setOnString(_ callback: (@Sendable (WebSocketTask, String) async -> Void)?) {
        guard !callbackRegistrationClosed else { return }
        _onString = callback
    }

    package func setOnError(_ callback: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?) {
        guard !callbackRegistrationClosed else { return }
        _onError = callback
    }

    package func setOnPong(_ callback: (@Sendable (WebSocketTask, WebSocketPongContext) async -> Void)?) {
        guard !callbackRegistrationClosed else { return }
        _onPong = callback
    }

    package func notifyError(_ task: WebSocketTask, error: WebSocketError) async {
        guard let callback = _onError else { return }
        await invokeUserCallback {
            await callback(task, error)
        }
    }

    package func notifyPong(_ task: WebSocketTask, context: WebSocketPongContext) async {
        guard let callback = _onPong else { return }
        await invokeUserCallback {
            await callback(task, context)
        }
    }

    func prepareConnectedCallback(
        _ task: WebSocketTask,
        protocolName: String?
    ) -> WebSocketPreparedUserCallback? {
        _onConnected.map { callback in
            prepareUserCallback {
                await callback(task, protocolName)
            }
        }
    }

    /// Snapshots and admits lifecycle handlers while their source transition
    /// is still linearized. A handler installed after event admission must not
    /// receive historical work from that transition.
    func prepareDisconnectedCallback(
        _ task: WebSocketTask,
        error: WebSocketError?
    ) -> WebSocketPreparedUserCallback? {
        _onDisconnected.map { callback in
            prepareUserCallback {
                await callback(task, error)
            }
        }
    }

    func prepareErrorCallback(
        _ task: WebSocketTask,
        error: WebSocketError
    ) -> WebSocketPreparedUserCallback? {
        _onError.map { callback in
            prepareUserCallback {
                await callback(task, error)
            }
        }
    }

    /// Snapshots and admits the pong handler at the same linearization point
    /// as its paired event. A later registration must not receive a pong that
    /// was already observed from the transport.
    func preparePongCallback(
        _ task: WebSocketTask,
        context: WebSocketPongContext
    ) -> WebSocketPreparedUserCallback? {
        _onPong.map { callback in
            prepareUserCallback {
                await callback(task, context)
            }
        }
    }

    /// Atomically verifies that a receive-loop worker is still the registered
    /// worker for `task`, then admits its user callback before the actor can
    /// service terminal runtime detachment. If teardown won first, the stale
    /// callback is suppressed. If admission won, teardown sees the active
    /// worker marker and never waits on a callback that may await retry.
    func prepareMessageCallbackFromCurrentWorker(
        _ task: WebSocketTask,
        data: Data
    ) -> WebSocketPreparedUserCallback? {
        prepareMessageEventFromCurrentWorker(task, data: data).callback
    }

    func prepareMessageEventFromCurrentWorker(
        _ task: WebSocketTask,
        data: Data
    ) -> WebSocketPreparedWorkerCallback {
        guard let workerID = WebSocketRuntimeWorkerContext.currentWorkerID,
            messageListenerTasks[task.id]?.id == workerID
        else {
            return WebSocketPreparedWorkerCallback(
                isCurrentWorker: false,
                callback: nil
            )
        }
        let callback = _onMessage.map { callback in
            prepareUserCallback {
                await callback(task, data)
            }
        }
        return WebSocketPreparedWorkerCallback(
            isCurrentWorker: true,
            callback: callback
        )
    }

    func prepareStringEventFromCurrentWorker(
        _ task: WebSocketTask,
        string: String
    ) -> WebSocketPreparedWorkerCallback {
        guard let workerID = WebSocketRuntimeWorkerContext.currentWorkerID,
            messageListenerTasks[task.id]?.id == workerID
        else {
            return WebSocketPreparedWorkerCallback(
                isCurrentWorker: false,
                callback: nil
            )
        }
        let callback = _onString.map { callback in
            prepareUserCallback {
                await callback(task, string)
            }
        }
        return WebSocketPreparedWorkerCallback(
            isCurrentWorker: true,
            callback: callback
        )
    }

    /// Admits the heartbeat callback while the manager still owns the task's
    /// lifecycle gate. The paired event can then be enqueued before the gate
    /// is released, while terminal cleanup can identify and avoid self-drain
    /// if the callback subsequently awaits `retry(_:)`.
    func preparePongCallbackFromCurrentHeartbeatWorker(
        _ task: WebSocketTask,
        context: WebSocketPongContext
    ) -> WebSocketPreparedWorkerCallback {
        guard let workerID = WebSocketRuntimeWorkerContext.currentWorkerID,
            heartbeatTasks[task.id]?.id == workerID
        else {
            return WebSocketPreparedWorkerCallback(
                isCurrentWorker: false,
                callback: nil
            )
        }
        return WebSocketPreparedWorkerCallback(
            isCurrentWorker: true,
            callback: preparePongCallback(task, context: context)
        )
    }

    /// Returns whether the caller is still the heartbeat worker registered for
    /// this logical task. Heartbeat event publication uses this check while the
    /// manager owns the task lifecycle gate, so a detached generation cannot
    /// publish into the task's current event partition.
    func isCurrentHeartbeatWorker(for taskID: String) -> Bool {
        guard let workerID = WebSocketRuntimeWorkerContext.currentWorkerID else {
            return false
        }
        return heartbeatTasks[taskID]?.id == workerID
    }

    func invokePreparedUserCallback(_ prepared: WebSocketPreparedUserCallback?) async {
        guard let prepared else { return }
        // Runtime teardown cancels the worker before deciding whether it can
        // await that worker. Run the already-admitted callback in a fresh,
        // uncancelled lane so an explicit `await retry(_:)` or `disconnect(_:)`
        // observes its own API contract instead of inheriting an internal
        // worker's cancellation bit. The token retains the original worker ID,
        // so teardown still recognizes and avoids the self-drain edge.
        let callbackTask = Task.detached {
            await WebSocketRuntimeWorkerContext.$workerID.withValue(nil) {
                await WebSocketUserCallbackContext.$token.withValue(prepared.admission.token) {
                    await prepared.operation()
                }
            }
        }
        await callbackTask.value
        finishUserCallback(prepared.admission)
    }

    /// Waits for callbacks that were admitted before `clearCallbacks()` to
    /// return. Notifications that reach the registry after clearing observe a
    /// nil handler and never increment the active count.
    package func waitForUserCallbacksToDrain() async {
        guard activeUserCallbackCount > 0 else { return }
        await withCheckedContinuation { continuation in
            userCallbackDrainWaiters.append(continuation)
        }
    }

    /// Runs a manager-owned callback inside this manager's reentrancy context
    /// and contributes it to the shutdown drain. This boundary covers the
    /// `setOn...Handler` callbacks and handshake adapters. Task event listeners
    /// retain `TaskEventHub`'s configured asynchronous delivery semantics.
    package func invokeUserCallback<Result: Sendable>(
        _ operation: @escaping @Sendable () async -> Result
    ) async -> Result {
        let admission = admitUserCallback()
        let result = await WebSocketRuntimeWorkerContext.$workerID.withValue(nil) {
            await WebSocketUserCallbackContext.$token.withValue(admission.token) {
                await operation()
            }
        }
        finishUserCallback(admission)
        return result
    }

    private func prepareUserCallback(
        _ operation: @escaping @Sendable () async -> Void
    ) -> WebSocketPreparedUserCallback {
        WebSocketPreparedUserCallback(
            admission: admitUserCallback(),
            operation: operation
        )
    }

    private func admitUserCallback() -> WebSocketUserCallbackAdmission {
        activeUserCallbackCount += 1
        let runtimeWorkerID = WebSocketRuntimeWorkerContext.currentWorkerID
        if let runtimeWorkerID {
            activeUserCallbackRuntimeWorkerCounts[runtimeWorkerID, default: 0] += 1
        }
        return WebSocketUserCallbackAdmission(
            token: WebSocketUserCallbackToken(
                managerID: callbackContextID,
                runtimeWorkerID: runtimeWorkerID,
                parent: WebSocketUserCallbackContext.token
            ),
            runtimeWorkerID: runtimeWorkerID
        )
    }

    private func finishUserCallback(_ admission: WebSocketUserCallbackAdmission) {
        admission.token.deactivate()
        activeUserCallbackCount -= 1
        if let runtimeWorkerID = admission.runtimeWorkerID,
            let count = activeUserCallbackRuntimeWorkerCounts[runtimeWorkerID]
        {
            if count > 1 {
                activeUserCallbackRuntimeWorkerCounts[runtimeWorkerID] = count - 1
            } else {
                activeUserCallbackRuntimeWorkerCounts.removeValue(forKey: runtimeWorkerID)
            }
        }

        if activeUserCallbackCount == 0 {
            let waiters = userCallbackDrainWaiters
            userCallbackDrainWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// Adds `task` to the registry unless shutdown has started, in which case
    /// the registration is refused and the caller is responsible for failing
    /// the task with a manager-shutdown error.
    ///
    /// - Returns: `true` if the task was registered, `false` if shutdown has
    ///   already started.
    @discardableResult
    package func add(_ task: WebSocketTask) -> Bool {
        guard !shutdownStarted else { return false }
        tasks[task.id] = task
        return true
    }

    package func remove(_ task: WebSocketTask) {
        tasks.removeValue(forKey: task.id)
    }

    package func task(withId id: String) -> WebSocketTask? {
        tasks[id]
    }

    package func allTasks() -> [WebSocketTask] {
        Array(tasks.values)
    }

    /// Marks the registry as shutting down and returns the current task
    /// snapshot in a single actor hop, so subsequent `add(_:)` calls cannot
    /// race past the snapshot.
    package func markShutdownStartedAndSnapshot() -> [WebSocketTask] {
        shutdownStarted = true
        return Array(tasks.values)
    }

    /// Resets every task-scoped collection so no phantom mappings or
    /// background coordinators outlive the wipe. Background coordinator
    /// tasks (heartbeat / message listener / reconnect / close handshake)
    /// are dropped without awaiting cancellation; callers that need
    /// awaited cleanup must use `removeTaskRuntime(taskId:)` per task
    /// before this method.
    package func removeAllTasks() {
        tasks.removeAll(keepingCapacity: false)
        identifierToTask.removeAll(keepingCapacity: false)
        identifierToGeneration.removeAll(keepingCapacity: false)
        taskIdToIdentifier.removeAll(keepingCapacity: false)
        taskIdToURLTask.removeAll(keepingCapacity: false)
        for worker in heartbeatTasks.values { worker.task.cancel() }
        heartbeatTasks.removeAll(keepingCapacity: false)
        for worker in messageListenerTasks.values { worker.task.cancel() }
        messageListenerTasks.removeAll(keepingCapacity: false)
        for worker in reconnectTasks.values { worker.task.cancel() }
        reconnectTasks.removeAll(keepingCapacity: false)
        for worker in closeHandshakeTasks.values { worker.task.cancel() }
        closeHandshakeTasks.removeAll(keepingCapacity: false)
    }

    package func setMapping(webSocketTask: WebSocketTask, for identifier: Int, generation: Int) {
        identifierToTask[identifier] = webSocketTask
        identifierToGeneration[identifier] = generation
        taskIdToIdentifier[webSocketTask.id] = identifier
    }

    package func setURLTask(_ urlTask: any WebSocketURLTask, for taskId: String) {
        taskIdToURLTask[taskId] = urlTask
    }

    package func webSocketTask(for identifier: Int) -> WebSocketTask? {
        identifierToTask[identifier]
    }

    /// Snapshots the logical task and transport generation for one delegate
    /// identifier in a single actor hop. A callback whose mapping has already
    /// been detached is stale and must be dropped rather than rebound to the
    /// task's current generation.
    package func callbackContext(for identifier: Int) -> WebSocketRuntimeCallbackContext? {
        guard let task = identifierToTask[identifier],
            let generation = identifierToGeneration[identifier]
        else { return nil }
        return WebSocketRuntimeCallbackContext(task: task, generation: generation)
    }

    package func matchesCallbackContext(
        _ context: WebSocketRuntimeCallbackContext,
        for identifier: Int
    ) -> Bool {
        identifierToTask[identifier] === context.task
            && identifierToGeneration[identifier] == context.generation
    }

    package func urlTask(for taskId: String) -> (any WebSocketURLTask)? {
        taskIdToURLTask[taskId]
    }

    package func taskIdentifier(for taskId: String) -> Int? {
        taskIdToIdentifier[taskId]
    }

    package func detachRuntime(taskIdentifier: Int) {
        guard let task = identifierToTask.removeValue(forKey: taskIdentifier) else { return }
        identifierToGeneration.removeValue(forKey: taskIdentifier)
        taskIdToIdentifier.removeValue(forKey: task.id)
    }

    package func removeTaskRuntime(taskId: String) async {
        let urlTask = taskIdToURLTask.removeValue(forKey: taskId)
        if let identifier = taskIdToIdentifier.removeValue(forKey: taskId) {
            identifierToTask.removeValue(forKey: identifier)
            identifierToGeneration.removeValue(forKey: identifier)
        } else {
            let staleIdentifiers = identifierToTask.compactMap { identifier, task in
                task.id == taskId ? identifier : nil
            }
            for identifier in staleIdentifiers {
                identifierToTask.removeValue(forKey: identifier)
                identifierToGeneration.removeValue(forKey: identifier)
            }
            taskIdToIdentifier.removeValue(forKey: taskId)
        }

        // Detach every generation-scoped worker before the first suspension.
        // A retry may install a fresh runtime while cancellation of the old
        // workers is still unwinding; retaining dictionary lookups across
        // those awaits could otherwise remove the newly installed workers.
        let heartbeatTask = heartbeatTasks.removeValue(forKey: taskId)
        let messageListenerTask = messageListenerTasks.removeValue(forKey: taskId)
        let reconnectTask = reconnectTasks.removeValue(forKey: taskId)
        let closeHandshakeTask = closeHandshakeTasks.removeValue(forKey: taskId)

        urlTask?.cancel()
        heartbeatTask?.task.cancel()
        messageListenerTask?.task.cancel()
        reconnectTask?.task.cancel()
        closeHandshakeTask?.task.cancel()

        await withTaskGroup(of: Void.self) { group in
            let workers = [heartbeatTask, messageListenerTask, reconnectTask, closeHandshakeTask]
                .compactMap { $0 }
                .filter(shouldAwaitWorker)
            for worker in workers {
                group.addTask {
                    await worker.task.value
                }
            }
            await group.waitForAll()
        }
    }

    package func setHeartbeatTask(
        _ task: Task<Void, Never>,
        workerID: UUID = UUID(),
        for taskId: String
    ) async {
        if let previousTask = heartbeatTasks[taskId] {
            previousTask.task.cancel()
            if shouldAwaitWorker(previousTask) {
                await previousTask.task.value
            }
        }
        heartbeatTasks[taskId] = WebSocketRuntimeWorker(id: workerID, task: task)
    }

    package func cancelHeartbeatTask(for taskId: String) async {
        guard let heartbeatTask = heartbeatTasks.removeValue(forKey: taskId) else { return }
        heartbeatTask.task.cancel()
        if shouldAwaitWorker(heartbeatTask) {
            await heartbeatTask.task.value
        }
    }

    package func setMessageListenerTask(
        _ task: Task<Void, Never>,
        workerID: UUID = UUID(),
        for taskId: String
    ) async {
        if let previousTask = messageListenerTasks[taskId] {
            previousTask.task.cancel()
            if shouldAwaitWorker(previousTask) {
                await previousTask.task.value
            }
        }
        messageListenerTasks[taskId] = WebSocketRuntimeWorker(id: workerID, task: task)
    }

    package func createMessageListenerTask(
        for taskId: String,
        operation: @escaping @Sendable () async -> Void
    ) async {
        if let previousTask = messageListenerTasks[taskId] {
            previousTask.task.cancel()
            if shouldAwaitWorker(previousTask) {
                await previousTask.task.value
            }
        }
        let workerID = UUID()
        let listenerTask = Task {
            await WebSocketRuntimeWorkerContext.$workerID.withValue(workerID) {
                await operation()
            }
        }
        messageListenerTasks[taskId] = WebSocketRuntimeWorker(id: workerID, task: listenerTask)
    }

    package func cancelMessageListenerTask(for taskId: String) async {
        guard let listenerTask = messageListenerTasks.removeValue(forKey: taskId) else { return }
        listenerTask.task.cancel()
        if shouldAwaitWorker(listenerTask) {
            await listenerTask.task.value
        }
    }

    package func setReconnectTask(
        _ task: Task<Void, Never>,
        workerID: UUID = UUID(),
        for taskId: String
    ) async {
        if let previousTask = reconnectTasks[taskId] {
            previousTask.task.cancel()
            if shouldAwaitWorker(previousTask) {
                await previousTask.task.value
            }
        }
        reconnectTasks[taskId] = WebSocketRuntimeWorker(id: workerID, task: task)
    }

    package func cancelReconnectTask(for taskId: String) async {
        guard let reconnectTask = reconnectTasks.removeValue(forKey: taskId) else { return }
        reconnectTask.task.cancel()
        if shouldAwaitWorker(reconnectTask) {
            await reconnectTask.task.value
        }
    }

    package func setCloseHandshakeTask(
        _ task: Task<Void, Never>,
        workerID: UUID = UUID(),
        for taskId: String
    ) async {
        guard taskIdToURLTask[taskId] != nil else {
            task.cancel()
            await task.value
            return
        }
        if let previousTask = closeHandshakeTasks[taskId] {
            previousTask.task.cancel()
            if shouldAwaitWorker(previousTask) {
                await previousTask.task.value
            }
        }
        closeHandshakeTasks[taskId] = WebSocketRuntimeWorker(id: workerID, task: task)
    }

    package func cancelCloseHandshakeTask(for taskId: String) async {
        guard let closeTask = closeHandshakeTasks.removeValue(forKey: taskId) else { return }
        closeTask.task.cancel()
        if shouldAwaitWorker(closeTask) {
            await closeTask.task.value
        }
    }

    package func clearCloseHandshakeTask(for taskId: String) {
        guard let closeTask = closeHandshakeTasks[taskId],
            closeTask.id == WebSocketRuntimeWorkerContext.currentWorkerID
        else { return }
        closeHandshakeTasks.removeValue(forKey: taskId)
    }

    /// Runtime teardown must not await a worker whose active user callback is
    /// waiting to enter the same lifecycle gate. The worker has already been
    /// detached and cancelled before this check; receive/heartbeat loops test
    /// cancellation after the callback and cannot publish into a new runtime.
    private func shouldAwaitWorker(_ worker: WebSocketRuntimeWorker) -> Bool {
        worker.id != WebSocketRuntimeWorkerContext.currentWorkerID
            && activeUserCallbackRuntimeWorkerCounts[worker.id] == nil
    }

    package func clearCallbacks() {
        callbackRegistrationClosed = true
        _onConnected = nil
        _onDisconnected = nil
        _onMessage = nil
        _onString = nil
        _onError = nil
        _onPong = nil
    }
}
