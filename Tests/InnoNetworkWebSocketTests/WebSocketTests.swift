import Foundation
import os
import Testing
@testable import InnoNetworkWebSocket


@Suite("WebSocket Configuration Tests")
struct WebSocketConfigurationTests {

    @Test("Default configuration has expected values")
    func defaultConfiguration() {
        let config = WebSocketConfiguration.default

        #expect(config.maxConnectionsPerHost == 5)
        #expect(config.connectionTimeout == 30)
        #expect(config.heartbeatInterval == 30)
        #expect(config.pongTimeout == 10)
        #expect(config.maxMissedPongs == 1)
        #expect(config.reconnectDelay == 1.0)
        #expect(config.reconnectJitterRatio == 0.2)
        #expect(config.maxReconnectAttempts == 5)
        #expect(config.allowsCellularAccess == true)
    }

    @Test("safeDefaults matches default configuration")
    func safeDefaultsMatchesDefault() {
        let config = WebSocketConfiguration.safeDefaults()
        let defaultConfig = WebSocketConfiguration.default

        #expect(config.maxConnectionsPerHost == defaultConfig.maxConnectionsPerHost)
        #expect(config.connectionTimeout == defaultConfig.connectionTimeout)
        #expect(config.heartbeatInterval == defaultConfig.heartbeatInterval)
        #expect(config.maxReconnectAttempts == defaultConfig.maxReconnectAttempts)
    }

    @Test("advanced builder can override reconnect tuning")
    func advancedBuilderOverrides() {
        let config = WebSocketConfiguration.advanced {
            $0.connectionTimeout = 60
            $0.reconnectDelay = 2
            $0.maxReconnectAttempts = 12
        }

        #expect(config.connectionTimeout == 60)
        #expect(config.reconnectDelay == 2)
        #expect(config.maxReconnectAttempts == 12)
    }

    @Test("Custom configuration is applied correctly")
    func customConfiguration() {
        let config = WebSocketConfiguration(
            maxConnectionsPerHost: 10,
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

        #expect(config.maxConnectionsPerHost == 10)
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
            maxConnectionsPerHost: 4,
            connectionTimeout: 45,
            allowsCellularAccess: false,
            sessionIdentifier: "test.websocket"
        )

        let sessionConfig = config.makeURLSessionConfiguration()

        #expect(sessionConfig.timeoutIntervalForRequest == 45)
        #expect(sessionConfig.allowsCellularAccess == false)
        #expect(sessionConfig.httpMaximumConnectionsPerHost == 4)
    }

    @Test("Negative values are clamped to safe bounds")
    func negativeValueClamping() {
        let config = WebSocketConfiguration(
            maxConnectionsPerHost: -1,
            connectionTimeout: -10,
            heartbeatInterval: -5,
            pongTimeout: -3,
            maxMissedPongs: -2,
            reconnectDelay: -1,
            reconnectJitterRatio: -0.5,
            maxReconnectAttempts: -4
        )

        #expect(config.maxConnectionsPerHost == 1)
        #expect(config.connectionTimeout == 0)
        #expect(config.heartbeatInterval == 0)
        #expect(config.pongTimeout == 0)
        #expect(config.maxMissedPongs == 1)
        #expect(config.reconnectDelay == 0)
        #expect(config.reconnectJitterRatio == 0)
        #expect(config.maxReconnectAttempts == 0)
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
        let config = WebSocketConfiguration(maxConnectionsPerHost: 5)
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

    @Test("Handshake classification maps HTTP auth and retryable responses")
    func handshakeClassification() {
        #expect(WebSocketCloseDisposition.classifyHandshake(
            statusCode: 401,
            error: SendableUnderlyingError(domain: NSURLErrorDomain, code: URLError.userAuthenticationRequired.rawValue, message: "401")
        ) == .handshakeUnauthorized(401))

