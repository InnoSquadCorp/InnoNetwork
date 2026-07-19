import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

extension WebSocketManagerShutdownTests {

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

    @Test("throwing handshake adapter fails through lifecycle without creating transport")
    func throwingHandshakeAdapterFailsWithoutCreatingTransport() async {
        let invocationCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let observedErrors = OSAllocatedUnfairLock<[WebSocketError]>(initialState: [])
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            reconnectJitterRatio: 0,
            maxReconnectAttempts: 1,
            handshakeRequestAdapters: [
                WebSocketHandshakeRequestAdapter { _ in
                    invocationCount.withLock { $0 += 1 }
                    throw ThrowingHandshakeAdapterTestError.tokenUnavailable
                }
            ]
        )
        let harness = makeShutdownHarness(configuration: configuration)
        await harness.manager.setOnErrorHandler { _, error in
            observedErrors.withLock { $0.append(error) }
        }

        let task = await harness.manager.connect(
            url: URL(string: "wss://example.invalid/adapter-throws")!
        )

        #expect(
            await waitForWebSocketState(task) { $0 == .failed },
            "adapter failures should exhaust the configured reconnect budget instead of leaving the task connecting"
        )
        #expect(invocationCount.withLock { $0 } == 2)
        #expect(harness.session.createdTasks.isEmpty)
        #expect(
            observedErrors.withLock { errors in
                errors.contains { error in
                    guard case .connectionFailed(let underlying) = error else { return false }
                    return underlying.message.contains("Handshake token lookup failed")
                }
            },
            "the first adapter failure should remain observable before reconnect exhaustion"
        )

        async let shutdown: Void = harness.manager.shutdown()
        #expect(await harness.session.waitForInvalidation())
        harness.callbacks.handleInvalidation(nil)
        await shutdown
    }
}
