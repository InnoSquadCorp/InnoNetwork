import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

extension WebSocketManagerShutdownTests {

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
        let trackedBeforeRetry = await harness.manager.coordinationState.activeShutdownTrackedOperationCount

        let retry = Task { await harness.manager.retry(source) }
        let admissionDeadline = ContinuousClock.now + .seconds(1)
        while await harness.manager.coordinationState.activeShutdownTrackedOperationCount <= trackedBeforeRetry,
            ContinuousClock.now < admissionDeadline
        {
            await Task.yield()
        }
        try #require(
            await harness.manager.coordinationState.activeShutdownTrackedOperationCount > trackedBeforeRetry
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
            let gateOwners = await manager.coordinationState.taskLifecycleGateOwners
            oldCallbackObservedCleanup.withLock { $0 = registeredTask == nil }
            oldCallbackObservedReleasedGate.withLock {
                $0 = !gateOwners.contains(callbackTask.id)
            }
            oldErrorCount.withLock { $0 += 1 }
        }
        await harness.manager.setOnDisconnectedHandler { [manager = harness.manager] callbackTask, _ in
            let registeredTask = await manager.task(withId: callbackTask.id)
            let gateOwners = await manager.coordinationState.taskLifecycleGateOwners
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
}
