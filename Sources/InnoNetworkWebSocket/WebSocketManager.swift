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


public final class WebSocketManager: NSObject, Sendable {
    public static let shared = WebSocketManager()

    private let configuration: WebSocketConfiguration
    private let session: URLSession
    private let delegate: WebSocketSessionDelegate

    private let storage = WebSocketStorage()

    public var onConnected: (@Sendable (WebSocketTask, String?) async -> Void)? {
        get { storage.onConnectedSync }
        set { storage.onConnectedSync = newValue }
    }
    public var onDisconnected: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)? {
        get { storage.onDisconnectedSync }
        set { storage.onDisconnectedSync = newValue }
    }
    public var onMessage: (@Sendable (WebSocketTask, Data) async -> Void)? {
        get { storage.onMessageSync }
        set { storage.onMessageSync = newValue }
    }
    public var onString: (@Sendable (WebSocketTask, String) async -> Void)? {
        get { storage.onStringSync }
        set { storage.onStringSync = newValue }
    }
    public var onError: (@Sendable (WebSocketTask, WebSocketError) async -> Void)? {
        get { storage.onErrorSync }
        set { storage.onErrorSync = newValue }
    }

    public init(configuration: WebSocketConfiguration = .default) {
        self.configuration = configuration
        self.delegate = WebSocketSessionDelegate()

        let sessionConfig = configuration.makeURLSessionConfiguration()
        self.session = URLSession(
            configuration: sessionConfig,
            delegate: delegate,
            delegateQueue: nil
        )

        super.init()

        delegate.manager = self
    }

    @discardableResult
    public func connect(url: URL, subprotocols: [String]? = nil) async -> WebSocketTask {
        let task = WebSocketTask(url: url, subprotocols: subprotocols)
        await storage.add(task)
        await startConnection(task)
        return task
    }

    public func disconnect(_ task: WebSocketTask, closeCode: URLSessionWebSocketTask.CloseCode = .normalClosure) async {
        guard await task.state == .connected else { return }

        await task.updateState(.disconnecting)
        await storage.onDisconnected?(task, nil)

        if let urlTask = await storage.urlTask(for: task.id) {
            urlTask.cancel(with: closeCode, reason: nil)
        }

        await task.updateState(.disconnected)
        await task.setCloseCode(closeCode)
        await storage.remove(taskId: task.id)
    }

    public func disconnectAll(closeCode: URLSessionWebSocketTask.CloseCode = .normalClosure) async {
        for task in await storage.allTasks() {
            await disconnect(task, closeCode: closeCode)
        }
    }

    public func retry(_ task: WebSocketTask) async {
        let state = await task.state
        guard state == .failed || state == .disconnected else { return }
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

        try await urlTask.sendPing { error in
            if let error = error {
                Task {
                    await self.handleError(taskIdentifier: urlTask.taskIdentifier, error: error)
                }
            }
        }
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

    public func events(for task: WebSocketTask) -> AsyncStream<WebSocketEvent> {
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
        await task.updateState(.connecting)

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
                await handleError(taskIdentifier: urlTask.taskIdentifier, error: error)
            }
        }
    }

    func handleConnected(taskIdentifier: Int, protocolName: String?) {
        Task {
            guard let task = await storage.webSocketTask(for: taskIdentifier) else { return }

            await task.updateState(.connected)
            await storage.onConnected?(task, protocolName)
            await storage.emitEvent(.connected(protocolName), for: task.id)
        }
    }

    func handleDisconnected(taskIdentifier: Int, closeCode: URLSessionWebSocketTask.CloseCode, reason: String?) {
        Task {
            guard let task = await storage.webSocketTask(for: taskIdentifier) else { return }

            defer {
                Task { await storage.remove(taskIdentifier: taskIdentifier) }
            }

            let error = WebSocketError.disconnected(nil)
            await task.updateState(.disconnected)
            await task.setCloseCode(closeCode)
            await task.setError(error)
            await storage.onDisconnected?(task, error)
            await storage.emitEvent(.disconnected(error), for: task.id)

            let reconnectCount = await task.incrementReconnectCount()
            if reconnectCount < configuration.maxReconnectAttempts {
                await attemptReconnect(task: task)
            }
        }
    }

    func handleError(taskIdentifier: Int, error: Error) {
        Task {
            guard let task = await storage.webSocketTask(for: taskIdentifier) else { return }

            let wsError: WebSocketError
            if let urlError = error as? URLError {
                switch urlError.code {
                case .cancelled:
                    return
                case .timedOut:
                    wsError = .pingTimeout
                default:
                    wsError = .connectionFailed(error)
                }
            } else {
                wsError = .connectionFailed(error)
            }

            await task.updateState(.failed)
            await task.setError(wsError)
            await storage.onError?(task, wsError)
            await storage.emitEvent(.error(wsError), for: task.id)

            let reconnectCount = await task.incrementReconnectCount()
            if reconnectCount < configuration.maxReconnectAttempts {
                await attemptReconnect(task: task)
            }
        }
    }

    private func attemptReconnect(task: WebSocketTask) async {
        let reconnectCount = await task.reconnectCount
        let delay = configuration.reconnectDelay * pow(2, Double(reconnectCount - 1))

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        let state = await task.state
        if state != .disconnected && state != .connected {
            await task.updateState(.reconnecting)
            await startConnection(task)
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


private actor WebSocketStorage {
    private var tasks: [String: WebSocketTask] = [:]
    private var identifierToTask: [Int: WebSocketTask] = [:]
    private var taskIdToURLTask: [String: URLSessionWebSocketTask] = [:]
    private var eventListeners: [String: @Sendable (WebSocketEvent) -> Void] = [:]

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

    nonisolated var onConnectedSync: (@Sendable (WebSocketTask, String?) async -> Void)? {
        get { nil }
        set { Task { await self.setOnConnected(newValue) } }
    }
    nonisolated var onDisconnectedSync: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)? {
        get { nil }
        set { Task { await self.setOnDisconnected(newValue) } }
    }
    nonisolated var onMessageSync: (@Sendable (WebSocketTask, Data) async -> Void)? {
        get { nil }
        set { Task { await self.setOnMessage(newValue) } }
    }
    nonisolated var onStringSync: (@Sendable (WebSocketTask, String) async -> Void)? {
        get { nil }
        set { Task { await self.setOnString(newValue) } }
    }
    nonisolated var onErrorSync: (@Sendable (WebSocketTask, WebSocketError) async -> Void)? {
        get { nil }
        set { Task { await self.setOnError(newValue) } }
    }

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

    func addEventListener(taskId: String, listener: @escaping @Sendable (WebSocketEvent) -> Void) {
        eventListeners[taskId] = listener
    }

    func removeEventListener(taskId: String) {
        eventListeners.removeValue(forKey: taskId)
    }

    func emitEvent(_ event: WebSocketEvent, for taskId: String) {
        eventListeners[taskId]?(event)
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
