import Foundation
import InnoNetwork


public enum WebSocketEvent: Sendable {
    case connected(String?)
    case disconnected(WebSocketError?)
    case message(Data)
    case string(String)
    case pong
    case error(WebSocketError)
}

public struct WebSocketEventSubscription: Hashable, Sendable {
    fileprivate let taskId: String
    fileprivate let listenerID: UUID

    public var id: UUID { listenerID }
}

private enum WebSocketInternalError: Error {
    case pingTimeout
}

private enum ReconnectAction {
    case retry
    case terminal
    case exceeded
}


public final class WebSocketManager: NSObject, Sendable {
    public static let shared = WebSocketManager()

    private let configuration: WebSocketConfiguration
    private let session: URLSession
    private let delegate: WebSocketSessionDelegate
    private let backgroundCompletionStore: BackgroundCompletionStore

    private let storage = WebSocketStorage()

    public init(configuration: WebSocketConfiguration = .default) {
        self.configuration = configuration
        let callbacks = WebSocketSessionDelegateCallbacks()
        let backgroundCompletionStore = BackgroundCompletionStore()
        self.delegate = WebSocketSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore
        )
        self.backgroundCompletionStore = backgroundCompletionStore

        let sessionConfig = configuration.makeURLSessionConfiguration()
        self.session = URLSession(
            configuration: sessionConfig,
            delegate: delegate,
            delegateQueue: nil
        )

        super.init()

