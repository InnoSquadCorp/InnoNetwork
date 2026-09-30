import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

@Suite("Large socket timing budgets", .timeLimit(.minutes(1)))
struct LargeSocketTimingTests {
    @Test func heartbeatRemainsPendingAcrossSlices() async {
        let harness = HeartbeatTestHarness(heartbeatInterval: 1e308, pongTimeout: 1, maxMissedPongs: 1)
        await harness.startHeartbeat()
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: 1))
        harness.clock.advance(by: SchedulingTime.maximumSleepSlice)
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: 2))
        #expect(harness.stubTask.pingCount == 0)
        await harness.stopHeartbeat()
        #expect(harness.clock.waiterCount == 0)
    }

    @Test func pongBudgetRemainsPendingAndCancels() async {
        let clock = TestClock()
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketHeartbeatCoordinator(
            configuration: .safeDefaults(), runtimeRegistry: registry,
            eventHub: TaskEventHub<WebSocketEvent>(), clock: clock)
        let socket = StubWebSocketURLTask()
        let task = Task { try await coordinator.sendPing(socket, timeout: 1e308) }
        await withTaskCancellationHandler {
            #expect(await clock.waitForEnqueuedCount(atLeast: 1))
            clock.advance(by: SchedulingTime.maximumSleepSlice)
            #expect(await clock.waitForEnqueuedCount(atLeast: 2))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            socket.completePendingPong(with: CancellationError())
            #expect(clock.waiterCount == 0)
        } onCancel: {
            task.cancel()
        }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func invalidPongBudgetFailsBeforeDispatch(timeout: Double) async {
        let socket = StubWebSocketURLTask()
        let coordinator = WebSocketHeartbeatCoordinator(
            configuration: .safeDefaults(), runtimeRegistry: WebSocketRuntimeRegistry(),
            eventHub: TaskEventHub<WebSocketEvent>())
        await #expect(throws: SchedulingTimeFailure.self) { try await coordinator.sendPing(socket, timeout: timeout) }
        #expect(socket.pingCount == 0)
    }

    @Test(arguments: [false, true])
    func reconnectKeepsHugeFiniteDelaysWithoutDispatch(overflowingBackoff: Bool) async throws {
        let clock = TestClock()
        let registry = WebSocketRuntimeRegistry()
        let configuration = WebSocketConfiguration.advanced(
            reconnect: .init(
                delay: 1e308, jitterRatio: overflowingBackoff ? 1 : 0, maxDelay: 0, maxAttempts: 10))
        let coordinator = WebSocketReconnectCoordinator(
            configuration: configuration,
            runtimeRegistry: registry, clock: clock, randomOffset: { $0.upperBound }, dateProvider: { clock.now() })
        let task = WebSocketTask(url: try #require(URL(string: "wss://example.invalid/large")))
        await task.restoreStateForTesting(.reconnecting)
        if overflowingBackoff { for _ in 0..<3 { _ = await task.incrementAttemptedReconnectCount() } }
        _ = await coordinator.reconnectAction(task: task)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        await coordinator.attemptReconnect(task: task, startConnection: { _ in calls.withLock { $0 += 1 } })
        #expect(await clock.waitForEnqueuedCount(atLeast: 1))
        clock.advance(by: SchedulingTime.maximumSleepSlice)
        #expect(await clock.waitForEnqueuedCount(atLeast: 2))
        #expect(calls.withLock { $0 } == 0)
        await registry.cancelReconnectTask(for: task.id)
        #expect(clock.waiterCount == 0)
    }
}
