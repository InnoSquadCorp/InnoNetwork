import Foundation
import InnoNetworkTestSupport
import Testing
import os

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
        #expect(await task.attemptedReconnectCount == 1)
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
        // attemptedReconnectCount overshoots the cap by one (the rejected
        // attempt that produced .exceeded).
        #expect(await task.attemptedReconnectCount == 3)
        // successfulReconnectCount stays at 0 — none of those attempts ever
        // re-entered the .connected state.
        #expect(await task.successfulReconnectCount == 0)
    }

    @Test("incrementSuccessfulReconnectCount accumulates across cycles without reset")
    func successfulCounterIsCumulative() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        // Simulate three successful reconnect cycles, each preceded by a few
        // attempts. Per-cycle attempted counter resets; the cumulative
        // successful counter does not.
        for cycle in 1...3 {
            for _ in 0..<2 { _ = await task.incrementAttemptedReconnectCount() }
            await task.incrementSuccessfulReconnectCount()
            await task.resetAttemptedReconnectCount()

            #expect(await task.attemptedReconnectCount == 0)
            #expect(await task.successfulReconnectCount == cycle)
        }
    }

    @Test("reset() clears both counters")
    func resetClearsBothCounters() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        _ = await task.incrementAttemptedReconnectCount()
        _ = await task.incrementAttemptedReconnectCount()
        await task.incrementSuccessfulReconnectCount()
        #expect(await task.attemptedReconnectCount == 2)
        #expect(await task.successfulReconnectCount == 1)

        await task.reset()
        #expect(await task.attemptedReconnectCount == 0)
        #expect(await task.successfulReconnectCount == 0)
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
        #expect(await task.attemptedReconnectCount == 0)
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
        #expect(await task.attemptedReconnectCount == 0)
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
        #expect(await task.attemptedReconnectCount == 0)
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
        #expect(await task.attemptedReconnectCount == 1)
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
        _ = await task.incrementAttemptedReconnectCount()

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

    @Test("Task.resetAttemptedReconnectCount clears prior reconnect tally")
    func taskResetReconnectCountClearsTally() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)
        _ = await task.incrementAttemptedReconnectCount()
        _ = await task.incrementAttemptedReconnectCount()
        #expect(await task.attemptedReconnectCount == 2)

        await task.resetAttemptedReconnectCount()
        #expect(await task.attemptedReconnectCount == 0)
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
        _ = await task.incrementAttemptedReconnectCount()

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
                _ = await task.incrementAttemptedReconnectCount()
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
        _ = await task.incrementAttemptedReconnectCount()

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

    @Test("Exponential backoff is capped at maxReconnectDelay")
    func reconnectBackoffCapsAtMaxReconnectDelay() async {
        let clock = TestClock()
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 1.0,
                reconnectJitterRatio: 0,
                maxReconnectDelay: 5.0,
                maxReconnectAttempts: 20
            ),
            runtimeRegistry: registry,
            clock: clock
        )
        // reconnectCount=10 would produce 2^9 = 512s without the cap.
        // With the cap active at 5s, advancing 5.001s must dispatch.
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/cap")!)
        await task.updateState(.disconnected)
        for _ in 0..<10 {
            _ = await task.incrementAttemptedReconnectCount()
        }

        let startCalled = OSAllocatedUnfairLock<Bool>(initialState: false)
        await coordinator.attemptReconnect(task: task) { _ in
            startCalled.withLock { $0 = true }
        }

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .milliseconds(5_001))

        let dispatched = await waitFor(timeout: 1.0) {
            startCalled.withLock { $0 }
        }
        #expect(dispatched, "cap did not fire — start was not dispatched after advance(5.001s)")
        await registry.cancelReconnectTask(for: task.id)
    }

    @Test("Capped backoff keeps jitter within the cap range")
    func cappedBackoffRetainsBoundedJitter() async {
        let clock = TestClock()
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 1.0,
                reconnectJitterRatio: 0.2,
                maxReconnectDelay: 5.0,
                maxReconnectAttempts: 20
            ),
            runtimeRegistry: registry,
            clock: clock,
            randomOffset: { range in
                #expect(range.lowerBound == 4.0)
                #expect(range.upperBound == 5.0)
                return range.lowerBound
            }
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/cap-jitter")!)
        for _ in 0..<10 {
            _ = await task.incrementAttemptedReconnectCount()
        }
        await task.updateState(.disconnected)

        let startCalled = OSAllocatedUnfairLock<Bool>(initialState: false)
        await coordinator.attemptReconnect(task: task) { _ in
            startCalled.withLock { $0 = true }
        }

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(3.95))
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(startCalled.withLock { $0 } == false)

        clock.advance(by: .seconds(0.05))
        let dispatched = await waitFor(timeout: 1.0) {
            startCalled.withLock { $0 }
        }
        #expect(dispatched, "capped jitter lower bound should dispatch at 4.0s")
        await registry.cancelReconnectTask(for: task.id)
    }

    @Test("maxReconnectDelay <= 0 disables the cap (unbounded backoff preserved)")
    func maxReconnectDelayZeroDisablesCap() async {
        let clock = TestClock()
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 2.0,
                reconnectJitterRatio: 0,
                maxReconnectDelay: 0,
                maxReconnectAttempts: 20
            ),
            runtimeRegistry: registry,
            clock: clock
        )
        // reconnectCount=3 → 2 * 2^2 = 8s total; no cap active, so 5s
        // advance must leave the waiter pending.
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/uncapped")!)
        await task.updateState(.disconnected)
        for _ in 0..<3 {
            _ = await task.incrementAttemptedReconnectCount()
        }

        let startCalled = OSAllocatedUnfairLock<Bool>(initialState: false)
        await coordinator.attemptReconnect(task: task) { _ in
            startCalled.withLock { $0 = true }
        }

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(5))
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(
            startCalled.withLock { $0 } == false,
            "cap should be disabled at maxReconnectDelay=0 — start fired too early"
        )

        clock.advance(by: .seconds(4))
        let dispatched = await waitFor(timeout: 1.0) {
            startCalled.withLock { $0 }
        }
        #expect(dispatched)
        await registry.cancelReconnectTask(for: task.id)
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
