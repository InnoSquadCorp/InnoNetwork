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

/// Actor-owned logical-task and transport mappings.
///
/// Keeping these tables in one value makes their consistency boundary
/// explicit without introducing another actor hop. `WebSocketRuntimeRegistry`
/// remains the sole synchronization owner.
private struct WebSocketTaskRuntimeState {
    var tasks: [String: WebSocketTask] = [:]
    var identifierToTask: [Int: WebSocketTask] = [:]
    var identifierToGeneration: [Int: Int] = [:]
    var taskIDToIdentifier: [String: Int] = [:]
    var taskIDToURLTask: [String: any WebSocketURLTask] = [:]
    var shutdownStarted = false

    mutating func detachRuntime(taskID: String) -> (any WebSocketURLTask)? {
        let urlTask = taskIDToURLTask.removeValue(forKey: taskID)
        if let identifier = taskIDToIdentifier.removeValue(forKey: taskID) {
            identifierToTask.removeValue(forKey: identifier)
            identifierToGeneration.removeValue(forKey: identifier)
        } else {
            let staleIdentifiers = identifierToTask.compactMap { identifier, task in
                task.id == taskID ? identifier : nil
            }
            for identifier in staleIdentifiers {
                identifierToTask.removeValue(forKey: identifier)
                identifierToGeneration.removeValue(forKey: identifier)
            }
            taskIDToIdentifier.removeValue(forKey: taskID)
        }
        return urlTask
    }
}

/// Actor-owned generation-scoped worker slots.
private struct WebSocketWorkerState {
    var heartbeat: [String: WebSocketRuntimeWorker] = [:]
    var messageListener: [String: WebSocketRuntimeWorker] = [:]
    var reconnect: [String: WebSocketRuntimeWorker] = [:]
    var closeHandshake: [String: WebSocketRuntimeWorker] = [:]

    mutating func detachAll(for taskID: String) -> [WebSocketRuntimeWorker] {
        [
            heartbeat.removeValue(forKey: taskID),
            messageListener.removeValue(forKey: taskID),
            reconnect.removeValue(forKey: taskID),
            closeHandshake.removeValue(forKey: taskID),
        ].compactMap { $0 }
    }
}

/// Actor-owned callback handlers and their shutdown-drain bookkeeping.
private struct WebSocketCallbackDrainState {
    var onConnected: (@Sendable (WebSocketTask, String?) async -> Void)?
    var onDisconnected: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?
    var onMessage: (@Sendable (WebSocketTask, Data) async -> Void)?
    var onString: (@Sendable (WebSocketTask, String) async -> Void)?
    var onError: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?
    var onPong: (@Sendable (WebSocketTask, WebSocketPongContext) async -> Void)?
    var activeCount = 0
    var activeRuntimeWorkerCounts: [UUID: Int] = [:]
    var waiters: [CheckedContinuation<Void, Never>] = []
    var registrationClosed = false

    mutating func clearHandlers() {
        registrationClosed = true
        onConnected = nil
        onDisconnected = nil
        onMessage = nil
        onString = nil
        onError = nil
        onPong = nil
    }
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

    private var runtime = WebSocketTaskRuntimeState()
    private var workers = WebSocketWorkerState()
    private var callbacks = WebSocketCallbackDrainState()

    package init() {}

    package func setOnConnected(_ callback: (@Sendable (WebSocketTask, String?) async -> Void)?) {
        guard !callbacks.registrationClosed else { return }
        callbacks.onConnected = callback
    }

    package func setOnDisconnected(_ callback: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?) {
        guard !callbacks.registrationClosed else { return }
        callbacks.onDisconnected = callback
    }

    package func setOnMessage(_ callback: (@Sendable (WebSocketTask, Data) async -> Void)?) {
        guard !callbacks.registrationClosed else { return }
        callbacks.onMessage = callback
    }

    package func setOnString(_ callback: (@Sendable (WebSocketTask, String) async -> Void)?) {
        guard !callbacks.registrationClosed else { return }
        callbacks.onString = callback
    }

    package func setOnError(_ callback: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?) {
        guard !callbacks.registrationClosed else { return }
        callbacks.onError = callback
    }

    package func setOnPong(_ callback: (@Sendable (WebSocketTask, WebSocketPongContext) async -> Void)?) {
        guard !callbacks.registrationClosed else { return }
        callbacks.onPong = callback
    }

    package func notifyError(_ task: WebSocketTask, error: WebSocketError) async {
        guard let callback = callbacks.onError else { return }
        await invokeUserCallback {
            await callback(task, error)
        }
    }

    package func notifyPong(_ task: WebSocketTask, context: WebSocketPongContext) async {
        guard let callback = callbacks.onPong else { return }
        await invokeUserCallback {
            await callback(task, context)
        }
    }

