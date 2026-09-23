import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

@Suite("WebSocket reconnect deadlines", .timeLimit(.minutes(1)))
struct WebSocketReconnectDeadlineTests {
    private actor Completion {
        private var result: Bool?
        private var waiter: CheckedContinuation<Bool, Never>?
        func finish(expired: Bool) {
            result = expired
            waiter?.resume(returning: expired)
            waiter = nil
        }
        func value() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    @Test("Backoff is bounded and delayed wake-ups cannot dispatch after expiry", arguments: [false, true])
    func expiryPreventsDispatch(delayedWakeup: Bool) async throws {
        let clock = TestClock()
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: delayedWakeup ? 1 : 10, reconnectJitterRatio: 0,
                maxReconnectAttempts: 10, reconnectMaxTotalDuration: 5
            ), runtimeRegistry: registry, clock: clock, dateProvider: { clock.now() }
        )
        let task = WebSocketTask(url: try #require(URL(string: "wss://example.invalid/deadline")))
        await task.restoreStateForTesting(.reconnecting)
        #expect(await coordinator.reconnectAction(task: task) == .retry)
        let completion = Completion()
        await coordinator.attemptReconnect(
            task: task,
            onBudgetExceeded: { _ in
                await completion.finish(expired: true)
            }
        ) { _ in
            await completion.finish(expired: false)
        }
        try #require(await clock.waitForWaiters(count: 1))
        if delayedWakeup {
            clock.advanceWithoutResuming(by: .seconds(6))
            clock.advance(by: .zero)
        } else {
            clock.advance(by: .seconds(5))
        }
        #expect(await completion.value())
        await registry.cancelReconnectTask(for: task.id)
        #expect(clock.waiterCount == 0)
    }

    @Test("Reconnect inside the window still dispatches")
    func inBudgetDispatch() async throws {
        let clock = TestClock()
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 1, reconnectJitterRatio: 0,
                maxReconnectAttempts: 10, reconnectMaxTotalDuration: 5
            ), runtimeRegistry: registry, clock: clock, dateProvider: { clock.now() }
        )
        let task = WebSocketTask(url: try #require(URL(string: "wss://example.invalid/control")))
        await task.restoreStateForTesting(.reconnecting)
        _ = await coordinator.reconnectAction(task: task)
        let completion = Completion()
        await coordinator.attemptReconnect(
            task: task,
            onBudgetExceeded: { _ in
                await completion.finish(expired: true)
            }
        ) { _ in
            await completion.finish(expired: false)
        }
        try #require(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(1))
        #expect(await completion.value() == false)
        await registry.cancelReconnectTask(for: task.id)
    }

    @Test("Expiry produces one terminal transition and ignores subsequent callbacks")
    func expiryIsTerminal() {
        let state = WebSocketLifecycleState.reconnecting(
            generation: 3, attempt: 1, autoReconnect: true,
            closeCode: nil, disposition: nil, error: nil
        )
        let transition = WebSocketLifecycleReducer.reduce(state: state, event: .reconnectWindowExpired)
        #expect(transition.state.publicState == .failed)
        #expect(transition.effects.contains(.cancelReconnect))
        #expect(transition.effects.contains(.publishTerminalError(.reconnectWindowExceeded)))
        #expect(transition.effects.contains(.finishTerminal(generation: 3)))
        let repeated = WebSocketLifecycleReducer.reduce(state: transition.state, event: .reconnectWindowExpired)
        #expect(repeated.isIgnoredCallback)
        let lateTimer = WebSocketLifecycleReducer.reduce(state: transition.state, event: .reconnectTimerFired)
        #expect(lateTimer.isIgnoredCallback)
    }
}
