import Darwin
import Foundation
import Testing

@testable import InnoNetwork

extension EventHubTests {
    @Test("TaskEventHub reports consumer overflow metrics with dropOldest policy")
    func taskEventHubReportsConsumerOverflowMetrics() async throws {
        let recorder = EventHubMetricRecorder()
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 8,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropOldest
            ),
            metricsReporter: recorder
        )
        let store = EventHubIntEventStore()

        _ = await hub.addListener(taskID: "task-overflow") { value in
            try? await Task.sleep(for: .milliseconds(100))
            await store.append(value)
        }

        await hub.publish(1, for: "task-overflow")
        await hub.publish(2, for: "task-overflow")
        await hub.publish(3, for: "task-overflow")

        let terminalDelivered = await eventHubWaitForCondition(timeout: 1.0) {
            await store.snapshot().last == 3
        }
        #expect(terminalDelivered)
        let values = await store.snapshot()
        #expect(!values.isEmpty)
        #expect(values.count <= 2)
        #expect(values == values.sorted())
        #expect(values.last == 3)

        let consumerMetrics = try await eventHubWaitForConsumerMetrics(
            recorder: recorder,
            partitionID: "task-overflow",
            minimumCount: 1,
            minimumDroppedEventCount: 1
        )
        #expect(consumerMetrics.contains(where: { $0.droppedEventCount > 0 }))
        #expect(consumerMetrics.allSatisfy { !$0.consumerID.hasPrefix("stream-") })
    }

    @Test("TaskEventHub terminal seal preserves existing consumers from late events")
    func taskEventHubTerminalSealProtectsExistingConsumers() async {
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 1,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropOldest
            )
        )
        let stream = await hub.stream(for: "terminal-seal")

        await hub.publish(1, for: "terminal-seal")
        await hub.publishTerminalAndFinish(99, for: "terminal-seal")
        await hub.publish(2, for: "terminal-seal")

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 99)
        #expect(await iterator.next() == nil)
    }

    @Test("TaskEventHub dropNewest stream retains oldest normal value but always admits terminal")
    func taskEventHubDropNewestStreamGuaranteesTerminal() async {
        let policy = EventDeliveryPolicy(
            maxBufferedEventsPerPartition: 8,
            maxBufferedEventsPerConsumer: 1,
            overflowPolicy: .dropNewest
        )

        let normalHub = TaskEventHub<Int>(policy: policy)
        let normalStream = await normalHub.stream(for: "drop-newest-normal")
        await normalHub.publish(1, for: "drop-newest-normal")
        await normalHub.publish(2, for: "drop-newest-normal")
        var normalIterator = normalStream.makeAsyncIterator()
        #expect(await normalIterator.next() == 1)
        await normalHub.finish(taskID: "drop-newest-normal")

        let terminalHub = TaskEventHub<Int>(policy: policy)
        let terminalStream = await terminalHub.stream(for: "drop-newest-terminal")
        await terminalHub.publish(1, for: "drop-newest-terminal")
        await terminalHub.publish(2, for: "drop-newest-terminal")
        await terminalHub.publishTerminalAndFinish(99, for: "drop-newest-terminal")
        var terminalIterator = terminalStream.makeAsyncIterator()
        #expect(await terminalIterator.next() == 99)
        #expect(await terminalIterator.next() == nil)
    }

    @Test("TaskEventHub distributes events across concurrent iterators without crashing")
    func taskEventHubSupportsConcurrentStreamIterators() async {
        let hub = TaskEventHub<Int>()
        let stream = await hub.stream(for: "concurrent-iterators")

        let first = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        let second = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        let bothWaitersInstalled = await eventHubWaitForCondition(timeout: 1.0) {
            await hub.streamWaiterCount(taskID: "concurrent-iterators") == 2
        }
        #expect(bothWaitersInstalled)

        await hub.publishAndWaitForEnqueue(1, for: "concurrent-iterators")
        await hub.publishAndWaitForEnqueue(2, for: "concurrent-iterators")

        let firstValue = await first.value
        let secondValue = await second.value
        let values = [firstValue, secondValue].compactMap { $0 }.sorted()
        #expect(values == [1, 2])
        await hub.finish(taskID: "concurrent-iterators")
    }

    @Test("TaskEventHub finish resumes every concurrent stream waiter once")
    func taskEventHubFinishResumesConcurrentStreamWaiters() async {
        let hub = TaskEventHub<Int>()
        let stream = await hub.stream(for: "finish-concurrent-waiters")

        let first = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        let second = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        let bothWaitersInstalled = await eventHubWaitForCondition(timeout: 1.0) {
            await hub.streamWaiterCount(taskID: "finish-concurrent-waiters") == 2
        }
        #expect(bothWaitersInstalled)

        await hub.finish(taskID: "finish-concurrent-waiters")
        #expect(await first.value == nil)
        #expect(await second.value == nil)
    }

    @Test("TaskEventHub stream cancellation does not depend on the hub lifetime")
    func taskEventHubStreamCancellationAfterHubDeinitReturns() async {
        weak var weakHub: TaskEventHub<Int>?
        var hub: TaskEventHub<Int>? = TaskEventHub<Int>()
        weakHub = hub
        let stream = await hub!.stream(for: "deinitialized-hub-cancellation")

        let returned = EventHubDeliveryGate()
        let nextTask = Task {
            var iterator = stream.makeAsyncIterator()
            let value = await iterator.next()
            await returned.markReturned()
            return value
        }

        let waiterInstalled = await eventHubWaitForCondition(timeout: 1.0) {
            guard let hub else { return false }
            return await hub.streamWaiterCount(taskID: "deinitialized-hub-cancellation") == 1
        }
        #expect(waiterInstalled)

        hub = nil
        let hubReleased = await eventHubWaitForCondition(timeout: 1.0) {
            weakHub == nil
        }
        #expect(hubReleased)

        nextTask.cancel()
        let didReturn = await eventHubWaitForCondition(timeout: 1.0) {
            await returned.hasReturned()
        }
        #expect(didReturn)
        if didReturn {
            #expect(await nextTask.value == nil)
        }
    }

    @Test("TaskEventHub reuses a task ID only after terminal partition closure")
    func taskEventHubReusesTaskIDAfterTerminalClosure() async {
        let hub = TaskEventHub<Int>()
        await hub.publishTerminalAndFinish(1, for: "terminal-retry")
        await hub.finishAndWaitForClosure(taskID: "terminal-retry")

        let stream = await hub.stream(for: "terminal-retry")
        await hub.publishTerminalAndFinish(2, for: "terminal-retry")

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == nil)
    }

    @Test("finishAndWait targets only the partition generation it closed")
    func taskEventHubFinishAndWaitTargetsCapturedGeneration() async {
        let retirementGate = EventHubDeliveryGate()
        let finishGate = EventHubDeliveryGate()
        let hub = TaskEventHub<Int>(partitionRetirementHook: { _, _ in
            await retirementGate.markStarted()
            await retirementGate.waitForRelease()
        })
        let taskID = "captured-retirement-generation"
        _ = await hub.addListener(taskID: taskID) { _ in }

        let finishTask = Task {
            await hub.finishAndWaitForClosure(taskID: taskID)
            await finishGate.markReturned()
        }
        await retirementGate.waitUntilStarted()

        _ = await hub.addListener(taskID: taskID) { _ in }
        #expect(await hub.listenerCount(taskID: taskID) == 1)
        await retirementGate.release()

        let returned = await eventHubWaitForCondition(timeout: 1.0) {
            await finishGate.hasReturned()
        }
        #expect(returned)
        #expect(await hub.listenerCount(taskID: taskID) == 1)

        if !returned {
            await hub.finish(taskID: taskID)
        }
        _ = await finishTask.result
        await hub.finish(taskID: taskID)
    }

    @Test("A consumer waits through consecutive closed partition generations")
    func taskEventHubConsumerWaitsThroughConsecutiveClosedGenerations() async throws {
        let firstDeliveryGate = EventHubDeliveryGate()
        let secondDeliveryGate = EventHubDeliveryGate()
        let firstRetirementGate = EventHubDeliveryGate()
        let secondRetirementGate = EventHubDeliveryGate()
        let subscriberGate = EventHubDeliveryGate()
        let subscriberStore = EventHubIntEventStore()
        let sequencer = EventHubPartitionRetirementSequencer(
            gates: [firstRetirementGate, secondRetirementGate]
        )
        let hub = TaskEventHub<Int>(partitionRetirementHook: { _, _ in
            await sequencer.handleRetirement()
        })
        let taskID = "consecutive-closed-generations"

        _ = await hub.addListener(taskID: taskID) { value in
            guard value == 1 else { return }
            await firstDeliveryGate.markStarted()
            await firstDeliveryGate.waitForRelease()
        }
        let firstPublish = Task {
            await hub.publishAndWaitForDelivery(1, for: taskID)
        }
        await firstDeliveryGate.waitUntilStarted()
        await hub.finish(taskID: taskID)

        let subscriber = Task {
            let listenerID = await hub.addListener(taskID: taskID) { value in
                await subscriberStore.append(value)
            }
            await subscriberGate.markReturned()
            return listenerID
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await subscriberGate.hasReturned() == false)

        await firstDeliveryGate.release()
        _ = await firstPublish.result
        await firstRetirementGate.waitUntilStarted()

        _ = await hub.addListener(taskID: taskID) { value in
            guard value == 2 else { return }
            await secondDeliveryGate.markStarted()
            await secondDeliveryGate.waitForRelease()
        }
        let secondPublish = Task {
            await hub.publishAndWaitForDelivery(2, for: taskID)
        }
        await secondDeliveryGate.waitUntilStarted()
        await hub.finish(taskID: taskID)

        await firstRetirementGate.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await subscriberGate.hasReturned() == false)

        await secondDeliveryGate.release()
        _ = await secondPublish.result
        await secondRetirementGate.waitUntilStarted()
        #expect(await subscriberGate.hasReturned() == false)
        await secondRetirementGate.release()

        let attachedToNextGeneration = await eventHubWaitForCondition(timeout: 1.0) {
            await subscriberGate.hasReturned()
        }
        #expect(attachedToNextGeneration)
        let subscriberID = await subscriber.value

        await hub.publishAndWaitForDelivery(3, for: taskID)
        #expect(await subscriberStore.snapshot() == [3])
        await hub.removeListener(taskID: taskID, listenerID: subscriberID)
        await hub.finish(taskID: taskID)
    }

}
