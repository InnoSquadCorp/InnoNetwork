import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

@Suite("WebSocket Reconnect Hardening Tests")
struct WebSocketReconnectHardeningTests {

    @Test("Reconnect delay never collapses below the configured floor when count == 0")
    func reconnectDelayClampedAtCountZero() async {
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

        let task = WebSocketTask(url: URL(string: "wss://example.invalid/zero")!)
        await task.restoreStateForTesting(.disconnected)
        // Note: do *not* increment attemptedReconnectCount before kicking off
        // the schedule — the coordinator must defend against the count==0
        // pow(2, -1) underflow.

        let startCalled = OSAllocatedUnfairLock<Bool>(initialState: false)
        await coordinator.attemptReconnect(task: task) { _ in
            startCalled.withLock { $0 = true }
        }

        #expect(await clock.waitForWaiters(count: 1))
        // 0.5s would be enough only if the underflow leaked; 1.0s is the
        // configured floor.
        clock.advance(by: .seconds(0.999))
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(startCalled.withLock { $0 } == false, "delay collapsed below configured floor")

        clock.advance(by: .seconds(0.001))
        let dispatched = await waitForCondition(timeout: 1.0) {
            startCalled.withLock { $0 }
        }
        #expect(dispatched)
        await registry.cancelReconnectTask(for: task.id)
    }

    @Test("randomOffset is always invoked with lowerBound <= upperBound")
    func randomOffsetBoundsAreOrdered() async {
        let registry = WebSocketRuntimeRegistry()
        // Force a configuration where jitter dominates the cap so any
        // floating-point round-off in the (cappedBase - jitter) lower bound
        // would otherwise push it above the upper bound.
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 1.0,
                reconnectJitterRatio: 1.0,
                maxReconnectDelay: 0.5,
                maxReconnectAttempts: 20
            ),
            runtimeRegistry: registry,
            clock: TestClock(),
            randomOffset: { range in
                #expect(
                    range.lowerBound <= range.upperBound,
                    "randomOffset received inverted bounds: \(range.lowerBound)...\(range.upperBound)"
                )
                return range.lowerBound
            }
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/bounds")!)
        for _ in 0..<10 {
            _ = await task.incrementAttemptedReconnectCount()
        }
        await task.restoreStateForTesting(.disconnected)
        await coordinator.attemptReconnect(task: task) { _ in }
        await registry.cancelReconnectTask(for: task.id)
    }

    @Test("reconnectMaxTotalDuration returns .exceeded once the cumulative budget is exhausted")
    func reconnectMaxTotalDurationEnforced() async {
        let registry = WebSocketRuntimeRegistry()
        let now = OSAllocatedUnfairLock<Date>(initialState: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0,
                reconnectJitterRatio: 0,
                maxReconnectAttempts: 1_000,
                reconnectMaxTotalDuration: 5.0
            ),
            runtimeRegistry: registry,
            dateProvider: { now.withLock { $0 } }
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/budget")!)

        let first = await coordinator.reconnectAction(task: task)
        #expect(first == .retry, "first reconnect should retry when within budget")

        // Advance the wall clock past the configured budget. The next call
        // must return .exceeded even though the per-attempt cap has not
        // been reached.
        now.withLock { $0 = $0.addingTimeInterval(5.5) }
        let second = await coordinator.reconnectAction(task: task)
        #expect(second == .exceeded(reason: .duration))
    }

    @Test("Successful reconnect clears the cumulative budget window")
    func reconnectWindowClearsAfterSuccess() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/clear")!)
        await task.beginReconnectWindowIfNeeded(now: Date(timeIntervalSince1970: 1_000))
        #expect(await task.reconnectWindowStartedAt != nil)
        await task.clearReconnectWindow()
        #expect(await task.reconnectWindowStartedAt == nil)
    }

    @Test("Calling attemptReconnect twice cancels the prior schedule before installing the new one")
    func attemptReconnectCancelsPriorSchedule() async {
        let clock = TestClock()
        let registry = WebSocketRuntimeRegistry()
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0.5,
                reconnectJitterRatio: 0,
                maxReconnectAttempts: 5
            ),
            runtimeRegistry: registry,
            clock: clock
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/swap")!)
        await task.restoreStateForTesting(.disconnected)
        _ = await task.incrementAttemptedReconnectCount()

        let startCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        await coordinator.attemptReconnect(task: task) { _ in
            startCount.withLock { $0 += 1 }
        }
        // Second attempt must cancel the first before installing itself —
        // otherwise both schedules will fire startConnection back-to-back
        // when the clock advances.
        await coordinator.attemptReconnect(task: task) { _ in
            startCount.withLock { $0 += 1 }
        }

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(1))
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(
            startCount.withLock { $0 } == 1,
            "duplicate attemptReconnect should not fire startConnection twice"
        )
        await registry.cancelReconnectTask(for: task.id)
    }

    @Test("Non-cancellation sleep failures publish a paired .error event for telemetry")
    func nonCancellationSleepFailurePublishesEvent() async {
        let registry = WebSocketRuntimeRegistry()
        let eventHub = TaskEventHub<WebSocketEvent>()
        let failingClock = ClockFailureInjector(wrapping: TestClock())
        failingClock.setFailureMode(.always(URLError(.timedOut)))
        let coordinator = WebSocketReconnectCoordinator(
            configuration: WebSocketConfiguration(
                reconnectDelay: 0.01,
                reconnectJitterRatio: 0,
                maxReconnectAttempts: 5
            ),
            runtimeRegistry: registry,
            clock: failingClock,
            eventHub: eventHub
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/event")!)
        await task.restoreStateForTesting(.disconnected)
        _ = await task.incrementAttemptedReconnectCount()

        let stream = await eventHub.stream(for: task.id)

        await coordinator.attemptReconnect(task: task) { _ in
            Issue.record("startConnection should not fire when the clock fails")
        }

        var iterator = stream.makeAsyncIterator()
        let observed = await iterator.next()
        if case .error(.unknown) = observed {
            // expected
        } else {
            Issue.record("expected .error(.unknown), got \(String(describing: observed))")
        }
        await registry.cancelReconnectTask(for: task.id)
    }
}


