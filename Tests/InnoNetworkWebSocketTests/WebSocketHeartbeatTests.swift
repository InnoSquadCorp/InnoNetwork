import Foundation
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
}
