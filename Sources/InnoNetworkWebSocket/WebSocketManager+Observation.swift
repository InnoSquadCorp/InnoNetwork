import Foundation

extension WebSocketManager {
    /// Sets a callback that runs when a socket connects.
    public func setOnConnectedHandler(_ callback: (@Sendable (WebSocketTask, String?) async -> Void)?) async {
        guard !isShutdown else { return }
        await runtimeRegistry.setOnConnected(callback)
    }

    /// Sets a callback that runs when a socket disconnects.
    public func setOnDisconnectedHandler(
        _ callback: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?
    ) async {
        guard !isShutdown else { return }
        await runtimeRegistry.setOnDisconnected(callback)
    }

    /// Sets a callback that runs when binary message data is received.
    public func setOnMessageHandler(_ callback: (@Sendable (WebSocketTask, Data) async -> Void)?) async {
        guard !isShutdown else { return }
        await runtimeRegistry.setOnMessage(callback)
    }

    /// Sets a callback that runs when a text message is received.
    public func setOnStringHandler(_ callback: (@Sendable (WebSocketTask, String) async -> Void)?) async {
        guard !isShutdown else { return }
        await runtimeRegistry.setOnString(callback)
    }

    /// Sets a callback that runs when an operational WebSocket error occurs.
    public func setOnErrorHandler(_ callback: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?) async {
        guard !isShutdown else { return }
        await runtimeRegistry.setOnError(callback)
    }

    /// Sets a callback that runs when a ping's paired pong is observed.
    public func setOnPongHandler(_ callback: (@Sendable (WebSocketTask, WebSocketPongContext) async -> Void)?) async {
        guard !isShutdown else { return }
        await runtimeRegistry.setOnPong(callback)
    }

    public func task(withId id: String) async -> WebSocketTask? {
        await runtimeRegistry.task(withId: id)
    }

    public func allTasks() async -> [WebSocketTask] {
        await runtimeRegistry.allTasks()
    }

    public func activeTasks() async -> [WebSocketTask] {
        var result: [WebSocketTask] = []
        for task in await runtimeRegistry.allTasks() {
            let state = await task.state
            if state == .connected || state == .connecting || state == .reconnecting {
                result.append(task)
            }
        }
        return result
    }

    func runtimeTaskIdentifier(for task: WebSocketTask) async -> Int? {
        await runtimeRegistry.taskIdentifier(for: task.id)
    }

    func listenerCount(for task: WebSocketTask) async -> Int {
        await eventHub.listenerCount(taskID: task.id)
    }

    /// Adds a module-owned event listener for a socket task.
    func addEventListener(
        for task: WebSocketTask,
        listener: @escaping @Sendable (WebSocketEvent) async -> Void
    ) async -> WebSocketEventSubscription {
        guard beginShutdownTrackedOperation() else {
            return WebSocketEventSubscription(taskId: task.id, listenerID: UUID())
        }
        defer { finishShutdownTrackedOperation() }
        guard beginEventConsumerRegistration(taskID: task.id) else {
            return WebSocketEventSubscription(taskId: task.id, listenerID: UUID())
        }
        defer { finishEventConsumerRegistration(taskID: task.id) }
        guard let registeredTask = await runtimeRegistry.task(withId: task.id),
            registeredTask === task,
            !(await task.state.isTerminal)
        else {
            return WebSocketEventSubscription(taskId: task.id, listenerID: UUID())
        }
        let listenerID = await eventHub.addListener(taskID: task.id, listener: listener)
        return WebSocketEventSubscription(taskId: task.id, listenerID: listenerID)
    }

    /// Removes a module-owned event listener using its subscription token.
    func removeEventListener(_ subscription: WebSocketEventSubscription) async {
        await eventHub.removeListener(taskID: subscription.taskId, listenerID: subscription.listenerID)
    }

    /// Creates an `AsyncStream` of WebSocket events for a task.
    public func events(for task: WebSocketTask) async -> AsyncStream<WebSocketEvent> {
        guard beginShutdownTrackedOperation() else {
            return AsyncStream { continuation in continuation.finish() }
        }
        defer { finishShutdownTrackedOperation() }
        guard beginEventConsumerRegistration(taskID: task.id) else {
            return AsyncStream { continuation in continuation.finish() }
        }
        defer { finishEventConsumerRegistration(taskID: task.id) }
        guard let registeredTask = await runtimeRegistry.task(withId: task.id),
            registeredTask === task,
            !(await task.state.isTerminal)
        else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return await eventHub.stream(for: task.id)
    }
}
