import Foundation
import Testing
@testable import InnoNetworkWebSocket


@Suite("WebSocket Configuration Tests")
struct WebSocketConfigurationTests {

    @Test("Default configuration has expected values")
    func defaultConfiguration() {
        let config = WebSocketConfiguration.default

        #expect(config.maxConcurrentConnections == 5)
        #expect(config.connectionTimeout == 30)
        #expect(config.heartbeatInterval == 30)
        #expect(config.pongTimeout == 10)
        #expect(config.maxMissedPongs == 1)
        #expect(config.reconnectDelay == 1.0)
        #expect(config.reconnectJitterRatio == 0.2)
        #expect(config.maxReconnectAttempts == 5)
        #expect(config.allowsCellularAccess == true)
    }

    @Test("Custom configuration is applied correctly")
    func customConfiguration() {
        let config = WebSocketConfiguration(
            maxConcurrentConnections: 10,
            connectionTimeout: 60,
            heartbeatInterval: 15,
            pongTimeout: 6,
            maxMissedPongs: 2,
            reconnectDelay: 2.0,
            reconnectJitterRatio: 0.1,
            maxReconnectAttempts: 10,
            allowsCellularAccess: false,
            requestHeaders: ["Authorization": "Bearer token"]
        )

        #expect(config.maxConcurrentConnections == 10)
        #expect(config.connectionTimeout == 60)
        #expect(config.heartbeatInterval == 15)
        #expect(config.pongTimeout == 6)
        #expect(config.maxMissedPongs == 2)
        #expect(config.reconnectDelay == 2.0)
        #expect(config.reconnectJitterRatio == 0.1)
        #expect(config.maxReconnectAttempts == 10)
        #expect(config.allowsCellularAccess == false)
        #expect(config.requestHeaders["Authorization"] == "Bearer token")
    }

    @Test("URLSessionConfiguration is created correctly")
    func urlSessionConfiguration() {
        let config = WebSocketConfiguration(
            maxConcurrentConnections: 4,
            connectionTimeout: 45,
            allowsCellularAccess: false,
            sessionIdentifier: "test.websocket"
        )

        let sessionConfig = config.makeURLSessionConfiguration()

        #expect(sessionConfig.timeoutIntervalForRequest == 45)
        #expect(sessionConfig.allowsCellularAccess == false)
        #expect(sessionConfig.httpMaximumConnectionsPerHost == 4)
    }
}


@Suite("WebSocket Task Tests")
struct WebSocketTaskTests {

    @Test("Task is created with correct initial state")
    func initialState() async {
        let url = URL(string: "wss://echo.websocket.org")!
        let task = WebSocketTask(url: url)

        #expect(await task.state == .idle)
        #expect(await task.reconnectCount == 0)
        #expect(await task.error == nil)
        #expect(await task.closeCode == nil)
    }

    @Test("Task is created with subprotocols")
    func withSubprotocols() async {
        let url = URL(string: "wss://echo.websocket.org")!
        let subprotocols = ["graphql-ws", "mqtt"]
        let task = WebSocketTask(url: url, subprotocols: subprotocols)

        #expect(await task.subprotocols == subprotocols)
    }

    @Test("Task state can be updated")
    func stateUpdate() async {
        let url = URL(string: "wss://echo.websocket.org")!
        let task = WebSocketTask(url: url)

        await task.updateState(.connecting)
        #expect(await task.state == .connecting)

        await task.updateState(.connected)
        #expect(await task.state == .connected)
    }

    @Test("Task reconnect count is incremented")
    func reconnectCount() async {
        let url = URL(string: "wss://echo.websocket.org")!
        let task = WebSocketTask(url: url)

        let count1 = await task.incrementReconnectCount()
        #expect(count1 == 1)

        let count2 = await task.incrementReconnectCount()
        #expect(count2 == 2)
    }

    @Test("Task can be reset")
    func taskReset() async {
        let url = URL(string: "wss://echo.websocket.org")!
        let task = WebSocketTask(url: url)

        await task.updateState(.failed)
        await task.setError(.maxReconnectAttemptsExceeded)
        _ = await task.incrementReconnectCount()

        await task.reset()

        #expect(await task.state == .idle)
        #expect(await task.reconnectCount == 0)
        #expect(await task.error == nil)
    }
}


@Suite("WebSocket State Tests")
struct WebSocketStateTests {

    @Test("All expected states exist")
    func states() {
        #expect(WebSocketState.idle.rawValue == "idle")
        #expect(WebSocketState.connecting.rawValue == "connecting")
        #expect(WebSocketState.connected.rawValue == "connected")
        #expect(WebSocketState.disconnecting.rawValue == "disconnecting")
        #expect(WebSocketState.disconnected.rawValue == "disconnected")
        #expect(WebSocketState.reconnecting.rawValue == "reconnecting")
        #expect(WebSocketState.failed.rawValue == "failed")
    }
}


@Suite("WebSocket Error Tests")
struct WebSocketErrorTests {

