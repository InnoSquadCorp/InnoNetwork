import Foundation

package actor WebSocketRuntimeRegistry {
    private var tasks: [String: WebSocketTask] = [:]
    private var identifierToTask: [Int: WebSocketTask] = [:]
    private var identifierToGeneration: [Int: Int] = [:]
    private var taskIdToIdentifier: [String: Int] = [:]
    private var taskIdToURLTask: [String: any WebSocketURLTask] = [:]
    private var heartbeatTasks: [String: Task<Void, Never>] = [:]
    private var messageListenerTasks: [String: Task<Void, Never>] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var closeHandshakeTasks: [String: Task<Void, Never>] = [:]

    private var _onConnected: (@Sendable (WebSocketTask, String?) async -> Void)?
    private var _onDisconnected: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?
    private var _onMessage: (@Sendable (WebSocketTask, Data) async -> Void)?
    private var _onString: (@Sendable (WebSocketTask, String) async -> Void)?
    private var _onError: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?
    private var _onPong: (@Sendable (WebSocketTask, WebSocketPongContext) async -> Void)?

    package var onConnected: (@Sendable (WebSocketTask, String?) async -> Void)? { _onConnected }
    package var onDisconnected: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)? { _onDisconnected }
    package var onMessage: (@Sendable (WebSocketTask, Data) async -> Void)? { _onMessage }
    package var onString: (@Sendable (WebSocketTask, String) async -> Void)? { _onString }
    package var onError: (@Sendable (WebSocketTask, WebSocketError) async -> Void)? { _onError }
    package var onPong: (@Sendable (WebSocketTask, WebSocketPongContext) async -> Void)? { _onPong }

    package init() {}

    package func setOnConnected(_ callback: (@Sendable (WebSocketTask, String?) async -> Void)?) {
        _onConnected = callback
    }

    package func setOnDisconnected(_ callback: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?) {
        _onDisconnected = callback
    }

    package func setOnMessage(_ callback: (@Sendable (WebSocketTask, Data) async -> Void)?) {
        _onMessage = callback
    }

    package func setOnString(_ callback: (@Sendable (WebSocketTask, String) async -> Void)?) {
        _onString = callback
    }

    package func setOnError(_ callback: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?) {
        _onError = callback
    }

    package func setOnPong(_ callback: (@Sendable (WebSocketTask, WebSocketPongContext) async -> Void)?) {
        _onPong = callback
    }

    package func add(_ task: WebSocketTask) {
        tasks[task.id] = task
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

    package func connectionGeneration(for identifier: Int) -> Int? {
        identifierToGeneration[identifier]
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
        urlTask?.cancel()
        await cancelHeartbeatTask(for: taskId)
        await cancelMessageListenerTask(for: taskId)
        await cancelReconnectTask(for: taskId)
        await cancelCloseHandshakeTask(for: taskId)
    }

    package func setHeartbeatTask(_ task: Task<Void, Never>, for taskId: String) async {
        if let previousTask = heartbeatTasks[taskId] {
            previousTask.cancel()
            await previousTask.value
        }
        heartbeatTasks[taskId] = task
    }

    package func cancelHeartbeatTask(for taskId: String) async {
        guard let heartbeatTask = heartbeatTasks.removeValue(forKey: taskId) else { return }
        heartbeatTask.cancel()
        await heartbeatTask.value
    }

    package func setMessageListenerTask(_ task: Task<Void, Never>, for taskId: String) async {
        if let previousTask = messageListenerTasks[taskId] {
            previousTask.cancel()
            await previousTask.value
        }
        messageListenerTasks[taskId] = task
    }

    package func createMessageListenerTask(
        for taskId: String,
        operation: @escaping @Sendable () async -> Void
    ) async {
        if let previousTask = messageListenerTasks[taskId] {
            previousTask.cancel()
            await previousTask.value
        }
        let listenerTask = Task(operation: operation)
        messageListenerTasks[taskId] = listenerTask
    }

    package func cancelMessageListenerTask(for taskId: String) async {
        guard let listenerTask = messageListenerTasks.removeValue(forKey: taskId) else { return }
        listenerTask.cancel()
        await listenerTask.value
    }

    package func setReconnectTask(_ task: Task<Void, Never>, for taskId: String) async {
        if let previousTask = reconnectTasks[taskId] {
            previousTask.cancel()
            await previousTask.value
        }
        reconnectTasks[taskId] = task
    }

    package func cancelReconnectTask(for taskId: String) async {
        guard let reconnectTask = reconnectTasks.removeValue(forKey: taskId) else { return }
        reconnectTask.cancel()
        await reconnectTask.value
    }

    package func setCloseHandshakeTask(_ task: Task<Void, Never>, for taskId: String) async {
        if let previousTask = closeHandshakeTasks[taskId] {
            previousTask.cancel()
            await previousTask.value
        }
        closeHandshakeTasks[taskId] = task
    }

    package func cancelCloseHandshakeTask(for taskId: String) async {
        guard let closeTask = closeHandshakeTasks.removeValue(forKey: taskId) else { return }
        closeTask.cancel()
        await closeTask.value
    }

    package func clearCloseHandshakeTask(for taskId: String) {
        closeHandshakeTasks.removeValue(forKey: taskId)
    }
}