/// Historical reference suite — exercises the *policy* under which a
/// transport failure should (have) trigger `.error(.pingTimeout)`. Production
/// heartbeat now publishes `.pingTimeout` unconditionally on ANY send-ping
/// failure (see `WebSocketHeartbeatCoordinator`), so these cases assert
/// only the reference classifier defined locally below — they exist to
/// document which transport failures were always intended as terminal for
/// heartbeat. The unconditional production behavior is covered by the
/// broader heartbeat tests in `WebSocketLifecycleTests` /
/// `WebSocketReconnectBackoffTests`.
@Suite("WebSocket Heartbeat Classifier Reference Tests")
struct WebSocketHeartbeatHardeningTests {

    @Test("Reference classifier flags URLError.cannotConnectToHost as ping timeout")
    func cannotConnectToHostClassifiedAsTimeout() {
        #expect(callIsPingTimeout(URLError(.cannotConnectToHost)))
    }

    @Test("Reference classifier flags URLError.networkConnectionLost as ping timeout")
    func networkConnectionLostClassifiedAsTimeout() {
        #expect(callIsPingTimeout(URLError(.networkConnectionLost)))
    }

    @Test("Reference classifier flags URLError.notConnectedToInternet as ping timeout")
    func notConnectedToInternetClassifiedAsTimeout() {
        #expect(callIsPingTimeout(URLError(.notConnectedToInternet)))
    }

    @Test("Reference classifier flags URLError.cancelled as ping timeout for heartbeat purposes")
    func cancelledClassifiedAsTimeout() {
        #expect(callIsPingTimeout(URLError(.cancelled)))
    }

    @Test("Reference classifier excludes unrelated URLError codes (production publishes regardless)")
    func unrelatedURLErrorIsNotTimeout() {
        // The reference classifier returns false for these; production
        // still publishes `.error(.pingTimeout)` on any send-ping failure.
        #expect(!callIsPingTimeout(URLError(.badURL)))
        #expect(!callIsPingTimeout(URLError(.userAuthenticationRequired)))
    }

    /// Reference classifier used as the historical contract for which
    /// transport failures should publish `.error(.pingTimeout)`. The
    /// production heartbeat now publishes unconditionally on any send-ping
    /// failure, but this table-driven coverage stays useful as a regression
    /// guard for the classification policy.
    private func callIsPingTimeout(_ error: Error) -> Bool {
        if let internalError = error as? WebSocketInternalError,
            case .pingTimeout = internalError
        {
            return true
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cancelled:
                return true
            default:
                return false
            }
        }
        return false
    }
}


@Suite("WebSocket Configuration Hardening Tests")
struct WebSocketConfigurationHardeningTests {

    @Test("maximumMessageSize is clamped to at least 1 byte")
    func maximumMessageSizeClampedToOne() {
        let config = WebSocketConfiguration(maximumMessageSize: 0)
        #expect(config.maximumMessageSize == 1)

        let negativeConfig = WebSocketConfiguration(maximumMessageSize: -1024)
        #expect(negativeConfig.maximumMessageSize == 1)
    }

    @Test("reconnectMaxTotalDuration negative values are clamped to zero (disabled)")
    func reconnectMaxTotalDurationClamped() {
        let config = WebSocketConfiguration(reconnectMaxTotalDuration: -10)
        #expect(config.reconnectMaxTotalDuration == 0)
    }

    @Test("permessageDeflateEnabled defaults to false (URLSession does not advertise it)")
    func permessageDeflateDefaultsFalse() {
        let config = WebSocketConfiguration()
        #expect(config.permessageDeflateEnabled == false)
    }

    @Test("AdvancedBuilder roundtrips the new fields without loss")
    func advancedBuilderRoundtripsHardeningFields() {
        let config = WebSocketConfiguration.advanced { builder in
            builder.maximumMessageSize = 8 * 1024 * 1024
            builder.permessageDeflateEnabled = true
            builder.reconnectMaxTotalDuration = 90
        }
        #expect(config.maximumMessageSize == 8 * 1024 * 1024)
        #expect(config.permessageDeflateEnabled == true)
        #expect(config.reconnectMaxTotalDuration == 90)
    }
}


@Sendable
private func waitForCondition(
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
