import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

extension WebSocketManagerShutdownTests {

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
}
