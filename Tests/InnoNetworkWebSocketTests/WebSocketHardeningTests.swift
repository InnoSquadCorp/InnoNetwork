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
            "shutdown must promptly invalidate the transport before awaiting full cleanup"
        )
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value

        #expect(observedErrors.withLock { $0 } == [WebSocketManager.managerShutdownError()])
        #expect(await task.state == .failed)
    }

    @Test("shutdown overrides an in-progress manual close with its terminal error")
    func shutdownOverridesInProgressManualClose() async {
        let harness = makeShutdownHarness()
        let observedErrors = OSAllocatedUnfairLock<[WebSocketError]>(initialState: [])
        await harness.manager.setOnErrorHandler { _, error in
            observedErrors.withLock { $0.append(error) }
        }
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/shutdown-during-manual-close")!
        )
        await task.restoreStateForTesting(.disconnecting)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value

        let shutdownError = WebSocketManager.managerShutdownError()
        #expect(await task.state == .failed)
        #expect(await task.error == shutdownError)
        #expect(observedErrors.withLock { $0 } == [shutdownError])
        #expect(await harness.manager.task(withId: task.id) == nil)
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
        harness.callbacks.handleInvalidation(nil)
        await shutdown

        #expect(urlTask.didCancelUnconditionally)
        #expect(await harness.manager.task(withId: task.id) == nil)
        #expect(await harness.manager.listenerCount(for: task) == 0)
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

        // Model the buffered-event boundary deterministically: shutdown has
        // closed delegate admission, but the registry sweep has not yet run.
        // Resetting the flag afterwards is only to let the public shutdown API
        // perform normal test teardown.
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

    @Test("shutdown drains an accepted delegate transaction before terminal cleanup")
    func shutdownDrainsAcceptedDelegateTransactionBeforeCleanup() async throws {
        let harness = makeShutdownHarness()
        let connectedGate = ShutdownDelegateGate()
        await harness.manager.setOnConnectedHandler { _, _ in
            await connectedGate.arriveAndWait()
        }

        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/accepted-delegate")!
        )
        let taskIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: taskIdentifier, protocolName: "chat")
        await connectedGate.waitForArrival()

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())

        // Transport invalidation is prompt, but task cleanup must wait until
        // the delegate transaction that entered before shutdown is complete.
        #expect(await task.state == .connected)
        #expect(await task.error == nil)
        #expect(await harness.manager.task(withId: task.id) === task)

        await connectedGate.release()
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value

        let shutdownError = WebSocketManager.managerShutdownError()
        #expect(await task.state == .failed)
        #expect(await task.error == shutdownError)
        #expect(await harness.manager.task(withId: task.id) == nil)
    }

    @Test("shutdown waits for an operation admitted before its terminal snapshot")
    func shutdownWaitsForAdmittedOperation() async {
        let harness = makeShutdownHarness()
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/admitted-operation")!
        )
        #expect(await harness.manager.beginShutdownTrackedOperation())

        let shutdownReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let shutdown = Task {
            await harness.manager.shutdown()
            shutdownReturned.withLock { $0 = true }
        }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)

        #expect(
            !(await waitForCondition(timeout: 0.1) {
                shutdownReturned.withLock { $0 }
            })
        )

        await harness.manager.finishShutdownTrackedOperation()
        await shutdown.value
        #expect(shutdownReturned.withLock { $0 })
        #expect(await task.state == .failed)
    }

    @Test("internal timer transactions are rejected after shutdown admission")
    func internalTimerTransactionsAreRejectedAfterShutdownAdmission() async {
        let harness = makeShutdownHarness()
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/timer-admission")!
        )
        await task.restoreStateForTesting(.disconnecting)

        #expect(harness.manager.markShutdownIfNeeded())
        await harness.manager.handleCloseHandshakeTimeout(
            taskID: task.id,
            closeCode: .goingAway
        )
        #expect(await task.state == .disconnecting)
        #expect(await task.closeDisposition == nil)

        await task.restoreStateForTesting(.reconnecting)
        await harness.manager.startReconnecting(task)
        #expect(await task.state == .reconnecting)

        // The direct admission marker above did not launch teardown. Restore
        // it only so the public shutdown API can perform ordinary cleanup.
        harness.manager.shutdownLock.withLock { $0 = false }
        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("onConnected can initiate shutdown without awaiting its own delegate consumer")
    func connectedHandlerCanInitiateShutdown() async throws {
        let harness = makeShutdownHarness()
        let nestedShutdownReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        await harness.manager.setOnConnectedHandler { [manager = harness.manager] _, _ in
            await manager.shutdown()
            nestedShutdownReturned.withLock { $0 = true }
        }

        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/reentrant-connected-shutdown")!
        )
        let taskIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: taskIdentifier, protocolName: nil)

        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        #expect(await waitForCondition(timeout: 1.0) { nestedShutdownReturned.withLock { $0 } })

        // This external call observes the strong completion boundary after the
        // callback-originated call has returned to let its worker unwind.
        await harness.manager.shutdown()
        #expect(await task.state == .failed)
        #expect(await harness.manager.task(withId: task.id) == nil)
    }

    @Test("onMessage can initiate shutdown without awaiting its own listener task")
    func messageHandlerCanInitiateShutdown() async throws {
        let harness = makeShutdownHarness()
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_102)
        harness.session.enqueue(urlTask)
        let nestedShutdownReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        await harness.manager.setOnMessageHandler { [manager = harness.manager] _, _ in
            await manager.shutdown()
            nestedShutdownReturned.withLock { $0 = true }
        }

        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/reentrant-message-shutdown")!
        )
        let taskIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: taskIdentifier, protocolName: nil)
        #expect(await waitForWebSocketState(task) { $0 == .connected })
        urlTask.scriptReceive(.success(.data(Data("shutdown".utf8))))

        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        #expect(await waitForCondition(timeout: 1.0) { nestedShutdownReturned.withLock { $0 } })

        await harness.manager.shutdown()
        #expect(await task.state == .failed)
        #expect(await harness.manager.task(withId: task.id) == nil)
    }

    @Test("shutdown error handler can reenter shutdown without blocking invalidation")
    func shutdownErrorHandlerCanReenterShutdown() async {
        let harness = makeShutdownHarness()
        let nestedShutdownReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        await harness.manager.setOnErrorHandler { [manager = harness.manager] _, error in
            guard error == WebSocketManager.managerShutdownError() else { return }
            await manager.shutdown()
            nestedShutdownReturned.withLock { $0 = true }
        }
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/reentrant-error-shutdown")!
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value

        #expect(
            await waitForCondition(timeout: 1.0) {
                nestedShutdownReturned.withLock { $0 }
            }
        )
        #expect(await task.state == .failed)
        #expect(await harness.manager.task(withId: task.id) == nil)
    }

    @Test("shutdown error event listener can reenter shutdown without blocking cleanup")
    func shutdownErrorEventListenerCanReenterShutdown() async {
        let harness = makeShutdownHarness()
        let nestedShutdownReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/reentrant-error-listener-shutdown")!
        )
        _ = await harness.manager.addEventListener(for: task) { [manager = harness.manager] event in
            guard case .error(let error) = event,
                error == WebSocketManager.managerShutdownError()
            else { return }
            await manager.shutdown()
            nestedShutdownReturned.withLock { $0 = true }
        }

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value

        #expect(
            await waitForCondition(timeout: 1.0) {
                nestedShutdownReturned.withLock { $0 }
            }
        )
        #expect(await task.state == .failed)
        #expect(await harness.manager.task(withId: task.id) == nil)
    }

    @Test("external shutdown waits for an active onPong callback to drain")
    func externalShutdownWaitsForActivePongCallback() async throws {
        let harness = makeShutdownHarness()
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_103)
        harness.session.enqueue(urlTask)
        let callbackGate = ShutdownDelegateGate()
        let nestedShutdownReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        await harness.manager.setOnPongHandler { [manager = harness.manager] _, _ in
            await manager.shutdown()
            nestedShutdownReturned.withLock { $0 = true }
            await callbackGate.arriveAndWait()
        }

        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/reentrant-pong-shutdown")!
        )
        let taskIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: taskIdentifier, protocolName: nil)
        #expect(await waitForWebSocketState(task) { $0 == .connected })

        let ping = Task {
            try await harness.manager.ping(task)
        }
        #expect(await waitForCondition(timeout: 1.0) { urlTask.hasPendingPong })
        urlTask.completePendingPong(with: nil)
        await callbackGate.waitForArrival()

        #expect(nestedShutdownReturned.withLock { $0 })
        #expect(await harness.session.waitForInvalidation())

        let externalShutdownReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let externalShutdown = Task {
            await harness.manager.shutdown()
            externalShutdownReturned.withLock { $0 = true }
        }
        harness.callbacks.handleInvalidation(nil)

        // Even after URLSession invalidation finishes, the strong external
        // boundary remains closed while the already-admitted callback runs.
        #expect(
            !(await waitForCondition(timeout: 0.25) {
                externalShutdownReturned.withLock { $0 }
            })
        )

        await callbackGate.release()
        try await ping.value
        await externalShutdown.value

        #expect(externalShutdownReturned.withLock { $0 })
        #expect(await task.state == .failed)
        #expect(await harness.manager.task(withId: task.id) == nil)
    }

    @Test("handler registration is terminal once shutdown admission closes")
    func handlerRegistrationIsRejectedAfterShutdownStarts() async {
        let harness = makeShutdownHarness()
        let callbackCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/late-handler-registration")!
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        await harness.manager.setOnErrorHandler { _, _ in
            callbackCount.withLock { $0 += 1 }
        }
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value

        // Exercise the registry notification boundary directly: a late setter
        // must not survive the terminal clear even if another internal worker
        // attempts to notify after shutdown.
        await harness.manager.runtimeRegistry.notifyError(task, error: .pingTimeout)
        #expect(callbackCount.withLock { $0 } == 0)

        _ = await harness.manager.addEventListener(for: task) { _ in
            callbackCount.withLock { $0 += 1 }
        }
        await harness.manager.eventHub.publishAndWaitForDelivery(.error(.pingTimeout), for: task.id)
        #expect(callbackCount.withLock { $0 } == 0)

        let lateStream = await harness.manager.events(for: task)
        var iterator = lateStream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("terminal registry removal rejects new listeners and streams before manager shutdown")
    func terminalTaskRejectsNewEventConsumers() async {
        let harness = makeShutdownHarness()
        let callbackCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/terminal-event-registration")!
        )
        await harness.manager.finishTaskBecauseManagerIsShutdown(task)
        #expect(await harness.manager.task(withId: task.id) == nil)

        _ = await harness.manager.addEventListener(for: task) { _ in
            callbackCount.withLock { $0 += 1 }
        }
        #expect(await harness.manager.listenerCount(for: task) == 0)
        #expect(callbackCount.withLock { $0 } == 0)

        let stream = await harness.manager.events(for: task)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("terminal cleanup drains admitted consumer registration before closing the partition")
    func terminalCleanupDrainsAdmittedConsumerRegistration() async throws {
        let harness = makeShutdownHarness()
        let callbackCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let cleanupReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/terminal-registration-race")!
        )

        // Model a public registration that passed manager admission and then
        // suspended before its cross-actor EventHub installation completed.
        #expect(await harness.manager.beginEventConsumerRegistration(taskID: task.id))
        let cleanup = Task {
            await harness.manager.finishTaskBecauseManagerIsShutdown(task)
            cleanupReturned.withLock { $0 = true }
        }

        let deadline = ContinuousClock.now + .seconds(1)
        while !(await harness.manager.isEventConsumerAdmissionClosed(taskID: task.id)),
            ContinuousClock.now < deadline
        {
            await Task.yield()
        }
        try #require(await harness.manager.isEventConsumerAdmissionClosed(taskID: task.id))
        #expect(!cleanupReturned.withLock { $0 })

        _ = await harness.manager.eventHub.addListener(taskID: task.id) { _ in
            callbackCount.withLock { $0 += 1 }
        }
        await harness.manager.finishEventConsumerRegistration(taskID: task.id)
        await cleanup.value

        #expect(cleanupReturned.withLock { $0 })
        #expect(await harness.manager.listenerCount(for: task) == 0)
        #expect(!(await harness.manager.isEventConsumerAdmissionClosed(taskID: task.id)))
        #expect(callbackCount.withLock { $0 } == 0)

        let lateStream = await harness.manager.events(for: task)
        var iterator = lateStream.makeAsyncIterator()
        #expect(await iterator.next() == nil)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("nested callbacks preserve outer-manager shutdown reentrancy")
    func nestedCallbacksPreserveOuterManagerReentrancy() async throws {
        let outer = makeShutdownHarness()
        let inner = makeShutdownHarness()
        let innerTask = WebSocketTask(
            url: URL(string: "wss://example.invalid/nested-inner-callback")!
        )
        let nestedShutdownReturned = OSAllocatedUnfairLock<Bool>(initialState: false)

        await inner.manager.setOnPongHandler { [outerManager = outer.manager] _, _ in
            await outerManager.shutdown()
            nestedShutdownReturned.withLock { $0 = true }
        }
        await outer.manager.setOnConnectedHandler { [innerManager = inner.manager] _, _ in
            await innerManager.runtimeRegistry.notifyPong(
                innerTask,
                context: WebSocketPongContext(attemptNumber: 1, roundTrip: .zero)
            )
        }

        let outerTask = await outer.manager.connect(
            url: URL(string: "wss://example.invalid/nested-outer-callback")!
        )
        let taskIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: outer.manager, task: outerTask)
        )
        outer.manager.handleConnected(taskIdentifier: taskIdentifier, protocolName: nil)

        #expect(await outer.session.waitForInvalidation())
        outer.callbacks.handleInvalidation(nil)
        #expect(await waitForCondition(timeout: 1.0) { nestedShutdownReturned.withLock { $0 } })
        await outer.manager.shutdown()

        #expect(await outerTask.state == .failed)
        #expect(await outer.manager.task(withId: outerTask.id) == nil)

        let innerShutdown = Task { await inner.manager.shutdown() }
        #expect(await inner.session.waitForInvalidation())
        inner.callbacks.handleInvalidation(nil)
        await innerShutdown.value
    }

    @Test("reciprocal manager shutdown preserves the complete callback ancestry")
    func reciprocalManagerShutdownPreservesCallbackAncestry() async throws {
        let first = makeShutdownHarness()
        let second = makeShutdownHarness()
        let firstNestedShutdownReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let secondNestedShutdownReturned = OSAllocatedUnfairLock<Bool>(initialState: false)

        await first.manager.setOnErrorHandler { [secondManager = second.manager] _, error in
            guard error == WebSocketManager.managerShutdownError() else { return }
            await secondManager.shutdown()
            secondNestedShutdownReturned.withLock { $0 = true }
        }
        await second.manager.setOnConnectedHandler { [firstManager = first.manager] _, _ in
            await firstManager.shutdown()
            firstNestedShutdownReturned.withLock { $0 = true }
        }

        let firstTask = await first.manager.connect(
            url: URL(string: "wss://example.invalid/reciprocal-first")!
        )
        let secondTask = await second.manager.connect(
            url: URL(string: "wss://example.invalid/reciprocal-second")!
        )
        let secondIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: second.manager, task: secondTask)
        )
        second.manager.handleConnected(taskIdentifier: secondIdentifier, protocolName: nil)

        #expect(await first.session.waitForInvalidation())
        first.callbacks.handleInvalidation(nil)
        #expect(await second.session.waitForInvalidation())
        second.callbacks.handleInvalidation(nil)

        try #require(
            await waitForCondition(timeout: 1.0) {
                firstNestedShutdownReturned.withLock { $0 }
                    && secondNestedShutdownReturned.withLock { $0 }
            }
        )
        await first.manager.shutdown()
        await second.manager.shutdown()

        #expect(await firstTask.state == .failed)
        #expect(await secondTask.state == .failed)
        #expect(await first.manager.task(withId: firstTask.id) == nil)
        #expect(await second.manager.task(withId: secondTask.id) == nil)
    }

    @Test("handshake adapter can initiate shutdown without waiting on its connect operation")
    func handshakeAdapterCanInitiateShutdown() async throws {
        let managerBox = OSAllocatedUnfairLock<WebSocketManager?>(initialState: nil)
        let adapterReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 0,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("adapter-shutdown"),
            handshakeRequestAdapters: [
                WebSocketHandshakeRequestAdapter { request in
                    guard let manager = managerBox.withLock({ $0 }) else { return request }
                    await manager.shutdown()
                    adapterReturned.withLock { $0 = true }
                    return request
                }
            ]
        )
        let harness = makeShutdownHarness(configuration: configuration)
        managerBox.withLock { $0 = harness.manager }

        let connect = Task {
            await harness.manager.connect(
                url: URL(string: "wss://example.invalid/adapter-shutdown")!
            )
        }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        try #require(
            await waitForCondition(timeout: 1.0) {
                adapterReturned.withLock { $0 }
            }
        )

        let task = await connect.value
        await harness.manager.shutdown()
        #expect(harness.session.createdTasks.isEmpty)
        #expect(await task.state == .failed)
        #expect(await harness.manager.task(withId: task.id) == nil)
    }

    @Test("disconnect during handshake adaptation cannot create stale transport")
    func disconnectDuringHandshakeAdaptationRejectsTransport() async throws {
        let adapterGate = ShutdownDelegateGate()
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 0,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("adapter-disconnect"),
            handshakeRequestAdapters: [
                WebSocketHandshakeRequestAdapter { request in
                    await adapterGate.arriveAndWait()
                    return request
                }
            ]
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let connect = Task {
            await harness.manager.connect(
                url: URL(string: "wss://example.invalid/adapter-disconnect")!
            )
        }

        await adapterGate.waitForArrival()
        var connectingTask: WebSocketTask?
        let deadline = ContinuousClock.now + .seconds(1)
        while connectingTask == nil, ContinuousClock.now < deadline {
            connectingTask = await harness.manager.allTasks().first
            if connectingTask == nil { await Task.yield() }
        }
        let task = try #require(connectingTask)
        await harness.manager.disconnect(task)
        await adapterGate.release()

        _ = await connect.value
        #expect(harness.session.createdTasks.isEmpty)
        #expect(await task.state == .disconnected)
        #expect(await harness.manager.task(withId: task.id) == nil)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("late manual pong cannot publish into a fresh retry task")
    func lateManualPongDoesNotCrossFreshRetryTask() async throws {
        let harness = makeShutdownHarness()
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_201)
        harness.session.enqueue(firstURLTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/late-manual-pong")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: firstIdentifier, protocolName: nil)
        let connectedDeadline = ContinuousClock.now + .seconds(1)
        while await task.state != .connected, ContinuousClock.now < connectedDeadline {
            await Task.yield()
        }
        try #require(await task.state == .connected)

        let ping = Task { try await harness.manager.ping(task) }
        try #require(
            await waitForCondition(timeout: 1.0) {
                firstURLTask.hasPendingPong
            }
        )

        await harness.manager.disconnect(task)
        harness.manager.handleDisconnected(
            taskIdentifier: firstIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        try #require(
            await waitForCondition(timeout: 1.0) {
                firstURLTask.cancelledCloseCode != nil
            }
        )
        let removalDeadline = ContinuousClock.now + .seconds(1)
        while await harness.manager.task(withId: task.id) != nil,
            ContinuousClock.now < removalDeadline
        {
            await Task.yield()
        }
        try #require(await harness.manager.task(withId: task.id) == nil)

        let retriedURLTask = StubWebSocketURLTask(taskIdentifier: 9_202)
        harness.session.enqueue(retriedURLTask)
        let retryResult = try #require(await harness.manager.retry(task))
        let replacement = retryResult.task
        let staleEventCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        _ = await harness.manager.addEventListener(for: replacement) { event in
            if case .pong = event {
                staleEventCount.withLock { $0 += 1 }
            }
        }

        firstURLTask.completePendingPong(with: nil)
        _ = await ping.result
        #expect(staleEventCount.withLock { $0 } == 0)
        #expect(replacement.id != task.id)
        #expect(await task.state == .disconnected)
        #expect(await harness.manager.task(withId: task.id) == nil)
        #expect(await replacement.connectionGeneration == 1)
        #expect(
            await harness.manager.runtimeTaskIdentifier(for: replacement)
                == retriedURLTask.taskIdentifier
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("retry waits for old-generation runtime cleanup before installing transport")
    func retryWaitsForOldGenerationRuntimeCleanup() async throws {
        let harness = makeShutdownHarness()
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_211)
        harness.session.enqueue(firstURLTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/retry-cleanup-fence")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: firstIdentifier, protocolName: nil)
        let connectedDeadline = ContinuousClock.now + .seconds(1)
        while await task.state != .connected, ContinuousClock.now < connectedDeadline {
            await Task.yield()
        }
        try #require(await task.state == .connected)

        let cleanupGate = ShutdownDelegateGate()
        let blockingRuntimeTask = Task {
            await cleanupGate.arriveAndWait()
        }
        await harness.manager.runtimeRegistry.setMessageListenerTask(
            blockingRuntimeTask,
            for: task.id
        )
        await cleanupGate.waitForArrival()

        harness.manager.handleError(
            taskIdentifier: firstIdentifier,
            error: URLError(.cannotConnectToHost)
        )
        let terminalDeadline = ContinuousClock.now + .seconds(1)
        while await task.state != .failed, ContinuousClock.now < terminalDeadline {
            await Task.yield()
        }
        try #require(await task.state == .failed)
        let detachedDeadline = ContinuousClock.now + .seconds(1)
        while await harness.manager.runtimeTaskIdentifier(for: task) != nil,
            ContinuousClock.now < detachedDeadline
        {
            await Task.yield()
        }
        try #require(await harness.manager.runtimeTaskIdentifier(for: task) == nil)

        let retryURLTask = StubWebSocketURLTask(taskIdentifier: 9_212)
        harness.session.enqueue(retryURLTask)
        let retryReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let retry = Task {
            let replacement = await harness.manager.retry(task)
            retryReturned.withLock { $0 = true }
            return replacement
        }
        #expect(
            !(await waitForCondition(timeout: 0.05) {
                retryReturned.withLock { $0 }
            })
        )
        #expect(harness.session.createdTasks.count == 1)

        await cleanupGate.release()
        let retryResult = try #require(await retry.value)
        let replacement = retryResult.task
        #expect(retryReturned.withLock { $0 })
        #expect(harness.session.createdTasks.count == 2)
        #expect(replacement.id != task.id)
        #expect(await task.state == .failed)
        #expect(
            await harness.manager.runtimeTaskIdentifier(for: replacement)
                == retryURLTask.taskIdentifier
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("blocked terminal listener stays isolated from a fresh retry task")
    func blockedTerminalListenerCannotAffectFreshRetryTask() async throws {
        let harness = makeShutdownHarness()
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_221)
        let replacementURLTask = StubWebSocketURLTask(taskIdentifier: 9_222)
        harness.session.enqueue(firstURLTask)
        let source = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/blocked-terminal-listener")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: source)
        )
        harness.manager.handleConnected(taskIdentifier: firstIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(source) { $0 == .connected })

        let oldListenerGate = ShutdownDelegateGate()
        let oldListenerTerminalCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let oldListenerConnectedCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let oldStreamTerminalCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let oldStreamConnectedCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let staleListenerActionReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let staleListenerRetryWasNil = OSAllocatedUnfairLock<Bool>(initialState: false)

        _ = await harness.manager.addEventListener(for: source) { [manager = harness.manager] event in
            switch event {
            case .connected:
                oldListenerConnectedCount.withLock { $0 += 1 }
            case .disconnected, .error:
                oldListenerTerminalCount.withLock { $0 += 1 }
                await oldListenerGate.arriveAndWait()
                await manager.disconnect(source)
                let staleReplacement = await manager.retry(source)
                staleListenerRetryWasNil.withLock { $0 = staleReplacement == nil }
                staleListenerActionReturned.withLock { $0 = true }
            default:
                break
            }
        }
        let oldStream = await harness.manager.events(for: source)
        let oldStreamConsumer = Task {
            for await event in oldStream {
                switch event {
                case .connected:
                    oldStreamConnectedCount.withLock { $0 += 1 }
                case .disconnected, .error:
                    oldStreamTerminalCount.withLock { $0 += 1 }
                default:
                    break
                }
            }
        }

        harness.manager.handleDisconnected(
            taskIdentifier: firstIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        await oldListenerGate.waitForArrival()
        try #require(await waitForWebSocketTaskRemoval(manager: harness.manager, task: source))
        await oldStreamConsumer.value
        let oldListenerConnectedBeforeRetry = oldListenerConnectedCount.withLock { $0 }
        let oldStreamConnectedBeforeRetry = oldStreamConnectedCount.withLock { $0 }
        let terminalGeneration = await source.connectionGeneration
        let terminalError = await source.error
        let terminalCloseCode = await source.closeCode
        let terminalDisposition = await source.closeDisposition
        #expect(await source.state == .disconnected)

        harness.session.enqueue(replacementURLTask)
        let retryResult = try #require(await harness.manager.retry(source))
        let replacement = retryResult.task
        let replacementIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(
                manager: harness.manager,
                task: replacement
            )
        )
        #expect(replacement.id != source.id)
        #expect(replacementIdentifier == replacementURLTask.taskIdentifier)

        let newListenerConnectedCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let newListenerTerminalCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let newStreamConnectedCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let newStreamTerminalCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        _ = await harness.manager.addEventListener(for: replacement) { event in
            switch event {
            case .connected:
                newListenerConnectedCount.withLock { $0 += 1 }
            case .disconnected, .error:
                newListenerTerminalCount.withLock { $0 += 1 }
            default:
                break
            }
        }
        let newStream = await harness.manager.events(for: replacement)
        let newStreamConsumer = Task {
            for await event in newStream {
                switch event {
                case .connected:
                    newStreamConnectedCount.withLock { $0 += 1 }
                    return
                case .disconnected, .error:
                    newStreamTerminalCount.withLock { $0 += 1 }
                default:
                    break
                }
            }
        }

        harness.manager.handleConnected(taskIdentifier: replacementIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(replacement) { $0 == .connected })
        try #require(
            await waitForCondition(timeout: 1.0) {
                newListenerConnectedCount.withLock { $0 } == 1
                    && newStreamConnectedCount.withLock { $0 } == 1
            }
        )

        await oldListenerGate.release()
        try #require(
            await waitForCondition(timeout: 1.0) {
                staleListenerActionReturned.withLock { $0 }
            }
        )
        await newStreamConsumer.value

        #expect(staleListenerRetryWasNil.withLock { $0 })
        #expect(oldListenerTerminalCount.withLock { $0 } == 1)
        #expect(oldStreamTerminalCount.withLock { $0 } == 1)
        #expect(oldListenerConnectedCount.withLock { $0 } == oldListenerConnectedBeforeRetry)
        #expect(oldStreamConnectedCount.withLock { $0 } == oldStreamConnectedBeforeRetry)
        #expect(newListenerConnectedCount.withLock { $0 } == 1)
        #expect(newStreamConnectedCount.withLock { $0 } == 1)
        #expect(newListenerTerminalCount.withLock { $0 } == 0)
        #expect(newStreamTerminalCount.withLock { $0 } == 0)
        #expect(await source.connectionGeneration == terminalGeneration)
        #expect(await source.error == terminalError)
        #expect(await source.closeCode == terminalCloseCode)
        #expect(await source.closeDisposition == terminalDisposition)
        #expect(await source.state == .disconnected)
        #expect(await replacement.state == .connected)
        #expect(
            await harness.manager.runtimeTaskIdentifier(for: replacement)
                == replacementIdentifier
        )

        await harness.manager.disconnect(replacement)
        harness.manager.handleDisconnected(
            taskIdentifier: replacementIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: replacement))

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("concurrent retries claim one fresh task and create one transport")
    func concurrentRetriesCreateExactlyOneFreshTask() async throws {
        let harness = makeShutdownHarness()
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_231)
        let retryURLTask = StubWebSocketURLTask(taskIdentifier: 9_232)
        harness.session.enqueue(firstURLTask)
        let source = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/concurrent-fresh-retry")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: source)
        )
        harness.manager.handleDisconnected(
            taskIdentifier: firstIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        try #require(await waitForWebSocketTaskRemoval(manager: harness.manager, task: source))

        harness.session.enqueue(retryURLTask)
        async let firstRetry = harness.manager.retry(source)
        async let secondRetry = harness.manager.retry(source)
        let (firstResult, secondResult) = await (firstRetry, secondRetry)
        let replacements = [firstResult, secondResult].compactMap { $0?.task }

        let replacement = try #require(replacements.first)
        #expect(replacements.count == 1)
        #expect(replacement.id != source.id)
        #expect(harness.session.createdTasks.count == 2)
        #expect(
            await harness.manager.runtimeTaskIdentifier(for: replacement)
                == retryURLTask.taskIdentifier
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("a terminal task can form a chain of distinct one-shot retry handles")
    func terminalReplacementCanRetryToAnotherFreshTask() async throws {
        let harness = makeShutdownHarness()
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_241)
        let secondURLTask = StubWebSocketURLTask(taskIdentifier: 9_242)
        let thirdURLTask = StubWebSocketURLTask(taskIdentifier: 9_243)
        harness.session.enqueue(firstURLTask)
        harness.session.enqueue(secondURLTask)
        harness.session.enqueue(thirdURLTask)
        let source = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/retry-chain")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: source)
        )
        harness.manager.handleDisconnected(
            taskIdentifier: firstIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        try #require(await waitForWebSocketTaskRemoval(manager: harness.manager, task: source))

        let retryResult = try #require(await harness.manager.retry(source))
        let replacement = retryResult.task
        let secondIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: replacement)
        )
        harness.manager.handleConnected(taskIdentifier: secondIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(replacement) { $0 == .connected })
        harness.manager.handleDisconnected(
            taskIdentifier: secondIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        try #require(await waitForWebSocketTaskRemoval(manager: harness.manager, task: replacement))

        let successorResult = try #require(await harness.manager.retry(replacement))
        let successor = successorResult.task
        let thirdIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: successor)
        )
        #expect(Set([source.id, replacement.id, successor.id]).count == 3)
        #expect(secondIdentifier == secondURLTask.taskIdentifier)
        #expect(thirdIdentifier == thirdURLTask.taskIdentifier)
        #expect(await source.state == .disconnected)
        #expect(await replacement.state == .disconnected)
        #expect(await successor.state == .connecting)
        #expect(await harness.manager.retry(source) == nil)
        #expect(await harness.manager.retry(replacement) == nil)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("foreign manager cannot retry a task owned by another manager")
    func foreignManagerRetryIsRejectedWithoutConsumingOwnerClaim() async throws {
        let owner = makeShutdownHarness()
        let foreign = makeShutdownHarness()
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_251)
        let ownerRetryURLTask = StubWebSocketURLTask(taskIdentifier: 9_252)
        owner.session.enqueue(firstURLTask)
        let source = await owner.manager.connect(
            url: URL(string: "wss://example.invalid/owned-retry")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: owner.manager, task: source)
        )
        owner.manager.handleDisconnected(
            taskIdentifier: firstIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        try #require(await waitForWebSocketTaskRemoval(manager: owner.manager, task: source))

        #expect(await foreign.manager.retry(source) == nil)
        #expect(foreign.session.createdTasks.isEmpty)

        owner.session.enqueue(ownerRetryURLTask)
        let retryResult = try #require(await owner.manager.retry(source))
        let replacement = retryResult.task
        #expect(replacement.id != source.id)
        #expect(
            await owner.manager.runtimeTaskIdentifier(for: replacement)
                == ownerRetryURLTask.taskIdentifier
        )

        let ownerShutdown = Task { await owner.manager.shutdown() }
        let foreignShutdown = Task { await foreign.manager.shutdown() }
        #expect(await owner.session.waitForInvalidation())
        #expect(await foreign.session.waitForInvalidation())
        owner.callbacks.handleInvalidation(nil)
        foreign.callbacks.handleInvalidation(nil)
        await ownerShutdown.value
        await foreignShutdown.value
    }

    @Test("task returned by connect after shutdown keeps its manager ownership")
    func postShutdownConnectTaskCannotBeAdoptedByForeignManager() async {
        let owner = makeShutdownHarness()
        let foreign = makeShutdownHarness()

        let ownerShutdown = Task { await owner.manager.shutdown() }
        #expect(await owner.session.waitForInvalidation())
        owner.callbacks.handleInvalidation(nil)
        await ownerShutdown.value

        let failedTask = await owner.manager.connect(
            url: URL(string: "wss://example.invalid/post-shutdown-owned")!
        )
        #expect(await failedTask.state == .failed)
        #expect(await failedTask.error == WebSocketManager.managerShutdownError())
        #expect(await foreign.manager.retry(failedTask) == nil)
        #expect(foreign.session.createdTasks.isEmpty)

        let foreignShutdown = Task { await foreign.manager.shutdown() }
        #expect(await foreign.session.waitForInvalidation())
        foreign.callbacks.handleInvalidation(nil)
        await foreignShutdown.value
    }

    @Test("retry admitted before shutdown returns a terminal replacement without transport")
    func retryRacingShutdownReturnsTerminalReplacement() async throws {
        let harness = makeShutdownHarness()
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_261)
        harness.session.enqueue(firstURLTask)
        let source = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/retry-shutdown-race")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: source)
        )
        harness.manager.handleConnected(taskIdentifier: firstIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(source) { $0 == .connected })

        let cleanupGate = ShutdownDelegateGate()
        let blockingRuntimeTask = Task {
            await cleanupGate.arriveAndWait()
        }
        await harness.manager.runtimeRegistry.setMessageListenerTask(
            blockingRuntimeTask,
            for: source.id
        )
        await cleanupGate.waitForArrival()

        harness.manager.handleError(
            taskIdentifier: firstIdentifier,
            error: URLError(.cannotConnectToHost)
        )
        try #require(await waitForWebSocketState(source) { $0 == .failed })
        let trackedBeforeRetry = await harness.manager.activeShutdownTrackedOperationCount

        let retry = Task { await harness.manager.retry(source) }
        let admissionDeadline = ContinuousClock.now + .seconds(1)
        while await harness.manager.activeShutdownTrackedOperationCount <= trackedBeforeRetry,
            ContinuousClock.now < admissionDeadline
        {
            await Task.yield()
        }
        try #require(
            await harness.manager.activeShutdownTrackedOperationCount > trackedBeforeRetry
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await cleanupGate.release()

        let retryResult = try #require(await retry.value)
        let replacement = retryResult.task
        await shutdown.value
        var eventIterator = retryResult.events.makeAsyncIterator()
        let terminalEvent = try #require(await eventIterator.next())
        guard case .error(let terminalError) = terminalEvent else {
            Issue.record("expected manager-shutdown error, got \(terminalEvent)")
            return
        }
        #expect(terminalError == WebSocketManager.managerShutdownError())
        #expect(await eventIterator.next() == nil)
        #expect(replacement.id != source.id)
        #expect(await replacement.state == .failed)
        #expect(await replacement.error == WebSocketManager.managerShutdownError())
        #expect(await harness.manager.task(withId: replacement.id) == nil)
        #expect(await harness.manager.runtimeTaskIdentifier(for: replacement) == nil)
        #expect(harness.session.createdTasks.count == 1)
    }

    @Test(
        "terminal publication keeps its original callback snapshot while suspended",
        arguments: [TerminalHandlerReplacementCase.error, .disconnected]
    )
    func terminalPublicationUsesHandlerSnapshot(
        _ terminalCase: TerminalHandlerReplacementCase
    ) async throws {
        let metrics = TerminalPublicationMetricRecorder()
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 0,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("terminal-handler-snapshot"),
            eventDeliveryPolicy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 1,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropNewest
            ),
            eventMetricsReporter: metrics
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_271)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/terminal-handler-snapshot")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let oldErrorCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let oldDisconnectedCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let newErrorCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let newDisconnectedCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let oldCallbackObservedCleanup = OSAllocatedUnfairLock<Bool>(initialState: false)
        let oldCallbackObservedReleasedGate = OSAllocatedUnfairLock<Bool>(initialState: false)

        await harness.manager.setOnErrorHandler { [manager = harness.manager] callbackTask, _ in
            let registeredTask = await manager.task(withId: callbackTask.id)
            let gateOwners = await manager.taskLifecycleGateOwners
            oldCallbackObservedCleanup.withLock { $0 = registeredTask == nil }
            oldCallbackObservedReleasedGate.withLock {
                $0 = !gateOwners.contains(callbackTask.id)
            }
            oldErrorCount.withLock { $0 += 1 }
        }
        await harness.manager.setOnDisconnectedHandler { [manager = harness.manager] callbackTask, _ in
            let registeredTask = await manager.task(withId: callbackTask.id)
            let gateOwners = await manager.taskLifecycleGateOwners
            oldCallbackObservedCleanup.withLock { $0 = registeredTask == nil }
            oldCallbackObservedReleasedGate.withLock {
                $0 = !gateOwners.contains(callbackTask.id)
            }
            oldDisconnectedCount.withLock { $0 += 1 }
        }

        let listenerGate = ShutdownDelegateGate()
        _ = await harness.manager.addEventListener(for: task) { event in
            guard case .ping(let context) = event, context.attemptNumber == 1 else { return }
            await listenerGate.arriveAndWait()
        }
        let blockingPublication = Task {
            await harness.manager.eventHub.publishAndWaitForDelivery(
                .ping(WebSocketPingContext(attemptNumber: 1, dispatchedAt: .now)),
                for: task.id
            )
        }
        await listenerGate.waitForArrival()
        await harness.manager.eventHub.publish(
            .ping(WebSocketPingContext(attemptNumber: 2, dispatchedAt: .now)),
            for: task.id
        )

        switch terminalCase {
        case .error:
            harness.manager.handleError(
                taskIdentifier: identifier,
                error: URLError(.cannotConnectToHost)
            )
        case .disconnected:
            harness.manager.handleDisconnected(
                taskIdentifier: identifier,
                closeCode: .normalClosure,
                reason: nil
            )
        }

        try #require(
            await waitForCondition(timeout: 1.0) {
                metrics.sawDroppedPartitionEvent(taskID: task.id)
            }
        )
        #expect(oldErrorCount.withLock { $0 } == 0)
        #expect(oldDisconnectedCount.withLock { $0 } == 0)

        await harness.manager.setOnErrorHandler { _, _ in
            newErrorCount.withLock { $0 += 1 }
        }
        await harness.manager.setOnDisconnectedHandler { _, _ in
            newDisconnectedCount.withLock { $0 += 1 }
        }

        await listenerGate.release()
        await blockingPublication.value
        try #require(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))
        try #require(
            await waitForCondition(timeout: 1.0) {
                oldErrorCount.withLock { $0 } + oldDisconnectedCount.withLock { $0 } == 1
            }
        )

        switch terminalCase {
        case .error:
            #expect(oldErrorCount.withLock { $0 } == 1)
            #expect(oldDisconnectedCount.withLock { $0 } == 0)
            #expect(await task.state == .failed)
        case .disconnected:
            #expect(oldErrorCount.withLock { $0 } == 0)
            #expect(oldDisconnectedCount.withLock { $0 } == 1)
            #expect(await task.state == .disconnected)
        }
        #expect(newErrorCount.withLock { $0 } == 0)
        #expect(newDisconnectedCount.withLock { $0 } == 0)
        #expect(oldCallbackObservedCleanup.withLock { $0 })
        #expect(oldCallbackObservedReleasedGate.withLock { $0 })

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("manual pong commit keeps its handler snapshot across replacement")
    func manualPongCommitUsesHandlerSnapshot() async throws {
        let harness = makeShutdownHarness()
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_272)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/manual-pong-handler-snapshot")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let oldHandlerCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let newHandlerCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let committedPongEventCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        await harness.manager.setOnPongHandler { _, context in
            guard context.attemptNumber == 99 else { return }
            oldHandlerCount.withLock { $0 += 1 }
        }
        _ = await harness.manager.addEventListener(for: task) { event in
            guard case .pong(let context) = event, context.attemptNumber == 99 else { return }
            committedPongEventCount.withLock { $0 += 1 }
        }

        let committedContext = WebSocketPongContext(
            attemptNumber: 99,
            roundTrip: .milliseconds(1)
        )
        await harness.manager.acquireTaskLifecycleGateUnconditionally(taskID: task.id)
        let prepared = await harness.manager.runtimeRegistry.preparePongCallback(
            task,
            context: committedContext
        )
        await harness.manager.eventHub.publish(.pong(committedContext), for: task.id)
        await harness.manager.setOnPongHandler { _, _ in
            newHandlerCount.withLock { $0 += 1 }
        }

        #expect(oldHandlerCount.withLock { $0 } == 0)
        #expect(newHandlerCount.withLock { $0 } == 0)
        await harness.manager.releaseTaskLifecycleGate(taskID: task.id)
        await harness.manager.runtimeRegistry.invokePreparedUserCallback(prepared)

        try #require(
            await waitForCondition(timeout: 1.0) {
                committedPongEventCount.withLock { $0 } == 1
            }
        )
        #expect(oldHandlerCount.withLock { $0 } == 1)
        #expect(newHandlerCount.withLock { $0 } == 0)

        // The replacement remains active for future manual pongs; it is only
        // excluded from the already-committed historical pong above.
        let futurePing = Task { try await harness.manager.ping(task) }
        try #require(await waitForCondition(timeout: 1.0) { urlTask.hasPendingPong })
        urlTask.completePendingPong(with: nil)
        try await futurePing.value
        try #require(
            await waitForCondition(timeout: 1.0) {
                newHandlerCount.withLock { $0 } == 1
            }
        )
        #expect(oldHandlerCount.withLock { $0 } == 1)

        await harness.manager.disconnect(task)
        harness.manager.handleDisconnected(
            taskIdentifier: identifier,
            closeCode: .normalClosure,
            reason: nil
        )
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("onConnected disconnect preserves its paired event and does not rebind its handler")
    func connectedCallbackDisconnectPreservesCommittedEvent() async throws {
        let harness = makeShutdownHarness()
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_273)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/connected-callback-commit")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )

        let listenerConnectedCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let streamConnectedCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let oldHandlerCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let newHandlerCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let oldHandlerReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        _ = await harness.manager.addEventListener(for: task) { event in
            guard case .connected = event else { return }
            listenerConnectedCount.withLock { $0 += 1 }
        }
        let stream = await harness.manager.events(for: task)
        let streamConsumer = Task {
            for await event in stream {
                guard case .connected = event else { continue }
                streamConnectedCount.withLock { $0 += 1 }
                return
            }
        }
        await harness.manager.setOnConnectedHandler { [manager = harness.manager] callbackTask, _ in
            await manager.setOnConnectedHandler { _, _ in
                newHandlerCount.withLock { $0 += 1 }
            }
            await manager.disconnect(callbackTask)
            oldHandlerCount.withLock { $0 += 1 }
            oldHandlerReturned.withLock { $0 = true }
        }

        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: "commit")
        try #require(
            await waitForCondition(timeout: 1.0) {
                oldHandlerReturned.withLock { $0 }
                    && listenerConnectedCount.withLock { $0 } == 1
                    && streamConnectedCount.withLock { $0 } == 1
            }
        )
        await streamConsumer.value
        #expect(oldHandlerCount.withLock { $0 } == 1)
        #expect(newHandlerCount.withLock { $0 } == 0)
        #expect(listenerConnectedCount.withLock { $0 } == 1)
        #expect(streamConnectedCount.withLock { $0 } == 1)
        #expect(await task.state == .disconnecting)

        harness.manager.handleDisconnected(
            taskIdentifier: identifier,
            closeCode: .normalClosure,
            reason: nil
        )
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("retryable onError disconnect preserves its paired event and handler snapshot")
    func retryableErrorCallbackDisconnectPreservesCommittedEvent() async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 60,
            reconnectJitterRatio: 0,
            maxReconnectAttempts: 3,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("retryable-error-callback-commit")
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_274)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/retryable-error-callback-commit")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let listenerErrorCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let streamErrorCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let oldHandlerCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let newHandlerCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let oldHandlerReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        _ = await harness.manager.addEventListener(for: task) { event in
            guard case .error = event else { return }
            listenerErrorCount.withLock { $0 += 1 }
        }
        let stream = await harness.manager.events(for: task)
        let streamConsumer = Task {
            for await event in stream {
                guard case .error = event else { continue }
                streamErrorCount.withLock { $0 += 1 }
                return
            }
        }
        await harness.manager.setOnErrorHandler { [manager = harness.manager] callbackTask, _ in
            await manager.setOnErrorHandler { _, _ in
                newHandlerCount.withLock { $0 += 1 }
            }
            await manager.disconnect(callbackTask)
            oldHandlerCount.withLock { $0 += 1 }
            oldHandlerReturned.withLock { $0 = true }
        }

        harness.manager.handleError(
            taskIdentifier: identifier,
            error: URLError(.cannotConnectToHost)
        )
        try #require(
            await waitForCondition(timeout: 1.0) {
                oldHandlerReturned.withLock { $0 }
                    && listenerErrorCount.withLock { $0 } == 1
                    && streamErrorCount.withLock { $0 } == 1
            }
        )
        await streamConsumer.value
        #expect(oldHandlerCount.withLock { $0 } == 1)
        #expect(newHandlerCount.withLock { $0 } == 0)
        #expect(listenerErrorCount.withLock { $0 } == 1)
        #expect(streamErrorCount.withLock { $0 } == 1)
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))
        #expect(await task.state == .disconnected)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("shutdown terminal error survives a saturated drop-newest listener queue")
    func shutdownTerminalErrorSurvivesDropNewestSaturation() async {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 0,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("terminal-overflow"),
            eventDeliveryPolicy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 1,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropNewest
            )
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let firstDeliveryGate = ShutdownDelegateGate()
        let observedEvents = OSAllocatedUnfairLock<[WebSocketEvent]>(initialState: [])
        let deliveryCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/terminal-overflow")!
        )
        _ = await harness.manager.addEventListener(for: task) { event in
            observedEvents.withLock { $0.append(event) }
            let position = deliveryCount.withLock { count -> Int in
                count += 1
                return count
            }
            if position == 1 {
                await firstDeliveryGate.arriveAndWait()
            }
        }

        await harness.manager.eventHub.publishAndWaitForEnqueue(
            .ping(WebSocketPingContext(attemptNumber: 1, dispatchedAt: .now)),
            for: task.id
        )
        await firstDeliveryGate.waitForArrival()
        await harness.manager.eventHub.publishAndWaitForEnqueue(
            .ping(WebSocketPingContext(attemptNumber: 2, dispatchedAt: .now)),
            for: task.id
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
        await firstDeliveryGate.release()

        let shutdownError = WebSocketManager.managerShutdownError()
        #expect(
            await waitForCondition(timeout: 1.0) {
                observedEvents.withLock { events in
                    events.contains { event in
                        guard case .error(let error) = event else { return false }
                        return error == shutdownError
                    }
                }
            }
        )
        let shutdownErrorCount = observedEvents.withLock { events in
            events.filter { event in
                guard case .error(let error) = event else { return false }
                return error == shutdownError
            }.count
        }
        #expect(shutdownErrorCount == 1)
    }

    @Test("shutdown terminal error replaces a saturated event-stream buffer")
    func shutdownTerminalErrorSurvivesSaturatedEventStream() async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 0,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("terminal-stream-overflow"),
            eventDeliveryPolicy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 1,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropNewest
            )
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/terminal-stream-overflow")!
        )
        let stream = await harness.manager.events(for: task)
        var iterator = stream.makeAsyncIterator()

        await harness.manager.eventHub.publishAndWaitForEnqueue(
            .ping(WebSocketPingContext(attemptNumber: 1, dispatchedAt: .now)),
            for: task.id
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value

        let firstEvent = try #require(await iterator.next())
        guard case .error(let error) = firstEvent else {
            Issue.record("expected terminal shutdown error, got \(firstEvent)")
            return
        }
        #expect(error == WebSocketManager.managerShutdownError())
        #expect(await iterator.next() == nil)
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

    @Test("cancelled runtime worker leaves a lifecycle gate queue without circular waiting")
    func cancelledRuntimeWorkerLeavesLifecycleGateQueue() async {
        let harness = makeShutdownHarness()
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/cancellable-lifecycle-gate")!
        )
        await task.restoreStateForTesting(.connecting)

        await harness.manager.acquireTaskLifecycleGateUnconditionally(taskID: task.id)
        let workerID = UUID()
        let reconnectWorker = Task {
            await WebSocketRuntimeWorkerContext.$workerID.withValue(workerID) {
                await harness.manager.startTransportConnection(task)
            }
        }
        await harness.manager.runtimeRegistry.setReconnectTask(
            reconnectWorker,
            workerID: workerID,
            for: task.id
        )
        let waiterDeadline = ContinuousClock.now + .seconds(1)
        while await harness.manager.taskLifecycleGateWaiterCount(taskID: task.id) != 1,
            ContinuousClock.now < waiterDeadline
        {
            await Task.yield()
        }
        #expect(await harness.manager.taskLifecycleGateWaiterCount(taskID: task.id) == 1)

        await task.restoreStateForTesting(.disconnected)
        let cleanupReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let cleanup = Task {
            await harness.manager.runtimeRegistry.removeTaskRuntime(taskId: task.id)
            cleanupReturned.withLock { $0 = true }
        }
        let cancelledWaiterDrained = await waitForCondition(timeout: 1.0) {
            cleanupReturned.withLock { $0 }
        }

        // Always release the synthetic owner so a regression reports a bounded
        // assertion failure instead of leaving the test process suspended.
        await harness.manager.releaseTaskLifecycleGate(taskID: task.id)
        await cleanup.value
        #expect(cancelledWaiterDrained)
        #expect(await harness.manager.taskLifecycleGateWaiterCount(taskID: task.id) == 0)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("reconnect winning heartbeat admission suppresses ping and preserves the old attempt snapshot")
    func reconnectWinningHeartbeatAdmissionSuppressesLatePing() async throws {
        let clock = TestClock()
        let harness = makeShutdownHarness(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 10,
                pongTimeout: 30,
                maxMissedPongs: 2,
                reconnectDelay: 1,
                reconnectJitterRatio: 0,
                maxReconnectAttempts: 2,
                sessionIdentifier: makeWebSocketTestSessionIdentifier("heartbeat-admission-race")
            ),
            clock: clock
        )
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_346)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/heartbeat-admission-race")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })
        try #require(await clock.waitForWaiters(count: 1))

        let leakedEvents = OSAllocatedUnfairLock<[WebSocketEvent]>(initialState: [])
        _ = await harness.manager.addEventListener(for: task) { event in
            switch event {
            case .ping, .error(.pingTimeout):
                leakedEvents.withLock { $0.append(event) }
            default:
                break
            }
        }

        // Hold the same gate used by lifecycle transitions, wake the real
        // heartbeat worker, and wait until its ping admission is queued behind
        // us. This deterministically models reconnect winning the race after
        // the worker obtained its URLTask but before it can publish.
        await harness.manager.acquireTaskLifecycleGateUnconditionally(taskID: task.id)
        clock.advance(by: .seconds(10))
        let waiterDeadline = ContinuousClock.now + .seconds(1)
        while await harness.manager.taskLifecycleGateWaiterCount(taskID: task.id) != 1,
            ContinuousClock.now < waiterDeadline
        {
            await Task.yield()
        }
        #expect(await harness.manager.taskLifecycleGateWaiterCount(taskID: task.id) == 1)

        let generation = await task.connectionGeneration
        let transition = await task.applyLifecycleEvent(
            .failure(
                generation: generation,
                disposition: .transportFailure(.pingTimeout),
                error: .pingTimeout
            ),
            context: .init(reconnectAction: .retry, attempt: 1)
        )
        #expect(transition.state.publicState == .reconnecting)

        let cleanupReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let cleanup = Task {
            await harness.manager.runtimeRegistry.removeTaskRuntime(taskId: task.id)
            cleanupReturned.withLock { $0 = true }
        }
        let cancellationDrained = await waitForCondition(timeout: 1.0) {
            cleanupReturned.withLock { $0 }
        }

        // Always release the synthetic owner so a regression fails with a
        // bounded assertion rather than stranding the test process.
        await harness.manager.releaseTaskLifecycleGate(taskID: task.id)
        await cleanup.value
        #expect(cancellationDrained)
        #expect(urlTask.pingCount == 0)
        #expect(leakedEvents.withLock { $0 }.isEmpty)
        // Ping allocation now occurs inside the rejected admission gate. The
        // first explicit increment therefore remains attempt 1 rather than 2.
        #expect(await task.incrementPingCounter() == 1)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("reconnect adapter can disconnect its own task without self-drain deadlock")
    func reconnectAdapterCanDisconnectItsOwnTask() async throws {
        let managerBox = OSAllocatedUnfairLock<WebSocketManager?>(initialState: nil)
        let taskBox = OSAllocatedUnfairLock<WebSocketTask?>(initialState: nil)
        let adapterInvocationCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let nestedDisconnectReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            reconnectJitterRatio: 0,
            maxReconnectAttempts: 3,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("reconnect-self-disconnect"),
            handshakeRequestAdapters: [
                WebSocketHandshakeRequestAdapter { request in
                    let invocation = adapterInvocationCount.withLock { count -> Int in
                        count += 1
                        return count
                    }
                    if invocation > 1,
                        let manager = managerBox.withLock({ $0 }),
                        let task = taskBox.withLock({ $0 })
                    {
                        await manager.disconnect(task)
                        nestedDisconnectReturned.withLock { $0 = true }
                    }
                    return request
                }
            ]
        )
        let harness = makeShutdownHarness(configuration: configuration)
        managerBox.withLock { $0 = harness.manager }
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_301)
        harness.session.enqueue(firstURLTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/reconnect-self-disconnect")!
        )
        taskBox.withLock { $0 = task }
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        harness.manager.handleDisconnected(
            taskIdentifier: identifier,
            closeCode: .goingAway,
            reason: nil
        )
        #expect(
            await waitForCondition(timeout: 1.0) {
                nestedDisconnectReturned.withLock { $0 }
            }
        )
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))
        #expect(harness.session.createdTasks.count == 1)
        #expect(await task.state == .disconnected)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("message callback can disconnect its own task without self-drain deadlock")
    func messageCallbackCanDisconnectItsOwnTask() async throws {
        let harness = makeShutdownHarness()
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_311)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/message-self-disconnect")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let nestedDisconnectReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        await harness.manager.setOnStringHandler { [manager = harness.manager] callbackTask, _ in
            await manager.disconnect(callbackTask)
            nestedDisconnectReturned.withLock { $0 = true }
        }
        urlTask.scriptReceive(.success(.string("stop")))

        #expect(
            await waitForCondition(timeout: 1.0) {
                nestedDisconnectReturned.withLock { $0 }
            }
        )
        #expect(await task.state == .disconnecting)
        harness.manager.handleDisconnected(
            taskIdentifier: identifier,
            closeCode: .normalClosure,
            reason: nil
        )
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("message callback disconnect preserves its paired event and handler snapshot")
    func messageCallbackDisconnectPreservesCommittedEvent() async throws {
        let harness = makeShutdownHarness()
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_312)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/message-callback-commit")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let listenerMessageCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let streamMessageCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let oldHandlerCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let newHandlerCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let oldHandlerReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        _ = await harness.manager.addEventListener(for: task) { event in
            guard case .message(let data) = event, data == Data("commit".utf8) else { return }
            listenerMessageCount.withLock { $0 += 1 }
        }
        let stream = await harness.manager.events(for: task)
        let streamConsumer = Task {
            for await event in stream {
                guard case .message(let data) = event, data == Data("commit".utf8) else { continue }
                streamMessageCount.withLock { $0 += 1 }
                return
            }
        }
        await harness.manager.setOnMessageHandler { [manager = harness.manager] callbackTask, data in
            guard data == Data("commit".utf8) else { return }
            await manager.setOnMessageHandler { _, _ in
                newHandlerCount.withLock { $0 += 1 }
            }
            await manager.disconnect(callbackTask)
            oldHandlerCount.withLock { $0 += 1 }
            oldHandlerReturned.withLock { $0 = true }
        }

        urlTask.scriptReceive(.success(.data(Data("commit".utf8))))
        try #require(
            await waitForCondition(timeout: 1.0) {
                oldHandlerReturned.withLock { $0 }
                    && listenerMessageCount.withLock { $0 } == 1
                    && streamMessageCount.withLock { $0 } == 1
            }
        )
        await streamConsumer.value
        #expect(oldHandlerCount.withLock { $0 } == 1)
        #expect(newHandlerCount.withLock { $0 } == 0)
        #expect(listenerMessageCount.withLock { $0 } == 1)
        #expect(streamMessageCount.withLock { $0 } == 1)
        #expect(await task.state == .disconnecting)

        harness.manager.handleDisconnected(
            taskIdentifier: identifier,
            closeCode: .normalClosure,
            reason: nil
        )
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("terminal cleanup suppresses a receive callback whose worker was already detached")
    func detachedReceiveWorkerCannotAdmitLateCallback() async throws {
        let harness = makeShutdownHarness()
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_351)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/detached-receive-callback")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let callbackCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        await harness.manager.setOnMessageHandler { [manager = harness.manager] callbackTask, _ in
            callbackCount.withLock { $0 += 1 }
            // Before worker-aware callback admission, this retry waited for the
            // cleanup-owned lifecycle gate while cleanup waited for this worker.
            _ = await manager.retry(callbackTask)
        }

        let workerGate = ShutdownDelegateGate()
        let workerReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        await harness.manager.runtimeRegistry.createMessageListenerTask(for: task.id) {
            await workerGate.arriveAndWait()
            let callback = await harness.manager.runtimeRegistry.prepareMessageCallbackFromCurrentWorker(
                task,
                data: Data("late".utf8)
            )
            await harness.manager.runtimeRegistry.invokePreparedUserCallback(callback)
            workerReturned.withLock { $0 = true }
        }
        await workerGate.waitForArrival()

        // Model the terminal transaction: it owns the lifecycle gate while
        // runtime cleanup detaches, cancels, and (when necessary) drains workers.
        await harness.manager.acquireTaskLifecycleGateUnconditionally(taskID: task.id)
        let cleanupReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let cleanup = Task {
            await harness.manager.runtimeRegistry.removeTaskRuntime(taskId: task.id)
            cleanupReturned.withLock { $0 = true }
        }
        try #require(
            await waitForCondition(timeout: 1.0) {
                urlTask.didCancelUnconditionally
            }
        )

        // The worker deliberately ignores cancellation and reaches callback
        // preparation after detachment. Registry identity validation must
        // suppress it, allowing cleanup to finish while the gate stays owned.
        await workerGate.release()
        #expect(
            await waitForCondition(timeout: 1.0) {
                cleanupReturned.withLock { $0 }
                    && workerReturned.withLock { $0 }
            }
        )
        #expect(callbackCount.withLock { $0 } == 0)

        await harness.manager.releaseTaskLifecycleGate(taskID: task.id)
        await cleanup.value

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("retryable error callback can terminally disconnect without gate deadlock")
    func retryableErrorCallbackCanDisconnectTerminally() async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            reconnectJitterRatio: 0,
            maxReconnectAttempts: 3,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("retry-callback-disconnect")
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_321)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/retry-callback-disconnect")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let nestedDisconnectReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        await harness.manager.setOnErrorHandler { [manager = harness.manager] callbackTask, _ in
            await manager.disconnect(callbackTask)
            nestedDisconnectReturned.withLock { $0 = true }
        }
        harness.manager.handleError(
            taskIdentifier: identifier,
            error: URLError(.cannotConnectToHost)
        )

        #expect(
            await waitForCondition(timeout: 1.0) {
                nestedDisconnectReturned.withLock { $0 }
            }
        )
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))
        try? await Task.sleep(for: .milliseconds(25))
        #expect(harness.session.createdTasks.count == 1)
        #expect(await task.state == .disconnected)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("old reconnect effects cannot cross a callback-created retry task")
    func oldReconnectEffectsCannotCrossCallbackRetryTask() async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            reconnectJitterRatio: 0,
            maxReconnectAttempts: 3,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("stale-reconnect-effects")
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_331)
        let retriedURLTask = StubWebSocketURLTask(taskIdentifier: 9_332)
        harness.session.enqueue(firstURLTask)
        harness.session.enqueue(retriedURLTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/stale-reconnect-effects")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: firstIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let callbackReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let replacementTask = OSAllocatedUnfairLock<WebSocketTask?>(initialState: nil)
        let staleErrorCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        await harness.manager.setOnErrorHandler { [manager = harness.manager] callbackTask, _ in
            await manager.setOnErrorHandler(nil)
            await manager.disconnect(callbackTask)
            let retryResult = await manager.retry(callbackTask)
            replacementTask.withLock { $0 = retryResult?.task }
            if let replacement = retryResult?.task {
                _ = await manager.addEventListener(for: replacement) { event in
                    if case .error = event {
                        staleErrorCount.withLock { $0 += 1 }
                    }
                }
            }
            callbackReturned.withLock { $0 = true }
        }

        harness.manager.handleError(
            taskIdentifier: firstIdentifier,
            error: URLError(.cannotConnectToHost)
        )
        try #require(
            await waitForCondition(timeout: 1.0) {
                callbackReturned.withLock { $0 }
            }
        )
        try? await Task.sleep(for: .milliseconds(50))

        let replacement = try #require(replacementTask.withLock { $0 })
        #expect(replacement.id != task.id)
        #expect(await task.state == .disconnected)
        #expect(await replacement.state == .connecting)
        #expect(staleErrorCount.withLock { $0 } == 0)
        #expect(harness.session.createdTasks.count == 2)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == nil)
        #expect(
            await harness.manager.runtimeTaskIdentifier(for: replacement)
                == retriedURLTask.taskIdentifier
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("terminal callback retry completes before replacement consumer registration")
    func terminalCallbackRetryCompletesBeforeReplacementConsumerRegistration() async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            reconnectJitterRatio: 0,
            maxReconnectAttempts: 0,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("terminal-callback-retry-registration")
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_343)
        let retriedURLTask = StubWebSocketURLTask(taskIdentifier: 9_344)
        harness.session.enqueue(firstURLTask)
        harness.session.enqueue(retriedURLTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/terminal-callback-retry-registration")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: firstIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })
        let firstGeneration = await task.connectionGeneration

        let callbackReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let replacementTask = OSAllocatedUnfairLock<WebSocketTask?>(initialState: nil)
        let retryIdentifierAtReturn = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let retryGenerationAtReturn = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let listenerObservedConnected = OSAllocatedUnfairLock<Bool>(initialState: false)
        let streamObservedConnected = OSAllocatedUnfairLock<Bool>(initialState: false)
        let listenerOldTerminalEventCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let streamOldTerminalEventCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let streamConsumer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

        await harness.manager.setOnErrorHandler { [manager = harness.manager] callbackTask, _ in
            await manager.setOnErrorHandler(nil)
            let retryResult = await manager.retry(callbackTask)
            replacementTask.withLock { $0 = retryResult?.task }
            guard let replacement = retryResult?.task else {
                callbackReturned.withLock { $0 = true }
                return
            }

            let installedIdentifier = await manager.runtimeTaskIdentifier(for: replacement)
            retryIdentifierAtReturn.withLock { $0 = installedIdentifier }
            let installedGeneration = await replacement.connectionGeneration
            retryGenerationAtReturn.withLock { $0 = installedGeneration }

            _ = await manager.addEventListener(for: replacement) { event in
                switch event {
                case .connected:
                    listenerObservedConnected.withLock { $0 = true }
                case .disconnected, .error:
                    listenerOldTerminalEventCount.withLock { $0 += 1 }
                default:
                    break
                }
            }
            let stream = await manager.events(for: replacement)
            let consumer = Task {
                for await event in stream {
                    switch event {
                    case .connected:
                        streamObservedConnected.withLock { $0 = true }
                        return
                    case .disconnected, .error:
                        streamOldTerminalEventCount.withLock { $0 += 1 }
                    default:
                        break
                    }
                }
            }
            streamConsumer.withLock { $0 = consumer }
            callbackReturned.withLock { $0 = true }
        }

        harness.manager.handleError(
            taskIdentifier: firstIdentifier,
            error: URLError(.cannotConnectToHost)
        )
        try #require(
            await waitForCondition(timeout: 1.0) {
                callbackReturned.withLock { $0 }
            }
        )

        let replacement = try #require(replacementTask.withLock { $0 })
        let retriedIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(
                manager: harness.manager,
                task: replacement,
                excluding: [firstIdentifier]
            )
        )
        #expect(retriedIdentifier == retriedURLTask.taskIdentifier)
        #expect(retryIdentifierAtReturn.withLock { $0 } == retriedIdentifier)
        #expect(replacement.id != task.id)
        #expect(await task.connectionGeneration == firstGeneration)
        #expect(await task.state == .failed)
        let replacementGeneration = await replacement.connectionGeneration
        #expect(retryGenerationAtReturn.withLock { $0 } == replacementGeneration)
        #expect(replacementGeneration == 1)

        harness.manager.handleConnected(taskIdentifier: retriedIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(replacement) { $0 == .connected })
        #expect(
            await waitForCondition(timeout: 1.0) {
                listenerObservedConnected.withLock { $0 }
                    && streamObservedConnected.withLock { $0 }
            }
        )
        #expect(listenerOldTerminalEventCount.withLock { $0 } == 0)
        #expect(streamOldTerminalEventCount.withLock { $0 } == 0)

        streamConsumer.withLock { $0 }?.cancel()
        if let consumer = streamConsumer.withLock({ $0 }) {
            _ = await consumer.result
        }

        await harness.manager.disconnect(replacement)
        harness.manager.handleDisconnected(
            taskIdentifier: retriedIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: replacement))

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("stale delegate callback context cannot bind to a fresh retry task")
    func staleDelegateContextCannotBindToFreshRetryTask() async throws {
        let harness = makeShutdownHarness()
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_333)
        let retriedURLTask = StubWebSocketURLTask(taskIdentifier: 9_334)
        harness.session.enqueue(firstURLTask)
        harness.session.enqueue(retriedURLTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/stale-delegate-context")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        let staleContext = try #require(
            await harness.manager.runtimeRegistry.callbackContext(for: firstIdentifier)
        )
        harness.manager.handleConnected(taskIdentifier: firstIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        harness.manager.handleDisconnected(
            taskIdentifier: firstIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
        try #require(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))

        let retryResult = try #require(await harness.manager.retry(task))
        let replacement = retryResult.task
        let retriedGeneration = await replacement.connectionGeneration
        #expect(replacement.id != task.id)
        #expect(await task.state == .disconnected)
        #expect(await replacement.state == .connecting)
        #expect(await replacement.attemptedReconnectCount == 0)
        #expect(
            await harness.manager.runtimeTaskIdentifier(for: replacement)
                == retriedURLTask.taskIdentifier
        )

        await harness.manager.handleMappedError(
            .connectionFailed(SendableUnderlyingError(URLError(.cannotConnectToHost))),
            callbackContext: staleContext,
            taskIdentifier: firstIdentifier
        )

        #expect(await task.state == .disconnected)
        #expect(await replacement.connectionGeneration == retriedGeneration)
        #expect(await replacement.state == .connecting)
        #expect(await replacement.attemptedReconnectCount == 0)
        #expect(
            await harness.manager.runtimeTaskIdentifier(for: replacement)
                == retriedURLTask.taskIdentifier
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("nonterminal runtime cleanup keeps the lifecycle gate until workers drain")
    func nonterminalRuntimeCleanupKeepsLifecycleGate() async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 60,
            reconnectJitterRatio: 0,
            maxReconnectAttempts: 3,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("nonterminal-effect-gate")
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_335)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/nonterminal-effect-gate")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let workerGate = ShutdownDelegateGate()
        let workerID = UUID()
        let blockingWorker = Task {
            await WebSocketRuntimeWorkerContext.$workerID.withValue(workerID) {
                await workerGate.arriveAndWait()
            }
        }
        await workerGate.waitForArrival()
        await harness.manager.runtimeRegistry.setMessageListenerTask(
            blockingWorker,
            workerID: workerID,
            for: task.id
        )

        harness.manager.handleError(
            taskIdentifier: identifier,
            error: URLError(.cannotConnectToHost)
        )
        try #require(await waitForWebSocketState(task) { $0 == .reconnecting })

        let disconnectReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let disconnect = Task {
            await harness.manager.disconnect(task)
            disconnectReturned.withLock { $0 = true }
        }
        #expect(
            !(await waitForCondition(timeout: 0.05) {
                disconnectReturned.withLock { $0 }
            })
        )

        await workerGate.release()
        await disconnect.value
        #expect(disconnectReturned.withLock { $0 })
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("manual pong callback can disconnect without lifecycle-gate deadlock")
    func manualPongCallbackCanDisconnect() async throws {
        let harness = makeShutdownHarness()
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_336)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/manual-pong-disconnect")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let callbackReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let callbackSendSucceeded = OSAllocatedUnfairLock<Bool>(initialState: false)
        let pongEventCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        _ = await harness.manager.addEventListener(for: task) { event in
            if case .pong = event {
                pongEventCount.withLock { $0 += 1 }
            }
        }
        await harness.manager.setOnPongHandler { [manager = harness.manager] callbackTask, _ in
            do {
                try await manager.send(callbackTask, string: "from-pong-callback")
                callbackSendSucceeded.withLock { $0 = true }
            } catch {
                Issue.record("connected onPong callback send failed: \(error)")
            }
            await manager.disconnect(callbackTask)
            callbackReturned.withLock { $0 = true }
        }

        let pingReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let ping = Task {
            try await harness.manager.ping(task)
            pingReturned.withLock { $0 = true }
        }
        try #require(await waitForCondition(timeout: 1.0) { urlTask.hasPendingPong })
        urlTask.completePendingPong(with: nil)

        try #require(
            await waitForCondition(timeout: 1.0) {
                callbackReturned.withLock { $0 } && pingReturned.withLock { $0 }
            }
        )
        try await ping.value
        #expect(callbackSendSucceeded.withLock { $0 })
        #expect(
            await waitForCondition(timeout: 1.0) {
                pongEventCount.withLock { $0 } == 1
            }
        )
        try #require(await waitForWebSocketState(task) { $0 == .disconnecting })

        harness.manager.handleDisconnected(
            taskIdentifier: identifier,
            closeCode: .normalClosure,
            reason: nil
        )
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("message callback waits for another connected task's lifecycle gate before sending")
    func messageCallbackWaitsForUnrelatedLifecycleGateBeforeSending() async throws {
        let harness = makeShutdownHarness()
        let sourceURLTask = StubWebSocketURLTask(taskIdentifier: 9_360)
        let targetURLTask = StubWebSocketURLTask(taskIdentifier: 9_361)
        harness.session.enqueue(sourceURLTask)
        harness.session.enqueue(targetURLTask)

        let source = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/callback-gated-send-source")!
        )
        let sourceIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: source)
        )
        harness.manager.handleConnected(taskIdentifier: sourceIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(source) { $0 == .connected })

        let target = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/callback-gated-send-target")!
        )
        let targetIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: target)
        )
        harness.manager.handleConnected(taskIdentifier: targetIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(target) { $0 == .connected })

        let callbackReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let sendSucceeded = OSAllocatedUnfairLock<Bool>(initialState: false)
        let callbackError = OSAllocatedUnfairLock<String?>(initialState: nil)
        await harness.manager.setOnMessageHandler { [manager = harness.manager] callbackTask, _ in
            guard callbackTask === source else { return }
            do {
                try await manager.send(target, string: "from-gated-message-callback")
                sendSucceeded.withLock { $0 = true }
            } catch {
                callbackError.withLock { $0 = String(describing: error) }
            }
            callbackReturned.withLock { $0 = true }
        }

        // Hold only the target's gate. A callback belonging to the same manager
        // but originating from another task must queue rather than being
        // mistaken for a recursive owner of this gate.
        await harness.manager.acquireTaskLifecycleGateUnconditionally(taskID: target.id)
        sourceURLTask.scriptReceive(.success(.data(Data("send".utf8))))

        let waiterDeadline = ContinuousClock.now + .seconds(1)
        while await harness.manager.taskLifecycleGateWaiterCount(taskID: target.id) != 1,
            !callbackReturned.withLock({ $0 }),
            ContinuousClock.now < waiterDeadline
        {
            await Task.yield()
        }
        let waiterCount = await harness.manager.taskLifecycleGateWaiterCount(taskID: target.id)

        // Always release the synthetic owner before asserting, so the test is
        // bounded even when the callback incorrectly returns immediately.
        await harness.manager.releaseTaskLifecycleGate(taskID: target.id)
        #expect(waiterCount == 1)
        #expect(
            await waitForCondition(timeout: 1.0) {
                callbackReturned.withLock { $0 }
            }
        )
        #expect(sendSucceeded.withLock { $0 })
        #expect(callbackError.withLock { $0 } == nil)
        let sentMessages = targetURLTask.sentMessages
        #expect(sentMessages.count == 1)
        if let firstMessage = sentMessages.first, case .string(let payload) = firstMessage {
            #expect(payload == "from-gated-message-callback")
        } else {
            Issue.record("expected one string payload from the message callback")
        }

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("message callback waits for another connected task's lifecycle gate before pinging")
    func messageCallbackWaitsForUnrelatedLifecycleGateBeforePinging() async throws {
        let harness = makeShutdownHarness()
        let sourceURLTask = StubWebSocketURLTask(taskIdentifier: 9_362)
        let targetURLTask = StubWebSocketURLTask(taskIdentifier: 9_363)
        harness.session.enqueue(sourceURLTask)
        harness.session.enqueue(targetURLTask)

        let source = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/callback-gated-ping-source")!
        )
        let sourceIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: source)
        )
        harness.manager.handleConnected(taskIdentifier: sourceIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(source) { $0 == .connected })

        let target = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/callback-gated-ping-target")!
        )
        let targetIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: target)
        )
        harness.manager.handleConnected(taskIdentifier: targetIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(target) { $0 == .connected })

        let callbackReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let pingSucceeded = OSAllocatedUnfairLock<Bool>(initialState: false)
        let callbackError = OSAllocatedUnfairLock<String?>(initialState: nil)
        await harness.manager.setOnMessageHandler { [manager = harness.manager] callbackTask, _ in
            guard callbackTask === source else { return }
            do {
                try await manager.ping(target)
                pingSucceeded.withLock { $0 = true }
            } catch {
                callbackError.withLock { $0 = String(describing: error) }
            }
            callbackReturned.withLock { $0 = true }
        }

        await harness.manager.acquireTaskLifecycleGateUnconditionally(taskID: target.id)
        sourceURLTask.scriptReceive(.success(.data(Data("ping".utf8))))

        let waiterDeadline = ContinuousClock.now + .seconds(1)
        while await harness.manager.taskLifecycleGateWaiterCount(taskID: target.id) != 1,
            !callbackReturned.withLock({ $0 }),
            ContinuousClock.now < waiterDeadline
        {
            await Task.yield()
        }
        let waiterCount = await harness.manager.taskLifecycleGateWaiterCount(taskID: target.id)
        await harness.manager.releaseTaskLifecycleGate(taskID: target.id)
        #expect(waiterCount == 1)

        let pingDispatchObserved = await waitForCondition(timeout: 1.0) {
            targetURLTask.hasPendingPong || callbackReturned.withLock { $0 }
        }
        let pingWasDispatched = targetURLTask.hasPendingPong
        #expect(pingDispatchObserved && pingWasDispatched)
        targetURLTask.completePendingPong(with: nil)

        #expect(
            await waitForCondition(timeout: 1.0) {
                callbackReturned.withLock { $0 }
            }
        )
        #expect(pingSucceeded.withLock { $0 })
        #expect(callbackError.withLock { $0 } == nil)
        #expect(targetURLTask.pingCount == 1)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test(
        "message callback preserves ping outcome while its publication waits for a lifecycle gate",
        arguments: [ManualPingCompletion.success, .failure]
    )
    func messageCallbackWaitsForPingOutcomePublication(
        _ completion: ManualPingCompletion
    ) async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            pongTimeout: 0.25,
            reconnectDelay: 0,
            maxReconnectAttempts: 0,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("callback-gated-ping-outcome")
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let sourceURLTask = StubWebSocketURLTask(taskIdentifier: 9_364)
        let targetURLTask = StubWebSocketURLTask(taskIdentifier: 9_365)
        harness.session.enqueue(sourceURLTask)
        harness.session.enqueue(targetURLTask)

        let source = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/callback-gated-outcome-source")!
        )
        let sourceIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: source)
        )
        harness.manager.handleConnected(taskIdentifier: sourceIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(source) { $0 == .connected })

        let target = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/callback-gated-outcome-target")!
        )
        let targetIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: target)
        )
        harness.manager.handleConnected(taskIdentifier: targetIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(target) { $0 == .connected })

        let pongEventCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let errorEventCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        _ = await harness.manager.addEventListener(for: target) { event in
            switch event {
            case .pong:
                pongEventCount.withLock { $0 += 1 }
            case .error(.pingTimeout):
                errorEventCount.withLock { $0 += 1 }
            case .connected, .disconnected, .message, .string, .ping, .error, .sendDropped:
                break
            }
        }

        let callbackReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let pingSucceeded = OSAllocatedUnfairLock<Bool>(initialState: false)
        let callbackError = OSAllocatedUnfairLock<WebSocketError?>(initialState: nil)
        await harness.manager.setOnMessageHandler { [manager = harness.manager] callbackTask, _ in
            guard callbackTask === source else { return }
            do {
                try await manager.ping(target)
                pingSucceeded.withLock { $0 = true }
            } catch let error as WebSocketError {
                callbackError.withLock { $0 = error }
            } catch {
                Issue.record("unexpected ping error: \(error)")
            }
            callbackReturned.withLock { $0 = true }
        }

        // Let preparePing complete before taking the target gate. Completing
        // the transport while that gate is held then isolates the pong/error
        // publication boundary from the initial ping-admission boundary.
        sourceURLTask.scriptReceive(.success(.data(Data("outcome".utf8))))
        let pingWasDispatched =
            await waitForCondition(timeout: 1.0) {
                targetURLTask.hasPendingPong || callbackReturned.withLock { $0 }
            } && targetURLTask.hasPendingPong

        var waiterCount = 0
        if pingWasDispatched {
            await harness.manager.acquireTaskLifecycleGateUnconditionally(taskID: target.id)
            switch completion {
            case .success:
                targetURLTask.completePendingPong(with: nil)
            case .failure:
                targetURLTask.completePendingPong(with: URLError(.timedOut))
            }

            let waiterDeadline = ContinuousClock.now + .seconds(1)
            while await harness.manager.taskLifecycleGateWaiterCount(taskID: target.id) != 1,
                !callbackReturned.withLock({ $0 }),
                ContinuousClock.now < waiterDeadline
            {
                await Task.yield()
            }
            waiterCount = await harness.manager.taskLifecycleGateWaiterCount(taskID: target.id)

            // The old callback-wide shortcut returns or drops the outcome here.
            // Release regardless of the observed result to keep failures bounded.
            await harness.manager.releaseTaskLifecycleGate(taskID: target.id)
        }

        #expect(pingWasDispatched)
        #expect(waiterCount == 1)
        #expect(
            await waitForCondition(timeout: 1.0) {
                callbackReturned.withLock { $0 }
            }
        )

        switch completion {
        case .success:
            #expect(pingSucceeded.withLock { $0 })
            #expect(callbackError.withLock { $0 } == nil)
            #expect(
                await waitForCondition(timeout: 1.0) {
                    pongEventCount.withLock { $0 } == 1
                }
            )
            #expect(errorEventCount.withLock { $0 } == 0)
        case .failure:
            #expect(!pingSucceeded.withLock { $0 })
            #expect(callbackError.withLock { $0 } == .pingTimeout)
            #expect(
                await waitForCondition(timeout: 1.0) {
                    errorEventCount.withLock { $0 } == 1
                }
            )
            #expect(pongEventCount.withLock { $0 } == 0)
        }

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("admitted heartbeat callback can retry after terminal cleanup cancels its worker")
    func admittedHeartbeatCallbackRetrySurvivesWorkerCancellation() async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            reconnectJitterRatio: 0,
            maxReconnectAttempts: 0,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("heartbeat-callback-retry")
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_352)
        let retriedURLTask = StubWebSocketURLTask(taskIdentifier: 9_353)
        harness.session.enqueue(firstURLTask)
        harness.session.enqueue(retriedURLTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/heartbeat-callback-retry")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: firstIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })
        let firstGeneration = await task.connectionGeneration

        let pongEventCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        _ = await harness.manager.addEventListener(for: task) { event in
            if case .pong = event {
                pongEventCount.withLock { $0 += 1 }
            }
        }

        let callbackGate = ShutdownDelegateGate()
        let callbackRetryReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let replacementTask = OSAllocatedUnfairLock<WebSocketTask?>(initialState: nil)
        await harness.manager.setOnPongHandler { [manager = harness.manager] callbackTask, _ in
            await callbackGate.arriveAndWait()
            let retryResult = await manager.retry(callbackTask)
            replacementTask.withLock { $0 = retryResult?.task }
            callbackRetryReturned.withLock { $0 = true }
        }

        // Install a deterministic heartbeat worker without waiting on a real
        // clock. The production manager path must atomically admit its callback
        // while the runtime is current, enqueue the paired pong, then release
        // the lifecycle gate before invoking user code.
        let workerID = UUID()
        let workerStartGate = ShutdownDelegateGate()
        let workerReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let heartbeatWorker = Task {
            await WebSocketRuntimeWorkerContext.$workerID.withValue(workerID) {
                await workerStartGate.arriveAndWait()
                await harness.manager.publishHeartbeatPongIfCurrent(
                    task: task,
                    generation: firstGeneration,
                    urlTask: firstURLTask,
                    context: WebSocketPongContext(
                        attemptNumber: 1,
                        roundTrip: .milliseconds(1)
                    )
                )
                workerReturned.withLock { $0 = true }
            }
        }
        await harness.manager.runtimeRegistry.setHeartbeatTask(
            heartbeatWorker,
            workerID: workerID,
            for: task.id
        )
        await workerStartGate.waitForArrival()
        await workerStartGate.release()
        await callbackGate.waitForArrival()

        // Terminal cleanup cancels and detaches the heartbeat worker. Because
        // callback admission already won, cleanup must not await that worker,
        // and the callback must execute on an uncancelled lane so `await retry`
        // can install the replacement transport after the terminal gate is released.
        harness.manager.handleError(
            taskIdentifier: firstIdentifier,
            error: URLError(.cannotConnectToHost)
        )
        let removedBeforeCallbackRelease = await waitForWebSocketTaskRemoval(
            manager: harness.manager,
            task: task
        )
        #expect(removedBeforeCallbackRelease)

        await callbackGate.release()
        #expect(
            await waitForCondition(timeout: 1.0) {
                callbackRetryReturned.withLock { $0 }
                    && workerReturned.withLock { $0 }
            }
        )

        let replacement = replacementTask.withLock { $0 }
        #expect(replacement != nil)
        let retriedIdentifier: Int?
        if let replacement {
            retriedIdentifier = await waitForWebSocketRuntimeTaskIdentifier(
                manager: harness.manager,
                task: replacement
            )
        } else {
            retriedIdentifier = nil
        }
        #expect(retriedIdentifier == retriedURLTask.taskIdentifier)
        #expect(await task.connectionGeneration == firstGeneration)
        #expect(await task.state == .failed)
        if let replacement {
            #expect(replacement.id != task.id)
            #expect(await replacement.connectionGeneration > 0)
        }
        #expect(
            await waitForCondition(timeout: 1.0) {
                pongEventCount.withLock { $0 } == 1
            }
        )

        if let replacement, let retriedIdentifier {
            harness.manager.handleConnected(taskIdentifier: retriedIdentifier, protocolName: nil)
            try #require(await waitForWebSocketState(replacement) { $0 == .connected })
            await harness.manager.disconnect(replacement)
            harness.manager.handleDisconnected(
                taskIdentifier: retriedIdentifier,
                closeCode: .normalClosure,
                reason: nil
            )
            #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: replacement))
        }
        await heartbeatWorker.value

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("cancelled close-timeout worker leaves a cleanup-owned lifecycle gate")
    func cancelledCloseTimeoutWorkerLeavesCleanupGate() async throws {
        let harness = makeShutdownHarness()
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_337)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/close-timeout-cancellation")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })
        await harness.manager.disconnect(task)
        try #require(await waitForWebSocketState(task) { $0 == .disconnecting })

        await harness.manager.acquireTaskLifecycleGateUnconditionally(taskID: task.id)
        let workerStartGate = ShutdownDelegateGate()
        let workerID = UUID()
        let timeoutReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let timeoutWorker = Task {
            await WebSocketRuntimeWorkerContext.$workerID.withValue(workerID) {
                await workerStartGate.arriveAndWait()
                await harness.manager.handleCloseHandshakeTimeout(
                    taskID: task.id,
                    closeCode: .normalClosure
                )
                timeoutReturned.withLock { $0 = true }
            }
        }
        await workerStartGate.waitForArrival()
        await harness.manager.runtimeRegistry.setCloseHandshakeTask(
            timeoutWorker,
            workerID: workerID,
            for: task.id
        )
        await workerStartGate.release()
        let waiterDeadline = ContinuousClock.now + .seconds(1)
        while await harness.manager.taskLifecycleGateWaiterCount(taskID: task.id) != 1,
            ContinuousClock.now < waiterDeadline
        {
            await Task.yield()
        }
        try #require(await harness.manager.taskLifecycleGateWaiterCount(taskID: task.id) == 1)

        let cleanupReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        let cleanup = Task {
            await harness.manager.runtimeRegistry.removeTaskRuntime(taskId: task.id)
            cleanupReturned.withLock { $0 = true }
        }
        try #require(
            await waitForCondition(timeout: 1.0) {
                cleanupReturned.withLock { $0 }
            }
        )
        await cleanup.value
        await timeoutWorker.value
        #expect(timeoutReturned.withLock { $0 })
        await harness.manager.releaseTaskLifecycleGate(taskID: task.id)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("ordinary terminal error replaces a saturated drop-newest listener queue")
    func ordinaryTerminalErrorSurvivesDropNewestSaturation() async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 0,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("ordinary-terminal-overflow"),
            eventDeliveryPolicy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 1,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropNewest
            )
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_338)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/ordinary-terminal-overflow")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let firstDeliveryGate = ShutdownDelegateGate()
        let observedEvents = OSAllocatedUnfairLock<[WebSocketEvent]>(initialState: [])
        let deliveryCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        _ = await harness.manager.addEventListener(for: task) { event in
            observedEvents.withLock { $0.append(event) }
            let position = deliveryCount.withLock { count -> Int in
                count += 1
                return count
            }
            if position == 1 {
                await firstDeliveryGate.arriveAndWait()
            }
        }
        await harness.manager.eventHub.publishAndWaitForEnqueue(
            .ping(WebSocketPingContext(attemptNumber: 1, dispatchedAt: .now)),
            for: task.id
        )
        await firstDeliveryGate.waitForArrival()
        await harness.manager.eventHub.publishAndWaitForEnqueue(
            .ping(WebSocketPingContext(attemptNumber: 2, dispatchedAt: .now)),
            for: task.id
        )

        harness.manager.handleError(
            taskIdentifier: identifier,
            error: URLError(.cannotConnectToHost)
        )
        try #require(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))
        await firstDeliveryGate.release()

        #expect(
            await waitForCondition(timeout: 1.0) {
                observedEvents.withLock { events in
                    events.contains { event in
                        guard case .error(.maxReconnectAttemptsExceeded) = event else { return false }
                        return true
                    }
                }
            }
        )

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("reconnect-exhausted close emits one guaranteed final outcome under saturation")
    func reconnectExhaustedCloseHasSingleGuaranteedOutcome() async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 0,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("close-terminal-outcome"),
            eventDeliveryPolicy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 1,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropNewest
            )
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_354)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/close-terminal-outcome")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )

        // Observe the initial connected event before installing the bounded
        // consumers whose queues this test intentionally saturates.
        let connectedObserved = OSAllocatedUnfairLock<Bool>(initialState: false)
        let connectedSubscription = await harness.manager.addEventListener(for: task) { event in
            if case .connected = event {
                connectedObserved.withLock { $0 = true }
            }
        }
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(
            await waitForCondition(timeout: 1.0) {
                connectedObserved.withLock { $0 }
            }
        )
        await harness.manager.removeEventListener(connectedSubscription)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let disconnectedCallbackCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let errorCallbackCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        await harness.manager.setOnDisconnectedHandler { _, _ in
            disconnectedCallbackCount.withLock { $0 += 1 }
        }
        await harness.manager.setOnErrorHandler { _, error in
            if error == .maxReconnectAttemptsExceeded {
                errorCallbackCount.withLock { $0 += 1 }
            }
        }

        let firstDeliveryGate = ShutdownDelegateGate()
        let observedEvents = OSAllocatedUnfairLock<[WebSocketEvent]>(initialState: [])
        let listenerDeliveryCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        _ = await harness.manager.addEventListener(for: task) { event in
            observedEvents.withLock { $0.append(event) }
            let position = listenerDeliveryCount.withLock { count -> Int in
                count += 1
                return count
            }
            if position == 1 {
                await firstDeliveryGate.arriveAndWait()
            }
        }
        let stream = await harness.manager.events(for: task)

        await harness.manager.eventHub.publishAndWaitForEnqueue(
            .ping(WebSocketPingContext(attemptNumber: 1, dispatchedAt: .now)),
            for: task.id
        )
        await firstDeliveryGate.waitForArrival()
        await harness.manager.eventHub.publishAndWaitForEnqueue(
            .ping(WebSocketPingContext(attemptNumber: 2, dispatchedAt: .now)),
            for: task.id
        )

        harness.manager.handleDisconnected(
            taskIdentifier: identifier,
            closeCode: .goingAway,
            reason: nil
        )
        try #require(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))
        #expect(
            await waitForCondition(timeout: 1.0) {
                errorCallbackCount.withLock { $0 } == 1
            }
        )
        #expect(disconnectedCallbackCount.withLock { $0 } == 0)

        await firstDeliveryGate.release()
        #expect(
            await waitForCondition(timeout: 1.0) {
                observedEvents.withLock { events in
                    events.contains { event in
                        guard case .error(.maxReconnectAttemptsExceeded) = event else { return false }
                        return true
                    }
                }
            }
        )
        #expect(
            !observedEvents.withLock { events in
                events.contains { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }
        )

        var streamIterator = stream.makeAsyncIterator()
        let streamedTerminalEvent = await streamIterator.next()
        if case .error(.maxReconnectAttemptsExceeded)? = streamedTerminalEvent {
            // Expected: bufferingNewest(1) retains the authoritative outcome.
        } else {
            Issue.record("Expected the final max-reconnect error from the saturated stream")
        }
        #expect(await streamIterator.next() == nil)
        #expect(await task.state == .failed)
        #expect(await task.closeCode == .goingAway)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("old-generation send completion cannot release an auto-reconnected generation slot")
    func oldGenerationSendCannotReleaseAutoReconnectedSlot() async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 3,
            sessionIdentifier: makeWebSocketTestSessionIdentifier("send-generation-slot"),
            sendQueueLimit: 1,
            sendQueueOverflowPolicy: .fail
        )
        let harness = makeShutdownHarness(configuration: configuration)
        let firstURLTask = StubWebSocketURLTask(taskIdentifier: 9_339)
        let retriedURLTask = StubWebSocketURLTask(taskIdentifier: 9_340)
        let firstSendGate = ShutdownDelegateGate()
        let retriedSendGate = ShutdownDelegateGate()
        firstURLTask.setBeforeSendCompletionHook {
            await firstSendGate.arriveAndWait()
        }
        retriedURLTask.setBeforeSendCompletionHook {
            await retriedSendGate.arriveAndWait()
        }
        harness.session.enqueue(firstURLTask)
        harness.session.enqueue(retriedURLTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/send-generation-slot")!
        )
        let firstIdentifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: firstIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let firstSend = Task {
            try await harness.manager.send(task, string: "generation-one")
        }
        await firstSendGate.waitForArrival()
        #expect(await task.inFlightSendCount == 1)

        harness.manager.handleError(
            taskIdentifier: firstIdentifier,
            error: URLError(.cannotConnectToHost)
        )
        let reconnectDeadline = ContinuousClock.now + .seconds(1)
        var retriedIdentifier: Int?
        while ContinuousClock.now < reconnectDeadline {
            let candidate = await harness.manager.runtimeTaskIdentifier(for: task)
            if candidate == retriedURLTask.taskIdentifier {
                retriedIdentifier = candidate
                break
            }
            await Task.yield()
        }
        let resolvedRetriedIdentifier = try #require(retriedIdentifier)
        harness.manager.handleConnected(taskIdentifier: resolvedRetriedIdentifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let retriedSend = Task {
            try await harness.manager.send(task, string: "generation-two")
        }
        await retriedSendGate.waitForArrival()
        #expect(await task.inFlightSendCount == 1)

        await firstSendGate.release()
        try await firstSend.value
        #expect(await task.inFlightSendCount == 1)
        await #expect(throws: WebSocketError.self) {
            try await harness.manager.send(task, string: "must-overflow")
        }

        await retriedSendGate.release()
        try await retriedSend.value
        #expect(await task.inFlightSendCount == 0)

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
    }

    @Test("event listener does not inherit the publishing runtime worker identity")
    func eventListenerDoesNotInheritRuntimeWorkerIdentity() async throws {
        let harness = makeShutdownHarness()
        let urlTask = StubWebSocketURLTask(taskIdentifier: 9_341)
        harness.session.enqueue(urlTask)
        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/listener-worker-identity")!
        )
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.manager.handleConnected(taskIdentifier: identifier, protocolName: nil)
        try #require(await waitForWebSocketState(task) { $0 == .connected })

        let listenerStarted = OSAllocatedUnfairLock<Bool>(initialState: false)
        let nestedDisconnectReturned = OSAllocatedUnfairLock<Bool>(initialState: false)
        _ = await harness.manager.addEventListener(for: task) { [manager = harness.manager] event in
            guard case .ping = event else { return }
            listenerStarted.withLock { $0 = true }
            await manager.disconnect(task)
            nestedDisconnectReturned.withLock { $0 = true }
        }

        let startGate = ShutdownDelegateGate()
        let workerExitGate = ShutdownDelegateGate()
        let workerID = UUID()
        let heartbeatWorker = Task {
            await WebSocketRuntimeWorkerContext.$workerID.withValue(workerID) {
                await startGate.arriveAndWait()
                await harness.manager.eventHub.publish(
                    .ping(WebSocketPingContext(attemptNumber: 1, dispatchedAt: .now)),
                    for: task.id
                )
                await workerExitGate.arriveAndWait()
            }
        }
        await startGate.waitForArrival()
        await harness.manager.runtimeRegistry.setHeartbeatTask(
            heartbeatWorker,
            workerID: workerID,
            for: task.id
        )
        await startGate.release()
        await workerExitGate.waitForArrival()
        try #require(
            await waitForCondition(timeout: 1.0) {
                listenerStarted.withLock { $0 }
            }
        )
        #expect(
            !(await waitForCondition(timeout: 0.05) {
                nestedDisconnectReturned.withLock { $0 }
            })
        )

        await workerExitGate.release()
        #expect(
            await waitForCondition(timeout: 1.0) {
                nestedDisconnectReturned.withLock { $0 }
            }
        )
        harness.manager.handleDisconnected(
            taskIdentifier: identifier,
            closeCode: .normalClosure,
            reason: nil
        )
        #expect(await waitForWebSocketTaskRemoval(manager: harness.manager, task: task))

        let shutdown = Task { await harness.manager.shutdown() }
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown.value
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
        ),
        clock: any InnoNetworkClock = SystemClock()
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
            callbacks: callbacks,
            clock: clock
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

    enum TerminalHandlerReplacementCase: Sendable {
        case error
        case disconnected
    }

    enum ManualPingCompletion: Sendable {
        case success
        case failure
    }
}

private final class TerminalPublicationMetricRecorder: EventPipelineMetricsReporting,
    @unchecked Sendable
{
    private let droppedPartitionTaskIDs = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    func report(_ metric: EventPipelineMetric) {
        guard case .partitionState(let state) = metric, state.droppedEventCount > 0 else { return }
        _ = droppedPartitionTaskIDs.withLock { $0.insert(state.partitionID) }
    }

    func sawDroppedPartitionEvent(taskID: String) -> Bool {
        droppedPartitionTaskIDs.withLock { $0.contains(taskID) }
    }
}

private actor ShutdownDelegateGate {
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
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