        #expect(WebSocketCloseDisposition.classifyHandshake(
            statusCode: 403,
            error: SendableUnderlyingError(domain: NSURLErrorDomain, code: URLError.noPermissionsToReadFile.rawValue, message: "403")
        ) == .handshakeForbidden(403))

        #expect(WebSocketCloseDisposition.classifyHandshake(
            statusCode: 503,
            error: SendableUnderlyingError(domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue, message: "503")
        ) == .handshakeServerUnavailable(503))

        #expect(WebSocketCloseDisposition.classifyHandshake(
            statusCode: 422,
            error: SendableUnderlyingError(domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue, message: "422")
        ) == .handshakeTerminalHTTP(422))
    }

    @Test("Handshake classification treats transient network errors as retryable")
    func handshakeTransientNetworkClassification() {
        let disposition = WebSocketCloseDisposition.classifyHandshake(
            statusCode: nil,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue,
                message: "connection lost"
            )
        )

        switch disposition {
        case .handshakeTransientNetwork(let error):
            #expect(error.code == URLError.networkConnectionLost.rawValue)
        default:
            Issue.record("Expected transient network handshake classification")
        }
    }

    @Test("Retry coordinator suppresses reconnect for auth handshake failures")
    func retryCoordinatorSuppressesAuthHandshakeFailures() async {
        let task = WebSocketTask(url: URL(string: "wss://example.com/socket")!)
        let coordinator = WebSocketReconnectCoordinator(
            configuration: .safeDefaults(),
            runtimeRegistry: WebSocketRuntimeRegistry()
        )

        let action = await coordinator.reconnectAction(
            task: task,
            closeDisposition: .handshakeUnauthorized(401),
            previousState: .connecting
        )

        #expect(action == .terminal)
    }

    @Test("Retry coordinator retries retryable handshake server failures")
    func retryCoordinatorRetriesRetryableHandshakeFailures() async {
        let task = WebSocketTask(url: URL(string: "wss://example.com/socket")!)
        let coordinator = WebSocketReconnectCoordinator(
            configuration: .advanced {
                $0.maxReconnectAttempts = 2
                $0.reconnectDelay = 0
            },
            runtimeRegistry: WebSocketRuntimeRegistry()
        )

        let action = await coordinator.reconnectAction(
            task: task,
            closeDisposition: .handshakeServerUnavailable(503),
            previousState: .connecting
        )

        #expect(action == .retry)
    }

    @Test("Reconnect attempt budget uses retry-count semantics")
    func reconnectAttemptBudgetSemantics() {
        #expect(WebSocketManager.shouldRetryReconnect(after: 1, maxReconnectAttempts: 2))
        #expect(WebSocketManager.shouldRetryReconnect(after: 2, maxReconnectAttempts: 2))
        #expect(!WebSocketManager.shouldRetryReconnect(after: 3, maxReconnectAttempts: 2))
        #expect(!WebSocketManager.shouldRetryReconnect(after: 1, maxReconnectAttempts: 0))
    }

    @Test("WebSocket lifecycle helper documents legal transitions")
    func stateTransitionModel() {
        #expect(WebSocketState.connected.nextStates == [.disconnecting, .disconnected, .reconnecting, .failed])
        #expect(WebSocketState.idle.canTransition(to: .connecting))
        #expect(WebSocketState.connecting.canTransition(to: .connected))
        #expect(WebSocketState.connected.canTransition(to: .reconnecting))
        #expect(WebSocketState.failed.canTransition(to: .idle))
        #expect(!WebSocketState.connected.canTransition(to: .idle))
        #expect(WebSocketState.failed.isTerminal)
        #expect(!WebSocketState.reconnecting.isTerminal)
    }

    @Test("Disconnect supports connecting and reconnecting states")
    func disconnectSupportsConnectingAndReconnectingStates() async {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                sessionIdentifier: "test.websocket.disconnect-state.\(UUID().uuidString)"
            )
        )

        let connectingTask = await manager.connect(url: URL(string: "wss://example.invalid/socket")!)
        let connectingIdentifier = await manager.runtimeTaskIdentifier(for: connectingTask)
        await manager.disconnect(connectingTask)
        if let connectingIdentifier {
            manager.handleDisconnected(
                taskIdentifier: connectingIdentifier,
                closeCode: .normalClosure,
                reason: nil
            )
        }
        #expect(await waitForTaskRemoval(manager: manager, taskID: connectingTask.id))

        let reconnectingTask = await manager.connect(url: URL(string: "wss://example.invalid/socket")!)
        await reconnectingTask.updateState(.reconnecting)
        let reconnectingIdentifier = await manager.runtimeTaskIdentifier(for: reconnectingTask)
        await manager.disconnect(reconnectingTask)
        if let reconnectingIdentifier {
            manager.handleDisconnected(
                taskIdentifier: reconnectingIdentifier,
                closeCode: .normalClosure,
                reason: nil
            )
        }
        #expect(await waitForTaskRemoval(manager: manager, taskID: reconnectingTask.id))
    }

    @Test("Background completion callback is immediate for websocket manager")
    func backgroundCompletionImmediate() async {
        let manager = WebSocketManager()

        await confirmation("background completion called") { confirm in
            manager.handleBackgroundSessionCompletion("websocket.any-id") {
                confirm()
            }
        }
    }

    private func waitForTaskRemoval(
        manager: WebSocketManager,
        taskID: String,
        timeout: TimeInterval = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await manager.task(withId: taskID) == nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}