    @Test("Error descriptions are meaningful")
    func errorDescriptions() {
        #expect(WebSocketError.cancelled.errorDescription?.contains("cancelled") == true)
        #expect(WebSocketError.pingTimeout.errorDescription?.contains("ping") == true)
        #expect(WebSocketError.maxReconnectAttemptsExceeded.errorDescription?.contains("reconnect") == true)
        #expect(WebSocketError.invalidURL("test").errorDescription?.contains("test") == true)
    }

    @Test("Disconnected error with nil reason")
    func disconnectedNilReason() {
        let error = WebSocketError.disconnected(nil)
        #expect(error.errorDescription?.contains("disconnected") == true)
    }
}


@Suite("WebSocket Manager Tests")
struct WebSocketManagerTests {

    @Test("Manager can be created with custom configuration")
    func customManager() async {
        let config = WebSocketConfiguration(maxConcurrentConnections: 5)
        let manager = WebSocketManager(configuration: config)

        #expect((await manager.allTasks()).isEmpty)
    }

    @Test("Manager can be created with default configuration")
    func defaultManager() async {
        let manager = WebSocketManager()

        #expect((await manager.allTasks()).isEmpty)
    }

    @Test("Active tasks are empty initially")
    func activeTasksEmpty() async {
        let manager = WebSocketManager()
        let activeTasks = await manager.activeTasks()

        #expect(activeTasks.isEmpty)
    }

    @Test("Reconnect decision allows disconnected and failed states only when enabled")
    func reconnectDecision() {
        #expect(WebSocketManager.shouldReconnect(currentState: .failed, autoReconnectEnabled: true))
        #expect(WebSocketManager.shouldReconnect(currentState: .disconnected, autoReconnectEnabled: true))
        #expect(WebSocketManager.shouldReconnect(currentState: .reconnecting, autoReconnectEnabled: true))

        #expect(!WebSocketManager.shouldReconnect(currentState: .connected, autoReconnectEnabled: true))
        #expect(!WebSocketManager.shouldReconnect(currentState: .disconnecting, autoReconnectEnabled: true))
        #expect(!WebSocketManager.shouldReconnect(currentState: .failed, autoReconnectEnabled: false))
    }
}


private actor WebSocketEventRecorder {
    private var events: [WebSocketEvent] = []

    func record(_ event: WebSocketEvent) {
        events.append(event)
    }

    func snapshot() -> [WebSocketEvent] {
        events
    }
}


@Suite("WebSocket Listener Lifecycle Tests")
struct WebSocketListenerLifecycleTests {
    @Test("Listener persists across auto reconnect and is cleaned on disconnect")
    func listenerPersistsAcrossReconnect() async throws {
        let config = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 3,
            sessionIdentifier: "test.websocket.listener.retry.\(UUID().uuidString)"
        )
        let manager = WebSocketManager(configuration: config)
        let recorder = WebSocketEventRecorder()

        let task = await manager.connect(url: URL(string: "wss://example.invalid/socket")!)
        let _ = await manager.addEventListener(for: task) { event in
            Task {
                await recorder.record(event)
            }
        }

        let firstTaskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        manager.handleDisconnected(
            taskIdentifier: firstTaskIdentifier,
            closeCode: .abnormalClosure,
            reason: "transient network error"
        )

        let reconnectedTaskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))

        #expect(await manager.listenerCount(for: task) == 1)

        manager.handleConnected(taskIdentifier: reconnectedTaskIdentifier, protocolName: "chat")
        let connectedReceived = await waitForEvent(
            recorder: recorder,
            timeout: 2.0
        ) { event in
            if case .connected(let protocolName) = event {
                return protocolName == "chat"
            }
            return false
        }
        #expect(connectedReceived)

        await manager.disconnect(task)
        #expect(await waitForListenerCleanup(manager: manager, task: task))
    }

    @Test("Final reconnect failure removes listeners and task runtime")
    func terminalFailureRemovesListeners() async throws {
        let config = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 1,
            sessionIdentifier: "test.websocket.listener.terminal.\(UUID().uuidString)"
        )
        let manager = WebSocketManager(configuration: config)

        let task = await manager.connect(url: URL(string: "wss://example.invalid/socket")!)
        let _ = await manager.addEventListener(for: task) { _ in }

        let taskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        manager.handleError(taskIdentifier: taskIdentifier, error: URLError(.cannotConnectToHost))

        #expect(await waitForListenerCleanup(manager: manager, task: task))
        #expect(await manager.task(withId: task.id) == nil)
    }

    private func waitForRuntimeTaskIdentifier(
        manager: WebSocketManager,
        task: WebSocketTask,
        timeout: TimeInterval = 2.0
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let identifier = await manager.runtimeTaskIdentifier(for: task) {
                return identifier
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func waitForEvent(
        recorder: WebSocketEventRecorder,
        timeout: TimeInterval,
        predicate: @escaping (WebSocketEvent) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let events = await recorder.snapshot()
            if events.contains(where: predicate) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func waitForListenerCleanup(
        manager: WebSocketManager,
        task: WebSocketTask,
        timeout: TimeInterval = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let listenerCount = await manager.listenerCount(for: task)
            let runtimeIdentifier = await manager.runtimeTaskIdentifier(for: task)
            if listenerCount == 0 && runtimeIdentifier == nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
