import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

extension WebSocketManagerShutdownTests {

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
}
