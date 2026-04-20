import Foundation
import Testing
@testable import InnoNetworkWebSocket


@Suite("WebSocket Reconnect Backoff Tests")
struct WebSocketReconnectBackoffTests {

    @Test("reconnectAction returns .retry within maxReconnectAttempts")
    func retryWithinBudget() async {
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0,
                maxReconnectAttempts: 3
            ),
            runtimeRegistry: registry
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        let action = await coordinator.reconnectAction(task: task)
        #expect(action == .retry)
        #expect(await task.reconnectCount == 1)
    }

    @Test("reconnectAction returns .exceeded past maxReconnectAttempts")
    func exceededPastBudget() async {
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0,
                maxReconnectAttempts: 2
            ),
            runtimeRegistry: registry
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        var lastAction: WebSocketReconnectAction = .terminal
        for _ in 0..<3 {
            lastAction = await coordinator.reconnectAction(task: task)
        }
        #expect(lastAction == .exceeded)
        #expect(await task.reconnectCount == 3)
    }

    @Test("reconnectAction returns .terminal when autoReconnect disabled")
    func terminalWhenAutoReconnectDisabled() async {
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0,
                maxReconnectAttempts: 5
            ),
            runtimeRegistry: registry
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        await task.setAutoReconnectEnabled(false)

        let action = await coordinator.reconnectAction(task: task)
        #expect(action == .terminal)
        #expect(await task.reconnectCount == 0)
    }

    @Test("reconnectAction returns .terminal when previousState is .disconnecting")
    func terminalWhenManualDisconnecting() async {
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0,
                maxReconnectAttempts: 5
            ),
            runtimeRegistry: registry
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        let action = await coordinator.reconnectAction(
            task: task,
            previousState: .disconnecting
        )
        #expect(action == .terminal)
        #expect(await task.reconnectCount == 0)
    }

    @Test("reconnectAction with non-retryable disposition returns .terminal")
    func terminalWhenDispositionNotRetryable() async {
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0,
                maxReconnectAttempts: 5
            ),
            runtimeRegistry: registry
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        let terminalDisposition = WebSocketCloseDisposition.classifyPeerClose(
            .policyViolation,
            reason: nil
        )
        let action = await coordinator.reconnectAction(
            task: task,
            closeDisposition: terminalDisposition
        )
        #expect(action == .terminal)
        #expect(await task.reconnectCount == 0)
    }

    @Test("reconnectAction with retryable disposition consumes budget")
    func retryableDispositionConsumesBudget() async {
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0,
                maxReconnectAttempts: 3
            ),
            runtimeRegistry: registry
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        let retryableDisposition = WebSocketCloseDisposition.classifyPeerClose(
            .goingAway,
            reason: nil
        )
        let action = await coordinator.reconnectAction(
            task: task,
            closeDisposition: retryableDisposition
        )
        #expect(action == .retry)
        #expect(await task.reconnectCount == 1)
    }

    @Test("attemptReconnect with zero delay schedules immediate reconnect")
    func zeroDelayAttemptReconnect() async {
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0,
                reconnectJitterRatio: 0,
                maxReconnectAttempts: 3
            ),
            runtimeRegistry: registry
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        await task.updateState(.disconnected)
        _ = await task.incrementReconnectCount()

        await withCheckedContinuation { continuation in
            Task {
                await coordinator.attemptReconnect(task: task) { _ in
                    continuation.resume()
                }
            }
        }

        let state = await task.state
        #expect(state == .reconnecting)
        await registry.cancelReconnectTask(for: task.id)
    }

    @Test("Task.resetReconnectCount clears prior reconnect tally")
    func taskResetReconnectCountClearsTally() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        _ = await task.incrementReconnectCount()
        _ = await task.incrementReconnectCount()
        #expect(await task.reconnectCount == 2)

        await task.resetReconnectCount()
        #expect(await task.reconnectCount == 0)
    }
}
