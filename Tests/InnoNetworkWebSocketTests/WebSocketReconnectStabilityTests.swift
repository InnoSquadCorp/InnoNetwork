import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

/// A connection that opens and drops again before the stability interval must
/// keep consuming the reconnect budget instead of resetting it.
@Suite("WebSocket Reconnect Stability Tests")
struct WebSocketReconnectStabilityTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Fixture {
        let coordinator: WebSocketReconnectCoordinator
        let task: WebSocketTask
        /// Drives the monotonic clock the coordinator measures both budgets
        /// on: how long a connection stayed open, and the reconnect window.
        let clock: TestClock

        func advance(by interval: TimeInterval) {
            clock.advance(by: .seconds(interval))
        }
    }

    private func makeFixture(
        maxReconnectAttempts: Int,
        reconnectMaxTotalDuration: TimeInterval = 0,
        stabilityInterval: TimeInterval = 10
    ) -> Fixture {
        let clock = TestClock(epoch: Self.start)
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0,
                reconnectJitterRatio: 0,
                maxReconnectAttempts: maxReconnectAttempts,
                reconnectMaxTotalDuration: reconnectMaxTotalDuration,
                reconnectStabilityInterval: stabilityInterval
            ),
            runtimeRegistry: WebSocketRuntimeRegistry(),
            clock: clock
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/stability")!)
        return Fixture(coordinator: coordinator, task: task, clock: clock)
    }

    @Test("A server that accepts and immediately drops connections exhausts the attempt budget")
    func flappingConnectionExhaustsAttempts() async {
        let fixture = makeFixture(maxReconnectAttempts: 3)

        var actions: [WebSocketReconnectAction] = []
        for _ in 0..<4 {
            // The connection drops; decide whether to reconnect.
            actions.append(await fixture.coordinator.reconnectAction(task: fixture.task))
            // The reconnect succeeds, then the server closes it one second
            // later — well inside the ten-second stability interval.
            await fixture.coordinator.connectionDidOpen(task: fixture.task)
            #expect(await fixture.task.attemptedReconnectCount == 0)
            fixture.advance(by: 1)
        }

        #expect(actions == [.retry, .retry, .retry, .exceeded(reason: .attempts)])
    }

    @Test("A connection that stays open for the stability interval starts a fresh budget")
    func stableConnectionResetsBudget() async {
        let fixture = makeFixture(maxReconnectAttempts: 3)

        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
        #expect(await fixture.task.attemptedReconnectCount == 2)

        await fixture.coordinator.connectionDidOpen(task: fixture.task)
        fixture.advance(by: 10)

        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
        #expect(await fixture.task.attemptedReconnectCount == 1)
    }

    @Test("A drop just short of the stability interval continues the earlier budget")
    func shortLivedConnectionContinuesBudget() async {
        let fixture = makeFixture(maxReconnectAttempts: 3)

        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)

        await fixture.coordinator.connectionDidOpen(task: fixture.task)
        fixture.advance(by: 9.9)

        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
        #expect(await fixture.task.attemptedReconnectCount == 3)
        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .exceeded(reason: .attempts))
    }

    @Test("A zero stability interval resets the budget on every opened connection")
    func zeroIntervalKeepsLegacyReset() async {
        let fixture = makeFixture(maxReconnectAttempts: 1, stabilityInterval: 0)

        for _ in 0..<5 {
            #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
            await fixture.coordinator.connectionDidOpen(task: fixture.task)
            fixture.advance(by: 0.1)
        }
    }

    @Test("Short-lived connections keep the reconnect window running")
    func flappingConnectionKeepsReconnectWindow() async {
        let fixture = makeFixture(maxReconnectAttempts: 1_000, reconnectMaxTotalDuration: 5)

        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
        for _ in 0..<5 {
            await fixture.coordinator.connectionDidOpen(task: fixture.task)
            #expect(await fixture.task.reconnectWindowStartedAt == nil)
            fixture.advance(by: 1)
            guard await fixture.coordinator.reconnectAction(task: fixture.task) == .retry else { break }
        }

        // Five seconds of open-then-drop cycles spend the five-second window
        // even though every reconnect "succeeded".
        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .exceeded(reason: .duration))
    }

    @Test("A wall-clock correction neither spends nor refills the reconnect window")
    func wallClockCorrectionLeavesReconnectWindowAlone() async {
        let clock = WallClockCorrectingClock(base: TestClock(epoch: Self.start))
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0,
                reconnectJitterRatio: 0,
                maxReconnectAttempts: 1_000,
                reconnectMaxTotalDuration: 5
            ),
            runtimeRegistry: WebSocketRuntimeRegistry(),
            clock: clock
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/wall-clock")!)

        #expect(await coordinator.reconnectAction(task: task) == .retry)
        // The wall clock jumps an hour ahead: the window must not expire.
        clock.correct(by: 3_600)
        #expect(await coordinator.reconnectAction(task: task) == .retry)
        // It jumps back two hours while five real seconds pass: the window
        // must expire on schedule instead of gaining an hour.
        clock.correct(by: -7_200)
        clock.base.advance(by: .seconds(5))
        #expect(await coordinator.reconnectAction(task: task) == .exceeded(reason: .duration))
    }

    @Test("Reset discards the budget carried across a short connection")
    func resetDiscardsCarriedBudget() async {
        let fixture = makeFixture(maxReconnectAttempts: 2)

        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
        await fixture.coordinator.connectionDidOpen(task: fixture.task)
        await fixture.task.reset()
        fixture.advance(by: 1)

        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
        #expect(await fixture.task.attemptedReconnectCount == 1)
    }

    @Test("An infinite stability interval never resets the budget, so attempts cap the task's lifetime")
    func infiniteIntervalNeverResets() async {
        let fixture = makeFixture(maxReconnectAttempts: 2, stabilityInterval: .infinity)

        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
        await fixture.coordinator.connectionDidOpen(task: fixture.task)
        fixture.advance(by: 86_400)
        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .retry)
        await fixture.coordinator.connectionDidOpen(task: fixture.task)
        fixture.advance(by: 86_400)

        #expect(await fixture.coordinator.reconnectAction(task: fixture.task) == .exceeded(reason: .attempts))
    }

    @Test("The reconnect pack carries the stability interval and normalizes invalid values")
    func packPlumbsStabilityInterval() {
        let configured = WebSocketConfiguration.advanced(
            reconnect: WebSocketReconnectPack(stabilityInterval: 42)
        )
        let negative = WebSocketConfiguration.advanced(
            reconnect: WebSocketReconnectPack(stabilityInterval: -1)
        )
        let infinite = WebSocketConfiguration.advanced(
            reconnect: WebSocketReconnectPack(stabilityInterval: .infinity)
        )
        let notANumber = WebSocketConfiguration.advanced(
            reconnect: WebSocketReconnectPack(stabilityInterval: .nan)
        )

        #expect(configured.reconnectStabilityInterval == 42)
        #expect(negative.reconnectStabilityInterval == 0)
        // Infinity keeps its meaning, never stable, instead of becoming 0.
        #expect(infinite.reconnectStabilityInterval == .infinity)
        #expect(notANumber.reconnectStabilityInterval == 10)
        #expect(WebSocketConfiguration.safeDefaults().reconnectStabilityInterval == 10)
        #expect(WebSocketConfiguration.advanced().reconnectStabilityInterval == 10)
    }
}

/// Moves only the wall clock, as an NTP or manual time correction does,
/// while the monotonic clock keeps following `base`.
private final class WallClockCorrectingClock: InnoNetworkClock, Sendable {
    let base: TestClock
    private let correction = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    init(base: TestClock) {
        self.base = base
    }

    func correct(by interval: TimeInterval) {
        correction.withLock { $0 += interval }
    }

    func sleep(for duration: Duration) async throws {
        try await base.sleep(for: duration)
    }

    func now() -> Date {
        base.now().addingTimeInterval(correction.withLock { $0 })
    }

    func monotonicNow() -> Duration {
        base.monotonicNow()
    }
}