        callbacks.setHandlers(
            onConnected: { [weak self] taskIdentifier, protocolName in
                self?.handleConnected(taskIdentifier: taskIdentifier, protocolName: protocolName)
            },
            onDisconnected: { [weak self] taskIdentifier, closeCode, reason in
                self?.handleDisconnected(
                    taskIdentifier: taskIdentifier,
                    closeCode: closeCode,
                    reason: reason
                )
            },
            onError: { [weak self] taskIdentifier, error in
                self?.handleSessionError(taskIdentifier: taskIdentifier, error: error)
            }
        )
    }

    public func setOnConnectedHandler(_ callback: (@Sendable (WebSocketTask, String?) async -> Void)?) async {
        await storage.setOnConnected(callback)
    }

    public func setOnDisconnectedHandler(_ callback: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?) async {
        await storage.setOnDisconnected(callback)
    }

    public func setOnMessageHandler(_ callback: (@Sendable (WebSocketTask, Data) async -> Void)?) async {
        await storage.setOnMessage(callback)
    }

    public func setOnStringHandler(_ callback: (@Sendable (WebSocketTask, String) async -> Void)?) async {
        await storage.setOnString(callback)
    }

    public func setOnErrorHandler(_ callback: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?) async {
        await storage.setOnError(callback)
    }

    @discardableResult
    public func connect(url: URL, subprotocols: [String]? = nil) async -> WebSocketTask {
        let task = WebSocketTask(url: url, subprotocols: subprotocols)
        await storage.add(task)
        await startConnection(task)
        return task
    }

    public func disconnect(_ task: WebSocketTask, closeCode: URLSessionWebSocketTask.CloseCode = .normalClosure) async {
        let state = await task.state
        switch state {
        case .connected, .connecting, .reconnecting:
            break
        case .idle, .disconnecting, .disconnected, .failed:
            return
        }

        await task.setAutoReconnectEnabled(false)
        await storage.cancelHeartbeatTask(for: task.id)
        await task.updateState(.disconnecting)
        let disconnectError: WebSocketError? = nil
        await storage.onDisconnected?(task, disconnectError)

        if let urlTask = await storage.urlTask(for: task.id) {
            urlTask.cancel(with: closeCode, reason: nil)
        } else {
            await task.updateState(.disconnected)
            await task.setCloseCode(closeCode)
            await storage.emitEvent(.disconnected(disconnectError), for: task.id)
            await storage.removeTaskAndListeners(taskId: task.id)
            await storage.remove(task)
            return
        }

        await task.updateState(.disconnected)
        await task.setCloseCode(closeCode)
        await storage.emitEvent(.disconnected(disconnectError), for: task.id)
        await storage.removeTaskAndListeners(taskId: task.id)
        await storage.remove(task)
    }

    public func disconnectAll(closeCode: URLSessionWebSocketTask.CloseCode = .normalClosure) async {
        for task in await storage.allTasks() {
            await disconnect(task, closeCode: closeCode)
        }
    }

    public func retry(_ task: WebSocketTask) async {
        let state = await task.state
        guard state == .failed || state == .disconnected else { return }
        await task.setAutoReconnectEnabled(true)
        await task.reset()
        await startConnection(task)
    }

    public func send(_ task: WebSocketTask, message: Data) async throws {
        guard let urlTask = await storage.urlTask(for: task.id) else {
            throw WebSocketError.disconnected(nil)
        }

        try await urlTask.send(.data(message))
    }

    public func send(_ task: WebSocketTask, string: String) async throws {
        guard let urlTask = await storage.urlTask(for: task.id) else {
            throw WebSocketError.disconnected(nil)
        }

        try await urlTask.send(.string(string))
    }

    public func ping(_ task: WebSocketTask) async throws {
        guard let urlTask = await storage.urlTask(for: task.id) else {
            throw WebSocketError.disconnected(nil)
        }
        try await sendPing(urlTask, timeout: configuration.pongTimeout)
        await storage.emitEvent(.pong, for: task.id)
    }

    public func task(withId id: String) async -> WebSocketTask? {
        await storage.task(withId: id)
    }

    public func allTasks() async -> [WebSocketTask] {
        await storage.allTasks()
    }

    public func activeTasks() async -> [WebSocketTask] {
        var result: [WebSocketTask] = []
        for task in await storage.allTasks() {
            let state = await task.state
            if state == .connected || state == .connecting || state == .reconnecting {
                result.append(task)
            }
        }
        return result
    }

    func runtimeTaskIdentifier(for task: WebSocketTask) async -> Int? {
        await storage.taskIdentifier(for: task.id)
    }

    func listenerCount(for task: WebSocketTask) async -> Int {
        await storage.eventListenerCount(for: task.id)
    }

    public func addEventListener(
        for task: WebSocketTask,
        listener: @escaping @Sendable (WebSocketEvent) -> Void
    ) async -> WebSocketEventSubscription {
        let listenerID = await storage.addEventListener(taskId: task.id, listener: listener)
        return WebSocketEventSubscription(taskId: task.id, listenerID: listenerID)
    }

    public func removeEventListener(_ subscription: WebSocketEventSubscription) async {
        await storage.removeEventListener(taskId: subscription.taskId, listenerID: subscription.listenerID)
    }

    public func events(for task: WebSocketTask) -> AsyncStream<WebSocketEvent> {
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

    public func receive(_ task: WebSocketTask) async throws -> WebSocketEvent {
        guard let urlTask = await storage.urlTask(for: task.id) else {
            throw WebSocketError.disconnected(nil)
        }

        let message = try await urlTask.receive()

        switch message {
        case .string(let string):
            return .string(string)
        case .data(let data):
            return .message(data)
        @unknown default:
            return .message(Data())
        }
    }

    private func startConnection(_ task: WebSocketTask) async {
        await task.setAutoReconnectEnabled(true)
        await task.updateState(.connecting)
        await storage.cancelHeartbeatTask(for: task.id)

        var request = URLRequest(url: task.url)
        request.timeoutInterval = configuration.connectionTimeout

        for (key, value) in configuration.requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let urlTask: URLSessionWebSocketTask
        if let subprotocols = task.subprotocols {
            urlTask = session.webSocketTask(with: request.url!, protocols: subprotocols)
        } else {
            urlTask = session.webSocketTask(with: request.url!)
        }

        await storage.setMapping(webSocketTask: task, for: urlTask.taskIdentifier)
        await storage.setURLTask(urlTask, for: task.id)

        urlTask.resume()
        await listenForMessages(task: task, urlTask: urlTask)
    }

    private func listenForMessages(task: WebSocketTask, urlTask: URLSessionWebSocketTask) async {
        Task {
            do {
                while true {
                    let message = try await urlTask.receive()

                    switch message {
                    case .string(let string):
                        await storage.onString?(task, string)
                        await storage.emitEvent(.string(string), for: task.id)
                    case .data(let data):
                        await storage.onMessage?(task, data)
                        await storage.emitEvent(.message(data), for: task.id)
                    @unknown default:
                        break
                    }
                }
            } catch {
                handleError(taskIdentifier: urlTask.taskIdentifier, error: error)
            }
        }
    }

    private func sendPing(_ urlTask: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            urlTask.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func sendPing(
        _ urlTask: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) async throws {
        guard timeout > 0 else {
            try await sendPing(urlTask)
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await self.sendPing(urlTask)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw WebSocketInternalError.pingTimeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    func handleConnected(taskIdentifier: Int, protocolName: String?) {
        Task {
            guard let task = await storage.webSocketTask(for: taskIdentifier) else { return }

            await task.resetReconnectCount()
            await task.setAutoReconnectEnabled(true)
            await task.setError(nil)
            await task.updateState(.connected)
            await startHeartbeat(for: task)
            await storage.onConnected?(task, protocolName)
            await storage.emitEvent(.connected(protocolName), for: task.id)
        }
    }

    func handleDisconnected(taskIdentifier: Int, closeCode: URLSessionWebSocketTask.CloseCode, reason: String?) {
        Task {
            guard let task = await storage.webSocketTask(for: taskIdentifier) else { return }
            let previousState = await task.state

            let error = makeDisconnectedError(closeCode: closeCode, reason: reason)
            await task.updateState(.disconnected)
            await task.setCloseCode(closeCode)
            await task.setError(error)
            await storage.cancelHeartbeatTask(for: task.id)
            await storage.onDisconnected?(task, error)
            await storage.emitEvent(.disconnected(error), for: task.id)

            let reconnectAction = await reconnectAction(task: task, previousState: previousState)
            switch reconnectAction {
            case .retry:
                await storage.detachRuntime(taskIdentifier: taskIdentifier)
                await attemptReconnect(task: task)
                return
            case .exceeded:
                await task.updateState(.failed)
                await task.setError(.maxReconnectAttemptsExceeded)
                await storage.onError?(task, .maxReconnectAttemptsExceeded)
                await storage.emitEvent(.error(.maxReconnectAttemptsExceeded), for: task.id)
            case .terminal:
                break
            }

            await storage.removeTaskAndListeners(taskId: task.id)
            await storage.remove(task)
        }
    }

    func handleError(taskIdentifier: Int, error: Error) {
        let wsError = mapWebSocketError(error)
        if case .cancelled = wsError {
            return
        }
        handleMappedError(taskIdentifier: taskIdentifier, error: wsError)
    }

    func handleSessionError(taskIdentifier: Int, error: SendableUnderlyingError) {
        guard !isCancelledTransportError(error) else { return }
        let wsError: WebSocketError
        if isTimeoutTransportError(error) {
            wsError = .pingTimeout
        } else {
            wsError = .connectionFailed(error)
        }
        handleMappedError(taskIdentifier: taskIdentifier, error: wsError)
    }

    private func mapWebSocketError(_ error: Error) -> WebSocketError {
        if let internalError = error as? WebSocketInternalError {
            switch internalError {
            case .pingTimeout:
                return .pingTimeout
            }
        }

        if let webSocketError = error as? WebSocketError {
            return webSocketError
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .pingTimeout
            default:
                return .connectionFailed(SendableUnderlyingError(error))
            }
        }

        return .connectionFailed(SendableUnderlyingError(error))
    }

    private func isCancelledTransportError(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    }

    private func isTimeoutTransportError(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == URLError.timedOut.rawValue
    }

    private func handleMappedError(taskIdentifier: Int, error: WebSocketError) {
        Task {
            guard let task = await storage.webSocketTask(for: taskIdentifier) else { return }

            let reconnectAction = await reconnectAction(task: task)
            let finalError: WebSocketError
            switch reconnectAction {
            case .exceeded:
                finalError = .maxReconnectAttemptsExceeded
            case .retry, .terminal:
                finalError = error
            }

            await task.updateState(.failed)
            await task.setError(finalError)
            await storage.cancelHeartbeatTask(for: task.id)
            await storage.onError?(task, finalError)
            await storage.emitEvent(.error(finalError), for: task.id)

            switch reconnectAction {
            case .retry:
                await storage.detachRuntime(taskIdentifier: taskIdentifier)
                await attemptReconnect(task: task)
                return
            case .terminal, .exceeded:
                break
            }

            await storage.removeTaskAndListeners(taskId: task.id)
            await storage.remove(task)
        }
    }

    private func makeDisconnectedError(
        closeCode: URLSessionWebSocketTask.CloseCode,
        reason: String?
    ) -> WebSocketError {
        guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .disconnected(nil)
        }
        return .disconnected(
            SendableUnderlyingError(
                domain: "InnoNetworkWebSocket.CloseReason",
                code: Int(closeCode.rawValue),
                message: reason
            )
        )
    }

    private func reconnectAction(
        task: WebSocketTask,
        previousState: WebSocketState? = nil
    ) async -> ReconnectAction {
        if let previousState, previousState == .disconnecting {
            return .terminal
        }

        guard await task.autoReconnectEnabled else {
            return .terminal
        }

        let reconnectCount = await task.incrementReconnectCount()
        if Self.shouldRetryReconnect(after: reconnectCount, maxReconnectAttempts: configuration.maxReconnectAttempts) {
            return .retry
        }
        return .exceeded
    }

    private func attemptReconnect(task: WebSocketTask) async {
        let reconnectCount = await task.reconnectCount
        let baseDelay = configuration.reconnectDelay * pow(2, Double(reconnectCount - 1))
        let jitter = abs(baseDelay * configuration.reconnectJitterRatio)
        let delay = max(0.0, baseDelay + Double.random(in: (-jitter)...(jitter)))

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        guard await task.autoReconnectEnabled else { return }
        let state = await task.state
        if Self.shouldReconnect(currentState: state, autoReconnectEnabled: true) {
            await task.updateState(.reconnecting)
            await startConnection(task)
        }
    }

    private func startHeartbeat(for task: WebSocketTask) async {
        await storage.cancelHeartbeatTask(for: task.id)
        guard configuration.heartbeatInterval > 0 else { return }
        guard let urlTask = await storage.urlTask(for: task.id) else { return }

        let heartbeatTask = Task { [weak self] in
            guard let self else { return }
            var missedPongs = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(configuration.heartbeatInterval))
                if Task.isCancelled { break }

                let state = await task.state
                if state != .connected { break }

                do {
                    try await sendPing(urlTask, timeout: configuration.pongTimeout)
                    missedPongs = 0
                    await storage.emitEvent(.pong, for: task.id)
                } catch {
                    missedPongs += 1
                    if missedPongs >= configuration.maxMissedPongs {
                        handleError(taskIdentifier: urlTask.taskIdentifier, error: WebSocketInternalError.pingTimeout)
                        break
                    }
                }
            }
        }
        await storage.setHeartbeatTask(heartbeatTask, for: task.id)
    }

    static func shouldReconnect(currentState: WebSocketState, autoReconnectEnabled: Bool) -> Bool {
        guard autoReconnectEnabled else { return false }
        switch currentState {
        case .failed, .disconnected, .reconnecting:
            return true
        case .idle, .connecting, .connected, .disconnecting:
            return false
        }
    }

    static func shouldRetryReconnect(after reconnectCount: Int, maxReconnectAttempts: Int) -> Bool {
        reconnectCount <= maxReconnectAttempts
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


private actor WebSocketStorage {
    private var tasks: [String: WebSocketTask] = [:]
    private var identifierToTask: [Int: WebSocketTask] = [:]
    private var taskIdToURLTask: [String: URLSessionWebSocketTask] = [:]
    private var heartbeatTasks: [String: Task<Void, Never>] = [:]
    private var eventListeners: [String: [UUID: @Sendable (WebSocketEvent) -> Void]] = [:]

    private var _onConnected: (@Sendable (WebSocketTask, String?) async -> Void)?
    private var _onDisconnected: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?
    private var _onMessage: (@Sendable (WebSocketTask, Data) async -> Void)?
    private var _onString: (@Sendable (WebSocketTask, String) async -> Void)?
    private var _onError: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?

    var onConnected: (@Sendable (WebSocketTask, String?) async -> Void)? { _onConnected }
    var onDisconnected: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)? { _onDisconnected }
    var onMessage: (@Sendable (WebSocketTask, Data) async -> Void)? { _onMessage }
    var onString: (@Sendable (WebSocketTask, String) async -> Void)? { _onString }
    var onError: (@Sendable (WebSocketTask, WebSocketError) async -> Void)? { _onError }

    func setOnConnected(_ callback: (@Sendable (WebSocketTask, String?) async -> Void)?) {
        _onConnected = callback
    }

    func setOnDisconnected(_ callback: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?) {
        _onDisconnected = callback
    }

    func setOnMessage(_ callback: (@Sendable (WebSocketTask, Data) async -> Void)?) {
        _onMessage = callback
    }

    func setOnString(_ callback: (@Sendable (WebSocketTask, String) async -> Void)?) {
        _onString = callback
    }

    func setOnError(_ callback: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?) {
        _onError = callback
    }

    func addEventListener(taskId: String, listener: @escaping @Sendable (WebSocketEvent) -> Void) -> UUID {
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

    func emitEvent(_ event: WebSocketEvent, for taskId: String) {
        guard let listeners = eventListeners[taskId] else { return }
        for listener in listeners.values {
            listener(event)
        }
    }

    func add(_ task: WebSocketTask) {
        tasks[task.id] = task
    }

    func remove(_ task: WebSocketTask) {
        tasks.removeValue(forKey: task.id)
    }

    func task(withId id: String) -> WebSocketTask? {
        tasks[id]
    }

    func allTasks() -> [WebSocketTask] {
        Array(tasks.values)
    }

    func setMapping(webSocketTask: WebSocketTask, for identifier: Int) {
        identifierToTask[identifier] = webSocketTask
    }

    func setURLTask(_ urlTask: URLSessionWebSocketTask, for taskId: String) {
        taskIdToURLTask[taskId] = urlTask
    }

    func webSocketTask(for identifier: Int) -> WebSocketTask? {
        identifierToTask[identifier]
    }

    func urlTask(for taskId: String) -> URLSessionWebSocketTask? {
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
        heartbeatTasks[taskId]?.cancel()
        heartbeatTasks.removeValue(forKey: taskId)
    }

    func removeTaskAndListeners(taskId: String) {
        removeTaskRuntime(taskId: taskId)
        eventListeners.removeValue(forKey: taskId)
    }

    func setHeartbeatTask(_ task: Task<Void, Never>, for taskId: String) {
        heartbeatTasks[taskId]?.cancel()
        heartbeatTasks[taskId] = task
    }

    func cancelHeartbeatTask(for taskId: String) {
        heartbeatTasks[taskId]?.cancel()
        heartbeatTasks.removeValue(forKey: taskId)
    }
}
