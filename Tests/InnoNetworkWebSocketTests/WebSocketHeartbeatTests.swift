import Foundation
import os
import Testing
@testable import InnoNetworkWebSocket


@Suite("WebSocket Heartbeat Tests")
struct WebSocketHeartbeatTests {

    @Test("startHeartbeat with heartbeatInterval=0 is a no-op")
    func heartbeatDisabledWhenIntervalZero() async {
        let registry = WebSocketRuntimeRegistry()
        let eventHub = TaskEventHub<WebSocketEvent>(
            policy: .default,
            metricsReporter: nil,
            hubKind: .webSocketTask
        )
        let coordinator = WebSocketHeartbeatCoordinator(
            configuration: WebSocketConfiguration(heartbeatInterval: 0),
            runtimeRegistry: registry,
            eventHub: eventHub
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        await coordinator.startHeartbeat(for: task) { _ in }

        // No heartbeat loop; subsequent cancel is a fast no-op.
        await registry.cancelHeartbeatTask(for: task.id)
    }

    @Test("startHeartbeat without registered urlTask exits the loop quickly")
    func heartbeatExitsWhenURLTaskMissing() async {
        let registry = WebSocketRuntimeRegistry()
        let eventHub = TaskEventHub<WebSocketEvent>(
            policy: .default,
            metricsReporter: nil,
            hubKind: .webSocketTask
        )
        let coordinator = WebSocketHeartbeatCoordinator(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0.02,
                pongTimeout: 0.05,
                maxMissedPongs: 1
            ),
            runtimeRegistry: registry,
            eventHub: eventHub
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        await task.updateState(.connected)

        await coordinator.startHeartbeat(for: task) { _ in }

        try? await Task.sleep(nanoseconds: 150_000_000)
        await registry.cancelHeartbeatTask(for: task.id)
    }

    @Test("Consecutive startHeartbeat calls cancel the previous heartbeat task")
    func startHeartbeatCancelsPrevious() async {
        let registry = WebSocketRuntimeRegistry()
        let eventHub = TaskEventHub<WebSocketEvent>(
            policy: .default,
            metricsReporter: nil,
            hubKind: .webSocketTask
        )
        let coordinator = WebSocketHeartbeatCoordinator(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 1.0,
                pongTimeout: 1.0
            ),
            runtimeRegistry: registry,
            eventHub: eventHub
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        await task.updateState(.connected)

        await coordinator.startHeartbeat(for: task) { _ in }
        await coordinator.startHeartbeat(for: task) { _ in }

        // Must complete without deadlocking; previous is awaited on replacement.
        await registry.cancelHeartbeatTask(for: task.id)
    }

    @Test("Manager disconnect cancels heartbeat scheduling for the task")
    func managerDisconnectCancelsHeartbeat() async throws {
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: makeWebSocketTestSessionIdentifier("heartbeat-disconnect")
            )
        )

        let task = await manager.connect(url: URL(string: "wss://example.invalid/socket")!)
        let identifier = try #require(await waitForWebSocketRuntimeTaskIdentifier(manager: manager, task: task))
        manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        _ = await waitForWebSocketState(task) { $0 == .connected }

        await manager.disconnect(task)
        manager.handleDisconnected(taskIdentifier: identifier, closeCode: .normalClosure, reason: nil)

        #expect(await waitForWebSocketTaskRemoval(manager: manager, task: task))
    }

    @Test("Final heartbeat timeout emits a single timeout error event for the cycle")
    func finalHeartbeatTimeoutEmitsSingleErrorEvent() async throws {
        let stubSession = StubWebSocketURLSession()
        let stubTask = StubWebSocketURLTask()
        stubSession.enqueue(stubTask)

        let callbacks = WebSocketSessionDelegateCallbacks()
        let delegate = WebSocketSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: BackgroundCompletionStore()
        )
        let manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0.05,
                pongTimeout: 0.05,
                maxMissedPongs: 2,
                reconnectDelay: 0,
                maxReconnectAttempts: 1,
                sessionIdentifier: makeWebSocketTestSessionIdentifier("heartbeat-final-timeout")
            ),
            urlSession: stubSession,
            delegate: delegate,
            callbacks: callbacks
        )

        let task = await manager.connect(url: URL(string: "wss://example.invalid/socket")!)
        let events = OSAllocatedUnfairLock<[WebSocketEvent]>(initialState: [])
        let subscription = await manager.addEventListener(for: task) { event in
            events.withLock { $0.append(event) }
        }

        manager.handleConnected(taskIdentifier: stubTask.taskIdentifier, protocolName: nil)
        #expect(await waitForWebSocketState(task) { $0 == .connected })

        // Keep the manager on the terminal path so the final timeout still
        // emits `.error(.pingTimeout)` but does not start a reconnect chain.
        await task.setAutoReconnectEnabled(false)

        let secondPingObserved = await waitFor(timeout: 2.0) {
            stubTask.pingCount >= 2
        }
        #expect(secondPingObserved)

        let secondTimeoutErrorObserved = await waitFor(timeout: 2.0) {
            events.withLock { snapshot in
                snapshot.reduce(0) { count, event in
                    if case .error(.pingTimeout) = event { return count + 1 }
                    return count
                } >= 2
            }
        }
        #expect(secondTimeoutErrorObserved)

        // Give the terminal failure path a brief moment to finish publishing.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = events.withLock { $0 }
        let pingCount = snapshot.reduce(0) { count, event in
            if case .ping = event { return count + 1 }
            return count
        }
        let pingTimeoutErrorCount = snapshot.reduce(0) { count, event in
            if case .error(.pingTimeout) = event { return count + 1 }
            return count
        }

        #expect(pingCount == 2)
        #expect(pingTimeoutErrorCount == 2)

        await manager.removeEventListener(subscription)
    }

    @Sendable
    private func waitFor(timeout: TimeInterval, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}