    func prepareConnectedCallback(
        _ task: WebSocketTask,
        protocolName: String?
    ) -> WebSocketPreparedUserCallback? {
        callbacks.onConnected.map { callback in
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
        callbacks.onDisconnected.map { callback in
            prepareUserCallback {
                await callback(task, error)
            }
        }
    }

    func prepareErrorCallback(
        _ task: WebSocketTask,
        error: WebSocketError
    ) -> WebSocketPreparedUserCallback? {
        callbacks.onError.map { callback in
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
        callbacks.onPong.map { callback in
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
            workers.messageListener[task.id]?.id == workerID
        else {
            return WebSocketPreparedWorkerCallback(
                isCurrentWorker: false,
                callback: nil
            )
        }
        let callback = callbacks.onMessage.map { callback in
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
            workers.messageListener[task.id]?.id == workerID
        else {
            return WebSocketPreparedWorkerCallback(
                isCurrentWorker: false,
                callback: nil
            )
        }
        let callback = callbacks.onString.map { callback in
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
            workers.heartbeat[task.id]?.id == workerID
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
        return workers.heartbeat[taskID]?.id == workerID
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
        guard callbacks.activeCount > 0 else { return }
        await withCheckedContinuation { continuation in
            callbacks.waiters.append(continuation)
        }
    }

    /// Runs a manager-owned callback inside this manager's reentrancy context
    /// and contributes it to the shutdown drain. This boundary covers the
    /// `setOn...Handler` callbacks and handshake adapters. Task event listeners
    /// retain `TaskEventHub`'s configured asynchronous delivery semantics.
    package func invokeUserCallback<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async rethrows -> Result {
        let admission = admitUserCallback()
        do {
            let result = try await WebSocketRuntimeWorkerContext.$workerID.withValue(nil) {
                try await WebSocketUserCallbackContext.$token.withValue(admission.token) {
                    try await operation()
                }
            }
            finishUserCallback(admission)
            return result
        } catch {
            // Throwing handshake adapters are still admitted user callbacks.
            // Always release their admission so shutdown cannot wait forever
            // for a callback that already unwound with an error.
            finishUserCallback(admission)
            throw error
        }
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
        callbacks.activeCount += 1
        let runtimeWorkerID = WebSocketRuntimeWorkerContext.currentWorkerID
        if let runtimeWorkerID {
            callbacks.activeRuntimeWorkerCounts[runtimeWorkerID, default: 0] += 1
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
        callbacks.activeCount -= 1
        if let runtimeWorkerID = admission.runtimeWorkerID,
            let count = callbacks.activeRuntimeWorkerCounts[runtimeWorkerID]
        {
            if count > 1 {
                callbacks.activeRuntimeWorkerCounts[runtimeWorkerID] = count - 1
            } else {
                callbacks.activeRuntimeWorkerCounts.removeValue(forKey: runtimeWorkerID)
            }
        }

        if callbacks.activeCount == 0 {
            let waiters = callbacks.waiters
            callbacks.waiters.removeAll(keepingCapacity: false)
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
        guard !runtime.shutdownStarted else { return false }
        runtime.tasks[task.id] = task
        return true
    }

    package func remove(_ task: WebSocketTask) {
        runtime.tasks.removeValue(forKey: task.id)
    }

    package func task(withId id: String) -> WebSocketTask? {
        runtime.tasks[id]
    }

    package func allTasks() -> [WebSocketTask] {
        Array(runtime.tasks.values)
    }

    /// Marks the registry as shutting down and returns the current task
    /// snapshot in a single actor hop, so subsequent `add(_:)` calls cannot
    /// race past the snapshot.
    package func markShutdownStartedAndSnapshot() -> [WebSocketTask] {
        runtime.shutdownStarted = true
        return Array(runtime.tasks.values)
    }

    package func setMapping(webSocketTask: WebSocketTask, for identifier: Int, generation: Int) {
        runtime.identifierToTask[identifier] = webSocketTask
        runtime.identifierToGeneration[identifier] = generation
        runtime.taskIDToIdentifier[webSocketTask.id] = identifier
    }

    package func setURLTask(_ urlTask: any WebSocketURLTask, for taskId: String) {
        runtime.taskIDToURLTask[taskId] = urlTask
    }

    package func webSocketTask(for identifier: Int) -> WebSocketTask? {
        runtime.identifierToTask[identifier]
    }

    /// Snapshots the logical task and transport generation for one delegate
    /// identifier in a single actor hop. A callback whose mapping has already
    /// been detached is stale and must be dropped rather than rebound to the
    /// task's current generation.
    package func callbackContext(for identifier: Int) -> WebSocketRuntimeCallbackContext? {
        guard let task = runtime.identifierToTask[identifier],
            let generation = runtime.identifierToGeneration[identifier]
        else { return nil }
        return WebSocketRuntimeCallbackContext(task: task, generation: generation)
    }

    package func matchesCallbackContext(
        _ context: WebSocketRuntimeCallbackContext,
        for identifier: Int
    ) -> Bool {
        runtime.identifierToTask[identifier] === context.task
            && runtime.identifierToGeneration[identifier] == context.generation
    }

    package func urlTask(for taskId: String) -> (any WebSocketURLTask)? {
        runtime.taskIDToURLTask[taskId]
    }

    package func taskIdentifier(for taskId: String) -> Int? {
        runtime.taskIDToIdentifier[taskId]
    }

    package func removeTaskRuntime(taskId: String) async {
        let urlTask = runtime.detachRuntime(taskID: taskId)

        // Detach every generation-scoped worker before the first suspension.
        // A retry may install a fresh runtime while cancellation of the old
        // workers is still unwinding; retaining dictionary lookups across
        // those awaits could otherwise remove the newly installed workers.
        let detachedWorkers = workers.detachAll(for: taskId)

        urlTask?.cancel()
        for worker in detachedWorkers {
            worker.task.cancel()
        }

        await withTaskGroup(of: Void.self) { group in
            for worker in detachedWorkers.filter(shouldAwaitWorker) {
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
        if let previousTask = workers.heartbeat[taskId] {
            previousTask.task.cancel()
            if shouldAwaitWorker(previousTask) {
                await previousTask.task.value
            }
        }
        workers.heartbeat[taskId] = WebSocketRuntimeWorker(id: workerID, task: task)
    }

    package func cancelHeartbeatTask(for taskId: String) async {
        guard let heartbeatTask = workers.heartbeat.removeValue(forKey: taskId) else { return }
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
        if let previousTask = workers.messageListener[taskId] {
            previousTask.task.cancel()
            if shouldAwaitWorker(previousTask) {
                await previousTask.task.value
            }
        }
        workers.messageListener[taskId] = WebSocketRuntimeWorker(id: workerID, task: task)
    }

    package func createMessageListenerTask(
        for taskId: String,
        operation: @escaping @Sendable () async -> Void
    ) async {
        if let previousTask = workers.messageListener[taskId] {
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
        workers.messageListener[taskId] = WebSocketRuntimeWorker(id: workerID, task: listenerTask)
    }

    package func cancelMessageListenerTask(for taskId: String) async {
        guard let listenerTask = workers.messageListener.removeValue(forKey: taskId) else { return }
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
        if let previousTask = workers.reconnect[taskId] {
            previousTask.task.cancel()
            if shouldAwaitWorker(previousTask) {
                await previousTask.task.value
            }
        }
        workers.reconnect[taskId] = WebSocketRuntimeWorker(id: workerID, task: task)
    }

    package func cancelReconnectTask(for taskId: String) async {
        guard let reconnectTask = workers.reconnect.removeValue(forKey: taskId) else { return }
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
        guard runtime.taskIDToURLTask[taskId] != nil else {
            task.cancel()
            await task.value
            return
        }
        if let previousTask = workers.closeHandshake[taskId] {
            previousTask.task.cancel()
            if shouldAwaitWorker(previousTask) {
                await previousTask.task.value
            }
        }
        workers.closeHandshake[taskId] = WebSocketRuntimeWorker(id: workerID, task: task)
    }

    package func cancelCloseHandshakeTask(for taskId: String) async {
        guard let closeTask = workers.closeHandshake.removeValue(forKey: taskId) else { return }
        closeTask.task.cancel()
        if shouldAwaitWorker(closeTask) {
            await closeTask.task.value
        }
    }

    package func clearCloseHandshakeTask(for taskId: String) {
        guard let closeTask = workers.closeHandshake[taskId],
            closeTask.id == WebSocketRuntimeWorkerContext.currentWorkerID
        else { return }
        workers.closeHandshake.removeValue(forKey: taskId)
    }

    /// Runtime teardown must not await a worker whose active user callback is
    /// waiting to enter the same lifecycle gate. The worker has already been
    /// detached and cancelled before this check; receive/heartbeat loops test
    /// cancellation after the callback and cannot publish into a new runtime.
    private func shouldAwaitWorker(_ worker: WebSocketRuntimeWorker) -> Bool {
        worker.id != WebSocketRuntimeWorkerContext.currentWorkerID
            && callbacks.activeRuntimeWorkerCounts[worker.id] == nil
    }

    package func clearCallbacks() {
        callbacks.clearHandlers()
    }
}
