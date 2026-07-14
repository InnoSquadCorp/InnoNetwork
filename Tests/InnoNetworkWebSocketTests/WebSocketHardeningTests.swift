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
        if case .error(.reconnectSleepFailed(let underlying)) = observed {
            // Verify the URLError context survived the typed wrapping so
            // observers can read the underlying clock/sleep failure instead
            // of guessing from a generic `.unknown`.
            #expect(underlying.domain == NSURLErrorDomain)
            #expect(underlying.code == URLError.timedOut.rawValue)
        } else {
            Issue.record(
                "expected .error(.reconnectSleepFailed), got \(String(describing: observed))"
            )
        }
        await registry.cancelReconnectTask(for: task.id)
    }
}


@Suite("WebSocket Manager Shutdown Tests")
struct WebSocketManagerShutdownTests {

    @Test("shutdown() delivers one terminal error to callback-only consumers")
    func shutdownDeliversTerminalErrorToCallbackOnlyConsumers() async {
        let harness = makeShutdownHarness()
        let observedErrors = OSAllocatedUnfairLock<[WebSocketError]>(initialState: [])
        await harness.manager.setOnErrorHandler { _, error in
            observedErrors.withLock { $0.append(error) }
        }

        let task = await harness.manager.connect(url: URL(string: "wss://example.invalid/handler-only")!)
        let shutdown = Task { await harness.manager.shutdown() }

        #expect(
            await harness.session.waitForInvalidation(),
            "the terminal handler must run before shutdown waits for URLSession invalidation"
        )
        #expect(observedErrors.withLock { $0 } == [WebSocketManager.managerShutdownError()])
        #expect(await task.state == .failed)

        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
        #expect(observedErrors.withLock { $0.count } == 1)
    }

    @Test("shutdown() invalidates the URLSession and cancels active sockets")
    func shutdownInvalidatesSessionAndCancelsActiveSockets() async throws {
        let harness = makeShutdownHarness()
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9001)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(url: URL(string: "wss://example.invalid/shutdown")!)
        _ = try #require(await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task))

        async let shutdown: Void = harness.manager.shutdown()
        #expect(await harness.session.waitForInvalidation())
        #expect(urlTask.didCancelUnconditionally)
        #expect(await harness.manager.task(withId: task.id) == nil)
        #expect(await harness.manager.listenerCount(for: task) == 0)

        harness.callbacks.handleInvalidation(nil)
        await shutdown
    }

    @Test("shutdown() is idempotent and concurrent callers wait for invalidation")
    func shutdownIsIdempotentAndWaitsForInvalidation() async {
        let harness = makeShutdownHarness()
        let completedCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let terminalErrorCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        await harness.manager.setOnErrorHandler { _, error in
            guard error == WebSocketManager.managerShutdownError() else { return }
            terminalErrorCount.withLock { $0 += 1 }
        }
        _ = await harness.manager.connect(url: URL(string: "wss://example.invalid/concurrent-shutdown")!)

        let first = Task {
            await harness.manager.shutdown()
            completedCount.withLock { $0 += 1 }
        }
        let second = Task {
            await harness.manager.shutdown()
            completedCount.withLock { $0 += 1 }
        }

        #expect(await harness.session.waitForInvalidation())
        #expect(completedCount.withLock { $0 } == 0)

        harness.callbacks.handleInvalidation(nil)
        await first.value
        await second.value
        #expect(completedCount.withLock { $0 } == 2)
        #expect(terminalErrorCount.withLock { $0 } == 1)
    }

    @Test("shutdown() finishes per-task event streams")
    func shutdownFinishesEventStreams() async throws {
        let harness = makeShutdownHarness()
        let task = await harness.manager.connect(url: URL(string: "wss://example.invalid/events")!)
        let stream = await harness.manager.events(for: task)
        var iterator = stream.makeAsyncIterator()

        async let shutdown: Void = harness.manager.shutdown()
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown

        // Shutdown contract: a terminal `.error(.connectionFailed)` must be
        // published before the stream ends. A nil first event would mean the
        // stream finished without any terminal signal, which silently passed
        // before; require a real event here.
        let firstEvent = try #require(await iterator.next())
        guard case .error(.connectionFailed) = firstEvent else {
            Issue.record("expected shutdown terminal error before end-of-stream, got \(firstEvent)")
            return
        }
        #expect(await iterator.next() == nil)
    }

    @Test("late delegate events do not invoke callbacks after shutdown returns")
    func lateDelegateEventsDoNotInvokeCallbacksAfterShutdown() async throws {
        let harness = makeShutdownHarness()
        let callbacks = OSAllocatedUnfairLock<[String]>(initialState: [])
        await harness.manager.setOnConnectedHandler { _, _ in
            callbacks.withLock { $0.append("connected") }
        }
        await harness.manager.setOnDisconnectedHandler { _, _ in
            callbacks.withLock { $0.append("disconnected") }
        }
        await harness.manager.setOnErrorHandler { _, error in
            if error == WebSocketManager.managerShutdownError() {
                callbacks.withLock { $0.append("shutdown-error") }
            } else {
                callbacks.withLock { $0.append("error") }
            }
        }

        let task = await harness.manager.connect(url: URL(string: "wss://example.invalid/late-delegate")!)
        let taskIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
        #expect(callbacks.withLock { $0 } == ["shutdown-error"])

        harness.manager.handleConnected(taskIdentifier: taskIdentifier, protocolName: nil)
        harness.manager.handleDisconnected(
            taskIdentifier: taskIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        harness.manager.handleError(taskIdentifier: taskIdentifier, error: URLError(.timedOut))
        for _ in 0..<5 { await Task.yield() }

        #expect(callbacks.withLock { $0 } == ["shutdown-error"])
    }

    @Test(
        "shutdown fence wins over buffered terminal delegate events",
        arguments: [BufferedTerminalDelegateEvent.mappedError, .didClose]
    )
    func shutdownFenceWinsOverBufferedTerminalDelegateEvents(
        _ bufferedEvent: BufferedTerminalDelegateEvent
    ) async throws {
        let harness = makeShutdownHarness()
        let observedErrors = OSAllocatedUnfairLock<[WebSocketError]>(initialState: [])
        let disconnectedCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        await harness.manager.setOnErrorHandler { _, error in
            observedErrors.withLock { $0.append(error) }
        }
        await harness.manager.setOnDisconnectedHandler { _, _ in
            disconnectedCount.withLock { $0 += 1 }
        }

        let task = await harness.manager.connect(url: URL(string: "wss://example.invalid/buffered-terminal")!)
        let taskIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )

        // Model the exact actor interleaving deterministically: shutdown has
        // linearized at its lock-backed fence, but the registry sweep has not
        // yet run and a terminal delegate event that was already buffered is
        // selected by the consumer. Resetting the fence afterwards is only to
        // let the public shutdown API perform normal test teardown.
        #expect(harness.manager.markShutdownIfNeeded())
        await harness.manager.processDelegateEvent(
            bufferedEvent.delegateEvent(taskIdentifier: taskIdentifier)
        )
        harness.manager.shutdownLock.withLock { $0 = false }

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value

        let shutdownError = WebSocketManager.managerShutdownError()
        #expect(await task.state == .failed)
        #expect(await task.error == shutdownError)
        #expect(observedErrors.withLock { $0 } == [shutdownError])
        #expect(disconnectedCount.withLock { $0 } == 0)
    }

    @Test("shutdown fence rejects a terminal delegate reduction already dequeued")
    func shutdownFenceRejectsAlreadyDequeuedTerminalReduction() async {
        let harness = makeShutdownHarness()
        let observedErrors = OSAllocatedUnfairLock<[WebSocketError]>(initialState: [])
        await harness.manager.setOnErrorHandler { _, error in
            observedErrors.withLock { $0.append(error) }
        }

        let task = await harness.manager.connect(url: URL(string: "wss://example.invalid/dequeued-terminal")!)
        let generation = await task.connectionGeneration

        // This models a consumer that passed processDelegateEvent's fast
        // fence check before shutdown, then suspended waiting for the task
        // actor. The reducer itself must re-enter the same fence and lose to
        // shutdown rather than applying the already-dequeued failure.
        #expect(harness.manager.markShutdownIfNeeded())
        let delegateTransition = await task.applyDelegateLifecycleEvent(
            .failure(
                generation: generation,
                disposition: .transportFailure(.pingTimeout),
                error: .pingTimeout
            ),
            context: .init(reconnectAction: .terminal),
            shutdownFence: harness.manager.shutdownLock
        )
        #expect(delegateTransition.isIgnoredCallback)
        #expect(await task.state == .connecting)
        harness.manager.shutdownLock.withLock { $0 = false }

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value

        let shutdownError = WebSocketManager.managerShutdownError()
        #expect(await task.state == .failed)
        #expect(await task.error == shutdownError)
        #expect(observedErrors.withLock { $0 } == [shutdownError])
    }

    @Test("connect after shutdown does not create a URLSession task")
    func connectAfterShutdownIsTerminalGuarded() async {
        let harness = makeShutdownHarness()
        async let shutdown: Void = harness.manager.shutdown()
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown

        let task = await harness.manager.connect(url: URL(string: "wss://example.invalid/post-shutdown")!)
        #expect(await task.state == .failed)
        #expect(harness.session.createdTasks.isEmpty)
    }

    @Test("URLSession transport rejects permessage-deflate with an unsupported diagnostic")
    func urlSessionTransportRejectsUnsupportedCompression() async {
        let harness = makeShutdownHarness(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: makeWebSocketTestSessionIdentifier("deflate"),
                permessageDeflateEnabled: true
            )
        )
        let observedError = OSAllocatedUnfairLock<WebSocketError?>(initialState: nil)
        await harness.manager.setOnErrorHandler { _, error in
            observedError.withLock { $0 = error }
        }

        let task = await harness.manager.connect(url: URL(string: "wss://example.invalid/deflate")!)

        let observed = await waitForCondition(timeout: 1.0) {
            observedError.withLock { $0 == .unsupportedProtocolFeature(.permessageDeflate) }
        }
        #expect(observed)
        #expect(await task.state == .failed)
        #expect(await task.error == .unsupportedProtocolFeature(.permessageDeflate))
        #expect(harness.session.createdTasks.isEmpty)

        async let shutdown: Void = harness.manager.shutdown()
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown
    }

    @Test("Registry refuses task registration after shutdown begins")
    func registryRefusesAddAfterShutdownStarted() async {
        let registry = WebSocketRuntimeRegistry()
        let prior = WebSocketTask(url: URL(string: "wss://example.invalid/prior")!)

        #expect(await registry.add(prior))
        let snapshot = await registry.markShutdownStartedAndSnapshot()
        #expect(snapshot.contains { $0.id == prior.id })

        let racingTask = WebSocketTask(url: URL(string: "wss://example.invalid/racing")!)
        #expect(!(await registry.add(racingTask)))
        let allTasks = await registry.allTasks()
        #expect(allTasks.count == 1)
        #expect(allTasks.first?.id == prior.id)
    }

    private func makeShutdownHarness(
        configuration: WebSocketConfiguration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 0,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("shutdown")
        )
    ) -> ShutdownHarness {
        let session = StubWebSocketURLSession()
        let callbacks = WebSocketSessionDelegateCallbacks()
        let delegate = WebSocketSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: BackgroundCompletionStore()
        )
        let manager = WebSocketManager(
            configuration: configuration,
            urlSession: session,
            delegate: delegate,
            callbacks: callbacks
        )
        return ShutdownHarness(manager: manager, session: session, callbacks: callbacks)
    }

    private struct ShutdownHarness {
        let manager: WebSocketManager
        let session: StubWebSocketURLSession
        let callbacks: WebSocketSessionDelegateCallbacks
    }

    enum BufferedTerminalDelegateEvent: Sendable {
        case mappedError
        case didClose

        func delegateEvent(taskIdentifier: Int) -> WebSocketManager.DelegateEvent {
            switch self {
            case .mappedError:
                .mappedError(taskIdentifier: taskIdentifier, error: .pingTimeout)
            case .didClose:
                .disconnected(
                    taskIdentifier: taskIdentifier,
                    closeCode: .normalClosure,
                    reason: nil
                )
            }
        }
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