// `WebSocketEventRecorder` is provided by `WebSocketTestSupport.swift`.


@Suite("WebSocket Listener Lifecycle Tests")
struct WebSocketListenerLifecycleTests {
    @Test("Reconnect runtime chain reaches max reconnect attempts")
    func reconnectRuntimeChainReachesMaxAttempts() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                connectionTimeout: 30,
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 2,
                sessionIdentifier: "test.websocket.reconnect-runtime.\(UUID().uuidString)"
            )
        )
        let recorder = WebSocketEventRecorder()

        let task = await manager.connect(url: URL(string: "ws://192.0.2.1/socket")!)
        _ = await manager.addEventListener(for: task) { event in
            recorder.record(event)
        }

        let firstTaskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        manager.handleError(taskIdentifier: firstTaskIdentifier, error: URLError(.cannotConnectToHost))

        let secondTaskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: manager,
                task: task,
                excluding: [firstTaskIdentifier],
                timeout: 3.0
            )
        )
        manager.handleError(taskIdentifier: secondTaskIdentifier, error: URLError(.cannotConnectToHost))

        let thirdTaskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: manager,
                task: task,
                excluding: [firstTaskIdentifier, secondTaskIdentifier],
                timeout: 3.0
            )
        )
        manager.handleError(taskIdentifier: thirdTaskIdentifier, error: URLError(.cannotConnectToHost))

        #expect(await waitForTaskError(task: task, timeout: 5.0) { error in
            if case .maxReconnectAttemptsExceeded = error {
                return true
            }
            return false
        })
        #expect(await task.reconnectCount >= 3)
        #expect(await waitForListenerCleanup(manager: manager, task: task))

        let maxExceededEvent = await waitForEvent(recorder: recorder, timeout: 1.0) { event in
            if case .error(.maxReconnectAttemptsExceeded) = event {
                return true
            }
            return false
        }
        #expect(maxExceededEvent)
    }

    @Test("Max reconnect attempts zero fails immediately")
    func maxReconnectAttemptsZeroFailsImmediately() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: "test.websocket.reconnect-zero.\(UUID().uuidString)"
            )
        )
        let recorder = WebSocketEventRecorder()

        let task = await manager.connect(url: URL(string: "ws://192.0.2.1/socket")!)
        _ = await manager.addEventListener(for: task) { event in
            recorder.record(event)
        }

        let taskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        manager.handleError(taskIdentifier: taskIdentifier, error: URLError(.cannotConnectToHost))

        #expect(await waitForListenerCleanup(manager: manager, task: task))
        let maxExceededEvent = await waitForEvent(recorder: recorder, timeout: 2.0) { event in
            if case .error(.maxReconnectAttemptsExceeded) = event {
                return true
            }
            return false
        }
        #expect(maxExceededEvent)
    }

    @Test("Listener persists across auto reconnect and is cleaned on disconnect")
    func listenerPersistsAcrossReconnect() async throws {
        let config = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 3,
            sessionIdentifier: "test.websocket.listener.retry.\(UUID().uuidString)"
        )
        let manager = WebSocketManager(configuration: config)

        let task = await manager.connect(url: URL(string: "wss://example.invalid/socket")!)
        let _ = await manager.addEventListener(for: task) { event in
            _ = event
        }

        let firstTaskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        manager.handleDisconnected(
            taskIdentifier: firstTaskIdentifier,
            closeCode: .abnormalClosure,
            reason: "transient network error"
        )

        #expect(await waitForListenerCount(manager: manager, task: task, expected: 1))

        await manager.disconnect(task)
        #expect(await waitForListenerCleanup(manager: manager, task: task))
    }

    @Test("Disconnect reason is propagated to disconnected event")
    func disconnectReasonPropagation() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: "test.websocket.disconnect-reason.\(UUID().uuidString)"
            )
        )
        let recorder = WebSocketEventRecorder()

        let task = await manager.connect(url: URL(string: "wss://example.invalid/socket")!)
        _ = await manager.addEventListener(for: task) { event in
            recorder.record(event)
        }

        let taskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        manager.handleDisconnected(
            taskIdentifier: taskIdentifier,
            closeCode: .goingAway,
            reason: "server shutdown"
        )

        let reasonDelivered = await waitForEvent(recorder: recorder, timeout: 2.0) { event in
            if case .disconnected(.disconnected(let underlying)) = event {
                return underlying?.domain == "InnoNetworkWebSocket.CloseReason"
                    && underlying?.message == "server shutdown"
                    && underlying?.code == Int(URLSessionWebSocketTask.CloseCode.goingAway.rawValue)
            }
            return false
        }
        #expect(reasonDelivered)
    }

    @Test("Manual disconnect emits contextual disconnected reason")
    func manualDisconnectReasonPropagation() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: "test.websocket.manual-disconnect-reason.\(UUID().uuidString)"
            )
        )
        let recorder = WebSocketEventRecorder()

        let task = await manager.connect(url: URL(string: "wss://example.invalid/socket")!)
        _ = await manager.addEventListener(for: task) { event in
            recorder.record(event)
        }

        let taskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        await task.setAutoReconnectEnabled(false)
        await task.beginManualDisconnect(
            error: .disconnected(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.ManualDisconnect",
                    code: Int(URLSessionWebSocketTask.CloseCode.goingAway.rawValue),
                    message: "Client initiated disconnect."
                )
            )
        )
        await task.updateState(.disconnecting)
        manager.handleDisconnected(
            taskIdentifier: taskIdentifier,
            closeCode: .goingAway,
            reason: nil
        )

        let reasonDelivered = await waitForEvent(recorder: recorder, timeout: 2.0) { event in
            if case .disconnected(.disconnected(let underlying)) = event {
                return underlying?.domain == "InnoNetworkWebSocket.ManualDisconnect"
                    && underlying?.message == "Client initiated disconnect."
                    && underlying?.code == Int(URLSessionWebSocketTask.CloseCode.goingAway.rawValue)
            }
            return false
        }
        #expect(reasonDelivered)
    }

    @Test("Manual disconnect remains disconnecting until close ack arrives")
    func manualDisconnectWaitsForCloseAck() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: "test.websocket.manual-close-ack.\(UUID().uuidString)"
            )
        )

        let task = await manager.connect(url: URL(string: "ws://192.0.2.1/socket")!)
        let taskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))

        await task.setAutoReconnectEnabled(false)
        await task.beginManualDisconnect(
            error: .disconnected(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.ManualDisconnect",
                    code: Int(URLSessionWebSocketTask.CloseCode.goingAway.rawValue),
                    message: "Client initiated disconnect."
                )
            )
        )
        await task.updateState(.disconnecting)
        #expect(await task.state == .disconnecting)
        #expect(await manager.task(withId: task.id) != nil)

        manager.handleDisconnected(
            taskIdentifier: taskIdentifier,
            closeCode: .goingAway,
            reason: "server-ack"
        )

        #expect(await waitForListenerCleanup(manager: manager, task: task))
    }

    @Test("Cancelled transport during manual close is not emitted as error")
    func cancelledTransportDuringManualCloseIsIgnored() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: "test.websocket.manual-close-cancelled.\(UUID().uuidString)"
            )
        )
        let recorder = WebSocketEventRecorder()

        let task = await manager.connect(url: URL(string: "ws://192.0.2.1/socket")!)
        _ = await manager.addEventListener(for: task) { event in
            recorder.record(event)
        }

        let taskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        await task.setAutoReconnectEnabled(false)
        await task.beginManualDisconnect(
            error: .disconnected(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.ManualDisconnect",
                    code: Int(URLSessionWebSocketTask.CloseCode.normalClosure.rawValue),
                    message: "Client initiated disconnect."
                )
            )
        )
        await task.updateState(.disconnecting)
        manager.handleSessionError(
            taskIdentifier: taskIdentifier,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.cancelled.rawValue,
                message: "manual close transport cancellation"
            )
        )

        let cancelledErrorDelivered = await waitForEvent(recorder: recorder, timeout: 0.3) { event in
            if case .error(.cancelled) = event {
                return true
            }
            return false
        }
        #expect(!cancelledErrorDelivered)

        manager.handleDisconnected(
            taskIdentifier: taskIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        #expect(await waitForListenerCleanup(manager: manager, task: task))
    }

    @Test("Disconnecting callback does not emit duplicate disconnected reason")
    func disconnectingCallbackSkipsDuplicateEmission() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: "test.websocket.disconnecting-duplicate.\(UUID().uuidString)"
            )
        )
        let recorder = WebSocketEventRecorder()

        let task = await manager.connect(url: URL(string: "ws://192.0.2.1/socket")!)
        _ = await manager.addEventListener(for: task) { event in
            recorder.record(event)
        }

        let taskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        await task.updateState(.disconnecting)
        manager.handleDisconnected(
            taskIdentifier: taskIdentifier,
            closeCode: .goingAway,
            reason: "duplicate-check"
        )

        let duplicateDelivered = await waitForEvent(recorder: recorder, timeout: 0.3) { event in
            if case .disconnected(.disconnected(let underlying)) = event {
                return underlying?.message == "duplicate-check"
            }
            return false
        }
        #expect(!duplicateDelivered)

        await task.updateState(.disconnected)
        manager.handleDisconnected(
            taskIdentifier: taskIdentifier,
            closeCode: .goingAway,
            reason: "duplicate-check-disconnected"
        )

        let duplicateWhenDisconnected = await waitForEvent(recorder: recorder, timeout: 0.3) { event in
            if case .disconnected(.disconnected(let underlying)) = event {
                return underlying?.message == "duplicate-check-disconnected"
            }
            return false
        }
        #expect(!duplicateWhenDisconnected)

        await task.updateState(.connected)
        await task.setAutoReconnectEnabled(false)
        await task.beginManualDisconnect(
            error: .disconnected(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.ManualDisconnect",
                    code: Int(URLSessionWebSocketTask.CloseCode.normalClosure.rawValue),
                    message: "Client initiated disconnect."
                )
            )
        )
        await task.updateState(.disconnecting)
        manager.handleDisconnected(
            taskIdentifier: taskIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        #expect(await waitForListenerCleanup(manager: manager, task: task))
    }

    @Test("Disconnecting task ignores stale connected callback")
    func disconnectingTaskIgnoresStaleConnectedCallback() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: "test.websocket.stale-connected.\(UUID().uuidString)"
            )
        )
        let recorder = WebSocketEventRecorder()

        let task = await manager.connect(url: URL(string: "ws://192.0.2.1/socket")!)
        _ = await manager.addEventListener(for: task) { event in
            recorder.record(event)
        }

        let taskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        await task.updateState(.disconnecting)
        await task.setAutoReconnectEnabled(false)
        manager.handleConnected(taskIdentifier: taskIdentifier, protocolName: "stale")

        let connectedDelivered = await waitForEvent(recorder: recorder, timeout: 0.3) { event in
            if case .connected = event { return true }
            return false
        }
        #expect(!connectedDelivered)
        #expect(await task.state == .disconnecting)

        await task.updateState(.connected)
        await task.setAutoReconnectEnabled(true)
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

        let task = await manager.connect(url: URL(string: "ws://192.0.2.1/socket")!)
        let _ = await manager.addEventListener(for: task) { _ in }

        let firstTaskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))
        manager.handleError(taskIdentifier: firstTaskIdentifier, error: URLError(.cannotConnectToHost))

        let secondTaskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: manager,
                task: task,
                excluding: [firstTaskIdentifier]
            )
        )
        manager.handleError(taskIdentifier: secondTaskIdentifier, error: URLError(.cannotConnectToHost))

        #expect(await waitForListenerCleanup(manager: manager, task: task))
        #expect(await manager.task(withId: task.id) == nil)
    }

    @Test("Server normal close does not trigger reconnect")
    func serverNormalCloseDoesNotReconnect() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 3,
                sessionIdentifier: "test.websocket.server-normal-close.\(UUID().uuidString)"
            )
        )

        let task = await manager.connect(url: URL(string: "ws://192.0.2.1/socket")!)
        let firstTaskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))

        manager.handleDisconnected(
            taskIdentifier: firstTaskIdentifier,
            closeCode: .normalClosure,
            reason: "server-finished"
        )

        #expect(await waitForTaskRemoval(manager: manager, task: task))
    }

    @Test("Retryable server close triggers reconnect")
    func retryableServerCloseReconnects() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 2,
                sessionIdentifier: "test.websocket.retryable-close.\(UUID().uuidString)"
            )
        )

        let task = await manager.connect(url: URL(string: "ws://192.0.2.1/socket")!)
        let firstTaskIdentifier = try #require(await waitForRuntimeTaskIdentifier(manager: manager, task: task))

        manager.handleDisconnected(
            taskIdentifier: firstTaskIdentifier,
            closeCode: .goingAway,
            reason: "server-restart"
        )

        let secondTaskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: manager,
                task: task,
                excluding: [firstTaskIdentifier]
            )
        )
        #expect(secondTaskIdentifier != firstTaskIdentifier)
    }

    private func waitForRuntimeTaskIdentifier(
        manager: WebSocketManager,
        task: WebSocketTask,
        excluding: Set<Int> = [],
        timeout: TimeInterval = 2.0
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let identifier = await manager.runtimeTaskIdentifier(for: task), !excluding.contains(identifier) {
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
            let events = recorder.snapshot()
            if events.contains(where: predicate) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func waitForListenerCount(
        manager: WebSocketManager,
        task: WebSocketTask,
        expected: Int,
        timeout: TimeInterval = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await manager.listenerCount(for: task) == expected {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func waitForTaskError(
        task: WebSocketTask,
        timeout: TimeInterval = 2.0,
        predicate: @escaping (WebSocketError?) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(await task.error) {
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

    private func waitForTaskRemoval(
        manager: WebSocketManager,
        task: WebSocketTask,
        timeout: TimeInterval = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await manager.task(withId: task.id) == nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}
