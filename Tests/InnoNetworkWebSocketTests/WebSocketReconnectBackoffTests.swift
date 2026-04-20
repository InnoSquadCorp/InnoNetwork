import Foundation
import os
import Testing
import InnoNetworkTestSupport
@testable import InnoNetwork
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

    @Test("attemptReconnect suspends on the injected clock before dispatching startConnection")
    func attemptReconnectWaitsForClockBeforeDispatch() async {
        let clock = TestClock()
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 2.0,
                reconnectJitterRatio: 0,
                maxReconnectAttempts: 3
            ),
            runtimeRegistry: registry,
            clock: clock
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        await task.updateState(.disconnected)
        _ = await task.incrementReconnectCount()

        let startCalled = OSAllocatedUnfairLock<Bool>(initialState: false)
        await coordinator.attemptReconnect(task: task) { _ in
            startCalled.withLock { $0 = true }
        }

        // Coordinator enqueues exactly one waiter on the clock and does not
        // dispatch startConnection until we advance.
        #expect(await clock.waitForWaiters(count: 1))
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(startCalled.withLock { $0 } == false)

        clock.advance(by: .seconds(2))

        let dispatched = await waitFor(timeout: 1.0) {
            startCalled.withLock { $0 }
        }
        #expect(dispatched)
        await registry.cancelReconnectTask(for: task.id)
    }

    @Test("reconnect backoff grows exponentially across consecutive attempts")
    func reconnectBackoffExponentiatesAcrossAttempts() async {
        let clock = TestClock()
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 1.0,
                reconnectJitterRatio: 0,
                maxReconnectAttempts: 5
            ),
            runtimeRegistry: registry,
            clock: clock
        )

        // Per attempt: baseDelay = reconnectDelay * 2^(count - 1)
        // count=1 -> 1.0s, count=2 -> 2.0s, count=3 -> 4.0s
        let expectedDelays: [TimeInterval] = [1.0, 2.0, 4.0]

        for (index, expectedDelay) in expectedDelays.enumerated() {
            let task = WebSocketTask(
                url: URL(string: "wss://example.invalid/attempt-\(index)")!
            )
            await task.updateState(.disconnected)
            for _ in 0..<(index + 1) {
                _ = await task.incrementReconnectCount()
            }

            let startCalled = OSAllocatedUnfairLock<Bool>(initialState: false)
            let baseline = clock.enqueuedCount
            await coordinator.attemptReconnect(task: task) { _ in
                startCalled.withLock { $0 = true }
            }

            #expect(await clock.waitForEnqueuedCount(atLeast: baseline + 1))
            // Advance *just short of* the expected delay - the waiter must
            // remain pending.
            if expectedDelay > 0.05 {
                clock.advance(by: .seconds(expectedDelay - 0.05))
                try? await Task.sleep(nanoseconds: 10_000_000)
                #expect(
                    startCalled.withLock { $0 } == false,
                    "attempt \(index + 1): start fired before full delay of \(expectedDelay)s"
                )
            }

            // Cross the remaining slack and verify dispatch.
            clock.advance(by: .seconds(0.05))
            let dispatched = await waitFor(timeout: 1.0) {
                startCalled.withLock { $0 }
            }
            #expect(
                dispatched,
                "attempt \(index + 1): start did not fire after full delay of \(expectedDelay)s"
            )

            await registry.cancelReconnectTask(for: task.id)
        }
    }

    @Test("Cancelling the reconnect task before advance skips dispatch")
    func reconnectTaskCancellationAbortsBackoff() async {
        let clock = TestClock()
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 5.0,
                reconnectJitterRatio: 0,
                maxReconnectAttempts: 3
            ),
            runtimeRegistry: registry,
            clock: clock
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/cancel")!)
        await task.updateState(.disconnected)
        _ = await task.incrementReconnectCount()

        let startCalled = OSAllocatedUnfairLock<Bool>(initialState: false)
        await coordinator.attemptReconnect(task: task) { _ in
            startCalled.withLock { $0 = true }
        }

        #expect(await clock.waitForWaiters(count: 1))
        await registry.cancelReconnectTask(for: task.id)

        // Even after advancing, the cancelled reconnect task must not
        // dispatch startConnection.
        clock.advance(by: .seconds(5))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(startCalled.withLock { $0 } == false)
    }
}


/// Shared polling helper for reconnect assertions. Mirrors the small waiter
/// used by heartbeat timing tests so both suites avoid hard-coded sleeps.
@Sendable
private func waitFor(
    timeout: TimeInterval,
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
