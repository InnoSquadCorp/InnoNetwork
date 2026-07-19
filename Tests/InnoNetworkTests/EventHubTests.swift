import Darwin
import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

private actor IntEventStore {
    private var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }

    func snapshot() -> [Int] {
        values
    }
}

private actor NetworkEventRecorder {
    private var events: [NetworkEvent] = []

    func append(_ event: NetworkEvent) {
        events.append(event)
    }

    func snapshot() -> [NetworkEvent] {
        events
    }
}

private struct RecordingObserver: NetworkEventObserving {
    let recorder: NetworkEventRecorder

    func handle(_ event: NetworkEvent) async {
        await recorder.append(event)
    }
}

private struct FirstEventBlockingObserver: NetworkEventObserving {
    let recorder: NetworkEventRecorder
    let gate: DeliveryGate

    func handle(_ event: NetworkEvent) async {
        if case .requestStart = event {
            await gate.markStarted()
            await gate.waitForRelease()
        }
        await recorder.append(event)
    }
}

private final class EventPipelineMetricRecorder: EventPipelineMetricsReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: [EventPipelineMetric] = []

    func report(_ metric: EventPipelineMetric) {
        lock.lock()
        metrics.append(metric)
        lock.unlock()
    }

    func snapshot() -> [EventPipelineMetric] {
        lock.lock()
        let value = metrics
        lock.unlock()
        return value
    }
}

private final class SlowEventPipelineMetricReporter: EventPipelineMetricsReporting, @unchecked Sendable {
    private let downstream: EventPipelineMetricRecorder
    private let delayMicroseconds: useconds_t

    init(downstream: EventPipelineMetricRecorder, delayMicroseconds: useconds_t = 200_000) {
        self.downstream = downstream
        self.delayMicroseconds = delayMicroseconds
    }

    func report(_ metric: EventPipelineMetric) {
        usleep(delayMicroseconds)
        downstream.report(metric)
    }
}

private final class SlowObserver: NetworkEventObserving, Sendable {
    func handle(_ event: NetworkEvent) async {
        _ = event
        try? await Task.sleep(for: .milliseconds(200))
    }
}

private actor DeliveryGate {
    private var started = false
    private var released = false
    private var returned = false
    private var continuedAfterCancellationAwareAwait = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func markReturned() {
        returned = true
    }

    func hasReturned() -> Bool {
        returned
    }

    func markContinuedAfterCancellationAwareAwait() {
        continuedAfterCancellationAwareAwait = true
    }

    func didContinueAfterCancellationAwareAwait() -> Bool {
        continuedAfterCancellationAwareAwait
    }

    func markCancelled() {
        cancelled = true
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}

private actor ListenerIDBox {
    private var listenerID: UUID?

    func set(_ listenerID: UUID) {
        self.listenerID = listenerID
    }

    func value() -> UUID? {
        listenerID
    }
}

private actor PartitionRetirementSequencer {
    private let gates: [DeliveryGate]
    private var index = 0

    init(gates: [DeliveryGate]) {
        self.gates = gates
    }

    func handleRetirement() async {
        guard index < gates.count else { return }
        let gate = gates[index]
        index += 1
        await gate.markStarted()
        await gate.waitForRelease()
    }
}


@Suite("Event Hub Tests", .serialized)
struct EventHubTests {
    @Test("TaskEventHub preserves per-task order")
    func taskEventHubPreservesPerTaskOrder() async throws {
        let hub = TaskEventHub<Int>()
        let store = IntEventStore()

        _ = await hub.addListener(taskID: "task-a") { value in
            await store.append(value)
        }

        await hub.publish(1, for: "task-a")
        await hub.publish(2, for: "task-a")
        await hub.publish(3, for: "task-a")

        let values = try await waitForValues(store: store, expectedCount: 3)
        #expect(values == [1, 2, 3])
    }

    @Test("TaskEventHub isolates slow listeners across tasks")
    func taskEventHubIsolatesSlowListenersAcrossTasks() async throws {
        let hub = TaskEventHub<Int>()
        let slowStore = IntEventStore()
        let fastStore = IntEventStore()

        _ = await hub.addListener(taskID: "slow") { value in
            try? await Task.sleep(for: .milliseconds(250))
            await slowStore.append(value)
        }

        _ = await hub.addListener(taskID: "fast") { value in
            await fastStore.append(value)
        }

        await hub.publish(1, for: "slow")
        await hub.publish(2, for: "fast")

        let fastValues = try await waitForValues(store: fastStore, expectedCount: 1)
        #expect(fastValues == [2])
    }

    @Test("TaskEventHub publishAndWaitForDelivery waits for listener completion")
    func taskEventHubPublishAndWaitForDeliveryWaitsForListenerCompletion() async {
        let hub = TaskEventHub<Int>()
        let gate = DeliveryGate()

        _ = await hub.addListener(taskID: "wait") { _ in
            await gate.markStarted()
            await gate.waitForRelease()
        }

        let publishTask = Task {
            await hub.publishAndWaitForDelivery(1, for: "wait")
            await gate.markReturned()
        }

        await gate.waitUntilStarted()
        #expect(await gate.hasReturned() == false)

        await gate.release()
        _ = await publishTask.result
        #expect(await gate.hasReturned())
    }

    @Test("TaskEventHub publishAndWaitForEnqueue does not wait for listener completion")
    func taskEventHubPublishAndWaitForEnqueueDoesNotWaitForListenerCompletion() async {
        let hub = TaskEventHub<Int>()
        let gate = DeliveryGate()

        _ = await hub.addListener(taskID: "enqueue") { _ in
            await gate.markStarted()
            await gate.waitForRelease()
        }

        await hub.publishAndWaitForEnqueue(1, for: "enqueue")

        await gate.waitUntilStarted()
        #expect(await gate.hasReturned() == false)

        await gate.release()
    }

    @Test("TaskEventHub publishAndWaitForEnqueue is not blocked by older listener deliveries")
    func taskEventHubPublishAndWaitForEnqueueIgnoresOlderBlockedListenerDelivery() async throws {
        let hub = TaskEventHub<Int>()
        let gate = DeliveryGate()
        let store = IntEventStore()

        _ = await hub.addListener(taskID: "enqueue-backlog") { value in
            if value == 0 {
                await gate.markStarted()
                await gate.waitForRelease()
            }
            await store.append(value)
        }

        await hub.publish(0, for: "enqueue-backlog")
        await gate.waitUntilStarted()

        let publishTask = Task {
            await hub.publishAndWaitForEnqueue(1, for: "enqueue-backlog")
            await gate.markReturned()
        }

        let returned = await waitForEventHubCondition(timeout: 1.0) {
            await gate.hasReturned()
        }
        #expect(returned)

        await gate.release()
        _ = await publishTask.result
        let values = try await waitForValues(store: store, expectedCount: 2)
        #expect(values == [0, 1])
    }

    @Test("TaskEventHub snapshots listeners when an event is enqueued")
    func taskEventHubDoesNotDeliverQueuedEventsToLaterListeners() async throws {
        let hub = TaskEventHub<Int>()
        let gate = DeliveryGate()
        let firstStore = IntEventStore()
        let secondStore = IntEventStore()

        _ = await hub.addListener(taskID: "snapshot") { value in
            await firstStore.append(value)
            if value == 0 {
                await gate.markStarted()
                await gate.waitForRelease()
            }
        }

        let blockingPublish = Task {
            await hub.publishAndWaitForDelivery(0, for: "snapshot")
        }
        await gate.waitUntilStarted()

        await hub.publish(1, for: "snapshot")
        _ = await hub.addListener(taskID: "snapshot") { value in
            await secondStore.append(value)
        }

        await gate.release()
        _ = await blockingPublish.result

        let firstValues = try await waitForValues(store: firstStore, expectedCount: 2)
        #expect(firstValues == [0, 1])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await secondStore.snapshot().isEmpty)
    }

    @Test("TaskEventHub publishAndWaitForDelivery completes when finish races delivery")
    func taskEventHubPublishAndWaitForDeliveryCompletesWhenFinishRacesDelivery() async {
        let hub = TaskEventHub<Int>()
        let gate = DeliveryGate()

        _ = await hub.addListener(taskID: "finish-race") { _ in
            await gate.markStarted()
            await gate.waitForRelease()
        }

        let publishTask = Task {
            await hub.publishAndWaitForDelivery(1, for: "finish-race")
            await gate.markReturned()
        }

        await gate.waitUntilStarted()
        let finishTask = Task {
            await hub.finish(taskID: "finish-race")
        }

        await gate.release()
        _ = await publishTask.result
        _ = await finishTask.result

        #expect(await gate.hasReturned())
    }

    @Test("TaskEventHub publishAndWaitForDelivery completes when listener removes itself")
    func taskEventHubPublishAndWaitForDeliveryCompletesWhenListenerRemovesItself() async {
        let hub = TaskEventHub<Int>()
        let listenerIDBox = ListenerIDBox()
        let gate = DeliveryGate()

        let listenerID = await hub.addListener(taskID: "self-remove") { _ in
            await gate.markStarted()
            if let listenerID = await listenerIDBox.value() {
                await hub.removeListener(taskID: "self-remove", listenerID: listenerID)
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                await gate.markCancelled()
                return
            }
            await gate.markContinuedAfterCancellationAwareAwait()
        }
        await listenerIDBox.set(listenerID)

        let publishTask = Task {
            await hub.publishAndWaitForDelivery(1, for: "self-remove")
            await gate.markReturned()
        }

        await gate.waitUntilStarted()
        let completed = await waitForEventHubCondition(timeout: 1.0) {
            await gate.hasReturned()
        }
        #expect(completed)
        #expect(await gate.didContinueAfterCancellationAwareAwait())
        #expect(await gate.wasCancelled() == false)
        #expect(await hub.listenerCount(taskID: "self-remove") == 0)

        if completed {
            _ = await publishTask.result
        } else {
            publishTask.cancel()
        }
    }

    @Test("NetworkEventHub isolates slow observers across requests")
    func networkEventHubIsolatesSlowObserversAcrossRequests() async throws {
        let hub = NetworkEventHub()
        let fastRecorder = NetworkEventRecorder()
        let fastObserver = RecordingObserver(recorder: fastRecorder)
        let slowObserver = SlowObserver()

        let slowRequestID = UUID()
        let fastRequestID = UUID()

        await hub.publish(
            .requestStart(requestID: slowRequestID, method: "GET", url: "https://example.com/slow", retryIndex: 0),
            requestID: slowRequestID,
            observers: [slowObserver]
        )
        await hub.publish(
            .requestStart(requestID: fastRequestID, method: "GET", url: "https://example.com/fast", retryIndex: 0),
            requestID: fastRequestID,
            observers: [fastObserver]
        )

        let events = try await waitForNetworkEvents(recorder: fastRecorder, expectedCount: 1)
        #expect(events.count == 1)
        #expect(requestID(of: events[0]) == fastRequestID)

        await hub.finish(requestID: slowRequestID)
        await hub.finish(requestID: fastRequestID)
    }

    @Test("NetworkEventHub finish preserves events queued behind an active observer")
    func networkEventHubFinishPreservesQueuedObserverEvents() async throws {
        let hub = NetworkEventHub()
        let recorder = NetworkEventRecorder()
        let gate = DeliveryGate()
        let observer = FirstEventBlockingObserver(recorder: recorder, gate: gate)
        let requestID = UUID()

        await hub.publish(
            .requestStart(
                requestID: requestID,
                method: "GET",
                url: "https://example.com/queued-finish",
                retryIndex: 0
            ),
            requestID: requestID,
            observers: [observer]
        )
        await gate.waitUntilStarted()

        await hub.publish(
            .requestFailed(requestID: requestID, errorCode: -999, message: "cancelled"),
            requestID: requestID,
            observers: [observer]
        )

        let finishTask = Task {
            await hub.finish(requestID: requestID)
            await gate.markReturned()
        }
        let finishReturned = await waitForEventHubCondition(timeout: 1.0) {
            await gate.hasReturned()
        }
        #expect(finishReturned)
        #expect(await recorder.snapshot().isEmpty)

        await gate.release()
        _ = await finishTask.result

        let events = try await waitForNetworkEvents(recorder: recorder, expectedCount: 2)
        #expect(events.count == 2)
        #expect(events.map(requestID(of:)) == [requestID, requestID])
        let isTerminalFailure: Bool
        if let lastEvent = events.last, case .requestFailed = lastEvent {
            isTerminalFailure = true
        } else {
            isTerminalFailure = false
        }
        #expect(isTerminalFailure)
    }

    @Test("NetworkEventHub keeps a closed tombstone across retirement reentrancy")
    func networkEventHubRetirementRejectsReentrantPublishAndJoinsFinish() async throws {
        let retirementGate = DeliveryGate()
        let firstFinishGate = DeliveryGate()
        let secondFinishGate = DeliveryGate()
        let recorder = NetworkEventRecorder()
        let requestID = UUID()
        let hub = NetworkEventHub { retiringRequestID in
            guard retiringRequestID == requestID else { return }
            await retirementGate.markStarted()
            await retirementGate.waitForRelease()
        }
        let observer = RecordingObserver(recorder: recorder)

        await hub.publish(
            .requestStart(
                requestID: requestID,
                method: "GET",
                url: "https://example.com/retirement-reentrancy",
                retryIndex: 0
            ),
            requestID: requestID,
            observers: [observer]
        )
        _ = try await waitForNetworkEvents(recorder: recorder, expectedCount: 1)

        let firstFinish = Task {
            await hub.finish(requestID: requestID)
            await firstFinishGate.markReturned()
        }
        await retirementGate.waitUntilStarted()

        let retiringState = try #require(
            await hub._testingRetirementState(requestID: requestID)
        )
        #expect(retiringState.isClosed)
        #expect(retiringState.isRetiring)

        await hub.publish(
            .requestFinished(requestID: requestID, statusCode: 200, byteCount: 0),
            requestID: requestID,
            observers: [observer]
        )

        let secondFinish = Task {
            await secondFinishGate.markStarted()
            await hub.finish(requestID: requestID)
            await secondFinishGate.markReturned()
        }
        await secondFinishGate.waitUntilStarted()
        let secondFinishJoined = await waitForEventHubCondition(timeout: 1.0) {
            await hub._testingRetirementState(requestID: requestID)?.closureWaiterCount == 1
        }
        #expect(secondFinishJoined)
        #expect(await firstFinishGate.hasReturned() == false)
        #expect(await secondFinishGate.hasReturned() == false)

        await retirementGate.release()
        _ = await firstFinish.result
        _ = await secondFinish.result

        #expect(await firstFinishGate.hasReturned())
        #expect(await secondFinishGate.hasReturned())
        #expect(await recorder.snapshot().count == 1)
        #expect(await hub._testingRetirementState(requestID: requestID) == nil)
    }

    @Test("TaskEventHub reports consumer overflow metrics with dropOldest policy")
    func taskEventHubReportsConsumerOverflowMetrics() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 8,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropOldest
            ),
            metricsReporter: recorder
        )
        let store = IntEventStore()

        _ = await hub.addListener(taskID: "task-overflow") { value in
            try? await Task.sleep(for: .milliseconds(100))
            await store.append(value)
        }

        await hub.publish(1, for: "task-overflow")
        await hub.publish(2, for: "task-overflow")
        await hub.publish(3, for: "task-overflow")

        let terminalDelivered = await waitForEventHubCondition(timeout: 1.0) {
            await store.snapshot().last == 3
        }
        #expect(terminalDelivered)
        let values = await store.snapshot()
        #expect(!values.isEmpty)
        #expect(values.count <= 2)
        #expect(values == values.sorted())
        #expect(values.last == 3)

        let consumerMetrics = try await waitForConsumerMetrics(
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

        let bothWaitersInstalled = await waitForEventHubCondition(timeout: 1.0) {
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

        let bothWaitersInstalled = await waitForEventHubCondition(timeout: 1.0) {
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

        let returned = DeliveryGate()
        let nextTask = Task {
            var iterator = stream.makeAsyncIterator()
            let value = await iterator.next()
            await returned.markReturned()
            return value
        }

        let waiterInstalled = await waitForEventHubCondition(timeout: 1.0) {
            guard let hub else { return false }
            return await hub.streamWaiterCount(taskID: "deinitialized-hub-cancellation") == 1
        }
        #expect(waiterInstalled)

        hub = nil
        let hubReleased = await waitForEventHubCondition(timeout: 1.0) {
            weakHub == nil
        }
        #expect(hubReleased)

        nextTask.cancel()
        let didReturn = await waitForEventHubCondition(timeout: 1.0) {
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
        let retirementGate = DeliveryGate()
        let finishGate = DeliveryGate()
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

        let returned = await waitForEventHubCondition(timeout: 1.0) {
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
        let firstDeliveryGate = DeliveryGate()
        let secondDeliveryGate = DeliveryGate()
        let firstRetirementGate = DeliveryGate()
        let secondRetirementGate = DeliveryGate()
        let subscriberGate = DeliveryGate()
        let subscriberStore = IntEventStore()
        let sequencer = PartitionRetirementSequencer(
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

        let attachedToNextGeneration = await waitForEventHubCondition(timeout: 1.0) {
            await subscriberGate.hasReturned()
        }
        #expect(attachedToNextGeneration)
        let subscriberID = await subscriber.value

        await hub.publishAndWaitForDelivery(3, for: taskID)
        #expect(await subscriberStore.snapshot() == [3])
        await hub.removeListener(taskID: taskID, listenerID: subscriberID)
        await hub.finish(taskID: taskID)
    }

    @Test("TaskEventHub reports AsyncStream overflow metrics and aggregate snapshots")
    func taskEventHubReportsStreamOverflowMetrics() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 8,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropOldest
            ),
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(50)
        )
        let stream = await hub.stream(for: "stream-overflow")
        var iterator = stream.makeAsyncIterator()

        await hub.publish(1, for: "stream-overflow")
        await hub.publish(2, for: "stream-overflow")
        await hub.publish(3, for: "stream-overflow")

        let consumerMetrics = try await waitForConsumerMetrics(
            recorder: recorder,
            partitionID: "stream-overflow",
            minimumCount: 3,
            minimumDroppedEventCount: 2
        )
        let streamMetrics = consumerMetrics.filter { $0.consumerID.hasPrefix("stream-") }
        #expect(!streamMetrics.isEmpty)
        #expect(Set(streamMetrics.map(\.droppedEventCount)).isSuperset(of: [1, 2]))
        #expect(streamMetrics.contains(where: { $0.queueDepth == 1 }))

        let snapshots = try await waitForAggregateSnapshots(
            recorder: recorder,
            hubKind: .genericTask,
            minimumCount: 1
        )
        let hasExpectedOverflowSnapshot = snapshots.contains { snapshot in
            snapshot.totalDroppedEventCount >= 2 && snapshot.overflowEventCount >= 2
                && snapshot.totalDroppedMetricCount == 0 && snapshot.metricsOverflowCount == 0
        }
        #expect(hasExpectedOverflowSnapshot)

        let bufferedValue = try #require(await iterator.next())
        #expect(bufferedValue == 3)

        await hub.finish(taskID: "stream-overflow")
    }

    @Test("Aggregate event overflow count resets after each snapshot")
    func aggregateEventOverflowCountResetsAfterSnapshot() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 8,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropOldest
            ),
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(30)
        )
        let stream = await hub.stream(for: "stream-windowed-overflow")
        _ = stream

        await hub.publish(1, for: "stream-windowed-overflow")
        await hub.publish(2, for: "stream-windowed-overflow")
        await hub.publish(3, for: "stream-windowed-overflow")

        let overflowSnapshot = try #require(
            await waitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: {
                    $0.totalDroppedEventCount >= 2 && $0.overflowEventCount >= 2
                }
            )
        )

        let baselineSnapshotCount = recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
            guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
            return snapshot.hubKind == .genericTask ? snapshot : nil
        }.count

        let subsequentSnapshots = try await waitForAdditionalAggregateSnapshots(
            recorder: recorder,
            hubKind: .genericTask,
            existingCount: baselineSnapshotCount,
            additionalCount: 1
        )
        let nextSnapshot = try #require(subsequentSnapshots.first)

        #expect(nextSnapshot.totalDroppedEventCount == overflowSnapshot.totalDroppedEventCount)
        #expect(nextSnapshot.overflowEventCount == 0)

        await hub.finish(taskID: "stream-windowed-overflow")
    }

    @Test("TaskEventHub AsyncStream buffering honors the per-consumer cap")
    func taskEventHubStreamUsesPerConsumerBufferCap() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 4,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropOldest
            ),
            metricsReporter: recorder
        )
        let stream = await hub.stream(for: "stream-cap")
        var iterator = stream.makeAsyncIterator()

        await hub.publish(1, for: "stream-cap")
        await hub.publish(2, for: "stream-cap")
        await hub.publish(3, for: "stream-cap")

        let consumerMetrics = try await waitForConsumerMetrics(
            recorder: recorder,
            partitionID: "stream-cap",
            minimumCount: 3,
            minimumDroppedEventCount: 2
        )
        let streamMetrics = consumerMetrics.filter { $0.consumerID.hasPrefix("stream-") }
        #expect(streamMetrics.contains(where: { $0.queueDepth == 1 }))

        let bufferedValue = try #require(await iterator.next())
        #expect(bufferedValue == 3)

        await hub.finish(taskID: "stream-cap")
    }

    @Test("TaskEventHub reconciles AsyncStream consumer metrics between publishes")
    func taskEventHubReconcilesStreamConsumerMetrics() async throws {
        let recorder = EventPipelineMetricRecorder()
        // The hub, its metrics proxy, and every age computation run on the
        // injected virtual clock, so queued-event ages advance only when the
        // test advances the clock — no wall-clock sleeps.
        let clock = TestClock()
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 8,
                maxBufferedEventsPerConsumer: 2,
                overflowPolicy: .dropOldest
            ),
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(30),
            clock: clock
        )
        let stream = await hub.stream(for: "stream-reconcile")
        _ = stream

        await hub.publish(1, for: "stream-reconcile")
        await hub.publish(2, for: "stream-reconcile")

        let initialMetrics = try await waitForConsumerMetrics(
            recorder: recorder,
            partitionID: "stream-reconcile",
            minimumCount: 1
        )
        let initialMetric = try #require(
            initialMetrics.last(where: { $0.consumerID.hasPrefix("stream-") && $0.queueDepth >= 1 })
        )
        let initialOldestAge = try #require(initialMetric.oldestQueuedEventAge)

        // Both the hub's reconciliation loop and the proxy's snapshot loop
        // park on the virtual clock. Advance past the aggregator's 1-second
        // per-consumer emission throttle so the reconciled state is emitted.
        #expect(await clock.waitForWaiters(count: 2))
        clock.advance(by: .milliseconds(1_100))

        let reconciledBaselineMetrics = try await waitForConsumerMetrics(
            recorder: recorder,
            partitionID: "stream-reconcile",
            minimumCount: 2
        )
        let reconciledBaselineMetric = try #require(
            reconciledBaselineMetrics.last(where: { $0.consumerID == initialMetric.consumerID && $0.queueDepth == 2 })
        )
        let reconciledBaselineOldestAge = try #require(reconciledBaselineMetric.oldestQueuedEventAge)
        #expect(reconciledBaselineOldestAge > initialOldestAge)

        #expect(await clock.waitForWaiters(count: 2))
        clock.advance(by: .milliseconds(1_100))

        let latestMetrics = try await waitForConsumerMetrics(
            recorder: recorder,
            partitionID: "stream-reconcile",
            minimumCount: 3
        )
        let latestMetric = try #require(
            latestMetrics.last(where: { $0.consumerID == initialMetric.consumerID })
        )
        let latestOldestAge = try #require(latestMetric.oldestQueuedEventAge)
        #expect(latestMetric.queueDepth == reconciledBaselineMetric.queueDepth)
        #expect(latestMetric.droppedEventCount == reconciledBaselineMetric.droppedEventCount)
        #expect(latestOldestAge > reconciledBaselineOldestAge)

        let snapshots = try await waitForAggregateSnapshots(
            recorder: recorder,
            hubKind: .genericTask,
            minimumCount: 2
        )
        #expect(
            snapshots.contains(where: {
                $0.activeConsumerCount >= 1 && $0.maxQueueDepth >= 2
            }))

        await hub.finish(taskID: "stream-reconcile")
    }

    @Test("TaskEventHub evicts cancelled AsyncStream consumers from aggregate snapshots immediately")
    func taskEventHubEvictsCancelledStreamConsumersFromAggregateSnapshots() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 8,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropOldest
            ),
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(30)
        )

        let consumerID: String
        do {
            let stream = await hub.stream(for: "stream-cancelled")
            let consumerTask = Task {
                let iterator = stream.makeAsyncIterator()
                _ = iterator

                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
            }

            await hub.publish(1, for: "stream-cancelled")
            await hub.publish(2, for: "stream-cancelled")
            await hub.publish(3, for: "stream-cancelled")

            let initialMetrics = try await waitForConsumerMetrics(
                recorder: recorder,
                partitionID: "stream-cancelled",
                minimumCount: 3,
                minimumDroppedEventCount: 2
            )
            let matchingInitialMetric = initialMetrics.last(where: { metric in
                metric.consumerID.hasPrefix("stream-") && metric.queueDepth == 1 && metric.droppedEventCount == 2
            })
            let initialMetric = try #require(matchingInitialMetric)
            consumerID = initialMetric.consumerID

            let activeSnapshot = try #require(
                await waitForAggregateSnapshot(
                    recorder: recorder,
                    hubKind: .genericTask,
                    predicate: { $0.activeConsumerCount >= 1 && $0.maxQueueDepth >= 1 }
                )
            )
            #expect(activeSnapshot.activeConsumerCount >= 1)

            consumerTask.cancel()
            _ = await consumerTask.result
        }

        let terminalMetric = try #require(
            await waitForConsumerMetric(
                recorder: recorder,
                partitionID: "stream-cancelled",
                consumerID: consumerID,
                predicate: { $0.queueDepth == 0 && $0.oldestQueuedEventAge == nil }
            )
        )
        #expect(terminalMetric.droppedEventCount == 2)

        let clearedSnapshot = try #require(
            await waitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: { $0.activeConsumerCount == 0 && $0.maxQueueDepth == 0 }
            )
        )
        #expect(clearedSnapshot.activeConsumerCount == 0)
    }

    @Test("TaskEventHub finish evicts active AsyncStream consumers from aggregate snapshots")
    func taskEventHubFinishEvictsActiveStreamConsumersFromAggregateSnapshots() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(30)
        )

        let consumerID: String
        do {
            let stream = await hub.stream(for: "stream-finish")
            let consumerTask = Task {
                var iterator = stream.makeAsyncIterator()
                while await iterator.next() != nil {}
            }

            let initialMetrics = try await waitForConsumerMetrics(
                recorder: recorder,
                partitionID: "stream-finish",
                minimumCount: 1
            )
            consumerID = try #require(
                initialMetrics.last(where: { $0.consumerID.hasPrefix("stream-") })?.consumerID
            )

            let activeSnapshot = try #require(
                await waitForAggregateSnapshot(
                    recorder: recorder,
                    hubKind: .genericTask,
                    predicate: { $0.activeConsumerCount >= 1 }
                )
            )
            #expect(activeSnapshot.activeConsumerCount >= 1)

            await hub.finish(taskID: "stream-finish")

            let clearedSnapshot = try #require(
                await waitForAggregateSnapshot(
                    recorder: recorder,
                    hubKind: .genericTask,
                    predicate: { $0.activeConsumerCount == 0 }
                )
            )
            #expect(clearedSnapshot.activeConsumerCount == 0)

            _ = await consumerTask.result
        }

        let terminalMetric = try #require(
            await waitForConsumerMetric(
                recorder: recorder,
                partitionID: "stream-finish",
                consumerID: consumerID,
                predicate: { $0.queueDepth == 0 && $0.oldestQueuedEventAge == nil }
            )
        )
        #expect(terminalMetric.queueDepth == 0)
    }

    @Test("TaskEventHub finish keeps subsequent snapshots cleared after terminal eviction reporting")
    func taskEventHubFinishKeepsSubsequentSnapshotsClearedAfterTerminalEvictionReporting() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 8,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropOldest
            ),
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(10)
        )

        let stream = await hub.stream(for: "stream-finish-serialization")
        _ = stream

        await hub.publish(1, for: "stream-finish-serialization")
        await hub.publish(2, for: "stream-finish-serialization")
        await hub.publish(3, for: "stream-finish-serialization")

        let initialMetrics = try await waitForConsumerMetrics(
            recorder: recorder,
            partitionID: "stream-finish-serialization",
            minimumCount: 3,
            minimumDroppedEventCount: 2
        )
        let matchingInitialMetric = initialMetrics.last(where: {
            $0.consumerID.hasPrefix("stream-") && $0.queueDepth == 1 && $0.droppedEventCount == 2
        })
        let initialMetric = try #require(matchingInitialMetric)

        let activeSnapshot = try #require(
            await waitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: { $0.activeConsumerCount >= 1 && $0.maxQueueDepth >= 1 }
            )
        )
        #expect(activeSnapshot.activeConsumerCount >= 1)

        await hub.finish(taskID: "stream-finish-serialization")

        let terminalMetric = try #require(
            await waitForConsumerMetric(
                recorder: recorder,
                partitionID: "stream-finish-serialization",
                consumerID: initialMetric.consumerID,
                predicate: {
                    $0.queueDepth == 0 && $0.oldestQueuedEventAge == nil && $0.droppedEventCount == 2
                }
            )
        )
        #expect(terminalMetric.queueDepth == 0)

        let baselineSnapshotCount = recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
            guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
            return snapshot.hubKind == .genericTask ? snapshot : nil
        }.count
        let subsequentSnapshots = try await waitForAdditionalAggregateSnapshots(
            recorder: recorder,
            hubKind: .genericTask,
            existingCount: baselineSnapshotCount,
            additionalCount: 5
        )
        #expect(!subsequentSnapshots.isEmpty)
        #expect(
            subsequentSnapshots.allSatisfy {
                $0.activeConsumerCount == 0 && $0.maxQueueDepth == 0
            })
    }

    @Test("TaskEventHub stops idle stream reconciliation and restarts on a new stream")
    func taskEventHubStopsAndRestartsStreamReconciliation() async throws {
        let recorder = EventPipelineMetricRecorder()
        // Virtual clock: the hub's reconciliation loop and the metrics
        // proxy's snapshot loop both park on it, so idle periods are driven
        // by advancing time instead of wall-clock sleeps.
        let clock = TestClock()
        let hub = TaskEventHub<Int>(
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(100),
            clock: clock
        )

        let firstConsumerID: String
        let firstConsumerMetricCount: Int
        do {
            let firstStream = await hub.stream(for: "stream-lifecycle")
            let firstConsumerTask = Task {
                var iterator = firstStream.makeAsyncIterator()
                while await iterator.next() != nil {}
            }

            // Registration alone does not emit a consumer metric; the
            // reconciliation loop does. Wait for both loops (reconcile +
            // proxy snapshot) to park on the virtual clock, then advance a
            // full interval so the first reconcile pass fires.
            #expect(await clock.waitForWaiters(count: 2))
            clock.advance(by: .milliseconds(150))
            let firstMetrics = try await waitForConsumerMetrics(
                recorder: recorder,
                partitionID: "stream-lifecycle",
                minimumCount: 1
            )
            firstConsumerID = try #require(firstMetrics.last?.consumerID)
            firstConsumerMetricCount = firstMetrics.count

            firstConsumerTask.cancel()
            _ = await firstConsumerTask.result
        }

        // The reconciliation loop must stop once the last stream consumer
        // detaches, leaving only the metrics proxy's snapshot loop parked on
        // the clock. Wait for that state deterministically instead of
        // sleeping.
        #expect(await waitForClockWaiterCount(clock, exactly: 1))

        // Consumer removal evicts aggregator state synchronously, but its
        // terminal metric still crosses the proxy's asynchronous reporter
        // queue. Include that final metric in the baseline before proving the
        // stopped reconciliation task emits nothing while idle.
        let metricsAfterShutdown = try await waitForConsumerMetrics(
            recorder: recorder,
            partitionID: "stream-lifecycle",
            minimumCount: firstConsumerMetricCount + 1
        )
        let idleBaselineCount = metricsAfterShutdown.count

        // Drive several full snapshot intervals of virtual time. Each advance
        // wakes the proxy loop; wait for it to park again before advancing so
        // every interval actually elapses from the loop's perspective.
        for _ in 0..<3 {
            let enqueuedBefore = clock.enqueuedCount
            clock.advance(by: .milliseconds(150))
            _ = await clock.waitForEnqueuedCount(atLeast: enqueuedBefore + 1)
        }

        let metricsWhileIdle = recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
            guard case .consumerState(let state) = metric else { return nil }
            return state.partitionID == "stream-lifecycle" ? state : nil
        }
        #expect(metricsWhileIdle.count == idleBaselineCount)

        do {
            let secondStream = await hub.stream(for: "stream-lifecycle")
            let secondConsumerTask = Task {
                var iterator = secondStream.makeAsyncIterator()
                while await iterator.next() != nil {}
            }

            // The restarted reconciliation loop re-parks on the virtual
            // clock; advance a full interval so it emits the new consumer's
            // state.
            #expect(await clock.waitForWaiters(count: 2))
            clock.advance(by: .milliseconds(150))
            let resumedMetrics = try await waitForConsumerMetrics(
                recorder: recorder,
                partitionID: "stream-lifecycle",
                minimumCount: idleBaselineCount + 1
            )
            #expect(
                resumedMetrics.contains(where: {
                    $0.consumerID != firstConsumerID && $0.consumerID.hasPrefix("stream-")
                })
            )

            secondConsumerTask.cancel()
            _ = await secondConsumerTask.result
        }

        await hub.finish(taskID: "stream-lifecycle")
    }

    @Test("TaskEventHub listener consumer metrics remain listener-scoped")
    func taskEventHubListenerMetricsRemainListenerScoped() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 8,
                maxBufferedEventsPerConsumer: 1,
                overflowPolicy: .dropOldest
            ),
            metricsReporter: recorder
        )

        let listenerID = await hub.addListener(taskID: "listener-regression") { value in
            try? await Task.sleep(for: .milliseconds(100))
            _ = value
        }

        await hub.publish(1, for: "listener-regression")
        await hub.publish(2, for: "listener-regression")
        await hub.publish(3, for: "listener-regression")

        let consumerMetrics = try await waitForConsumerMetrics(
            recorder: recorder,
            partitionID: "listener-regression",
            minimumCount: 2,
            minimumDroppedEventCount: 1
        )
        #expect(
            consumerMetrics.contains(where: {
                $0.consumerID == listenerID.uuidString && $0.droppedEventCount > 0
            }))
        #expect(consumerMetrics.allSatisfy { !$0.consumerID.hasPrefix("stream-") })
    }

    @Test("TaskEventHub reports consumer latency metrics")
    func taskEventHubReportsConsumerLatencyMetrics() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 8,
                maxBufferedEventsPerConsumer: 8,
                overflowPolicy: .dropOldest
            ),
            metricsReporter: recorder
        )

        _ = await hub.addListener(taskID: "latency") { value in
            _ = value
            try? await Task.sleep(for: .milliseconds(300))
        }

        await hub.publish(1, for: "latency")
        let latencies = try await waitForLatencyMetrics(
            recorder: recorder,
            partitionID: "latency",
            minimumCount: 1
        )
        #expect(latencies.contains(where: { $0.latency >= 0 }))
    }

    @Test("TaskEventHub coalesces partition state metrics within one second")
    func taskEventHubCoalescesPartitionStateMetrics() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            metricsReporter: recorder,
            metricsSnapshotInterval: .seconds(60)
        )

        await hub.publish(1, for: "coalesce")
        await hub.publish(2, for: "coalesce")
        await hub.publish(3, for: "coalesce")
        try await Task.sleep(for: .milliseconds(50))

        let metrics = recorder.snapshot()
        let partitionMetrics = metrics.compactMap { metric -> EventPipelinePartitionStateMetric? in
            guard case .partitionState(let state) = metric else { return nil }
            return state.partitionID == "coalesce" ? state : nil
        }
        #expect(partitionMetrics.count == 1)
    }

    @Test("TaskEventHub emits aggregate snapshot metrics without high-cardinality fields")
    func taskEventHubEmitsAggregateSnapshots() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(50)
        )
        let store = IntEventStore()

        _ = await hub.addListener(taskID: "aggregate") { value in
            await store.append(value)
        }

        await hub.publish(1, for: "aggregate")
        _ = try await waitForValues(store: store, expectedCount: 1)
        let snapshots = try await waitForAggregateSnapshots(
            recorder: recorder,
            hubKind: .genericTask,
            minimumCount: 1
        )
        #expect(!snapshots.isEmpty)
        #expect(snapshots.contains(where: { $0.activePartitionCount >= 1 }))
        #expect(snapshots.contains(where: { $0.activeConsumerCount >= 1 }))
        #expect(
            snapshots.contains(where: {
                $0.totalDroppedMetricCount == 0 && $0.metricsOverflowCount == 0
            }))
    }

    @Test("Aggregate snapshot metric keeps the legacy initializer source-compatible")
    func aggregateSnapshotMetricKeepsLegacyInitializerSourceCompatibility() {
        let snapshot = EventPipelineAggregateSnapshotMetric(
            hubKind: .genericTask,
            activePartitionCount: 2,
            activeConsumerCount: 3,
            totalDroppedEventCount: 5,
            maxQueueDepth: 7,
            p50DeliveryLatency: 0.1,
            p95DeliveryLatency: 0.2,
            overflowEventCount: 11
        )

        #expect(snapshot.totalDroppedMetricCount == 0)
        #expect(snapshot.metricsOverflowCount == 0)
    }

    @Test("Slow metrics reporters do not block listener delivery")
    func slowMetricsReportersDoNotBlockListeners() async throws {
        let recorder = EventPipelineMetricRecorder()
        let slowReporter = SlowEventPipelineMetricReporter(downstream: recorder)
        let hub = TaskEventHub<Int>(
            metricsReporter: slowReporter,
            metricsSnapshotInterval: .seconds(60)
        )
        let store = IntEventStore()

        _ = await hub.addListener(taskID: "metrics-fast") { value in
            await store.append(value)
        }

        await hub.publish(1, for: "metrics-fast")
        let values = try await waitForValues(store: store, expectedCount: 1)
        #expect(values == [1])
    }

    @Test("Metrics proxy drains accepted metrics before shutdown returns")
    func metricsProxyDrainsAcceptedMetricsDuringShutdown() async {
        let recorder = EventPipelineMetricRecorder()
        let proxy = EventPipelineMetricsReporterProxy(
            hubKind: .genericTask,
            reporter: recorder,
            snapshotInterval: .seconds(60)
        )

        for index in 0..<20 {
            proxy.report(
                .partitionState(
                    EventPipelinePartitionStateMetric(
                        partitionID: "shutdown-drain-\(index)",
                        queueDepth: index,
                        droppedEventCount: 0,
                        oldestQueuedEventAge: nil
                    )
                )
            )
        }

        await proxy.shutdown()

        let drainedPartitionIDs = Set(
            recorder.snapshot().compactMap { metric -> String? in
                guard case .partitionState(let state) = metric else { return nil }
                return state.partitionID.hasPrefix("shutdown-drain-") ? state.partitionID : nil
            })
        #expect(drainedPartitionIDs.count == 20)

        proxy.report(
            .partitionState(
                EventPipelinePartitionStateMetric(
                    partitionID: "shutdown-drain-late",
                    queueDepth: 0,
                    droppedEventCount: 0,
                    oldestQueuedEventAge: nil
                )
            )
        )
        #expect(recorder.snapshot().count == drainedPartitionIDs.count)
    }

    @Test("Task event hub shutdown stops periodic metrics work")
    func taskEventHubShutdownStopsPeriodicMetricsWork() async {
        let recorder = EventPipelineMetricRecorder()
        let clock = TestClock()
        let hub = TaskEventHub<Int>(
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(100),
            clock: clock
        )

        #expect(await clock.waitForWaiters(count: 1))
        await hub.shutdown()

        #expect(clock.waiterCount == 0)
        let metricCount = recorder.snapshot().count
        clock.advance(by: .seconds(1))
        await Task.yield()
        #expect(recorder.snapshot().count == metricCount)
    }

    @Test(
        "Metrics proxy carries reporter-side overflow across snapshot windows without polluting event overflow counts")
    func metricsProxyTracksReporterSideOverflow() async throws {
        let recorder = EventPipelineMetricRecorder()
        let slowReporter = SlowEventPipelineMetricReporter(
            downstream: recorder,
            delayMicroseconds: 80_000
        )
        let proxy = EventPipelineMetricsReporterProxy(
            hubKind: .genericTask,
            reporter: slowReporter,
            snapshotInterval: .milliseconds(40),
            queueCapacity: 8
        )
        defer { proxy.cancelImmediately() }

        let start = Date()
        let floodTask = Task {
            let deadline = Date().addingTimeInterval(0.35)
            var index = 0
            while Date() < deadline {
                proxy.report(
                    .consumerDeliveryLatency(
                        EventPipelineConsumerDeliveryLatencyMetric(
                            partitionID: "proxy-overflow",
                            consumerID: "consumer-\(index)",
                            latency: 0.5
                        )
                    )
                )
                index += 1
            }
        }
        _ = await floodTask.result
        let reportElapsed = Date().timeIntervalSince(start)
        #expect(reportElapsed < 1.0)

        let overflowSnapshot = await waitForAggregateSnapshot(
            recorder: recorder,
            hubKind: .genericTask
        ) {
            $0.totalDroppedMetricCount > 0 && $0.metricsOverflowCount > 0
        }
        #expect(overflowSnapshot != nil)

        let snapshots = try await waitForAggregateSnapshots(
            recorder: recorder,
            hubKind: .genericTask,
            minimumCount: 2
        )
        #expect(snapshots.count >= 2)
        #expect(
            zip(snapshots, snapshots.dropFirst()).allSatisfy {
                $1.totalDroppedMetricCount >= $0.totalDroppedMetricCount
            })
        #expect(snapshots.contains(where: { $0.totalDroppedMetricCount > 0 }))
        #expect(
            snapshots.allSatisfy {
                $0.totalDroppedEventCount == 0 && $0.overflowEventCount == 0
            })

        let latencyMetrics = recorder.snapshot().compactMap { metric -> EventPipelineConsumerDeliveryLatencyMetric? in
            guard case .consumerDeliveryLatency(let latency) = metric else { return nil }
            return latency.partitionID == "proxy-overflow" ? latency : nil
        }
        #expect(!latencyMetrics.isEmpty)
        #expect(latencyMetrics.count < 64)
    }

    @Test("Metrics proxy never snapshots zero-depth terminal consumers as active")
    func metricsProxyDoesNotSnapshotZeroDepthTerminalConsumersAsActive() async throws {
        let recorder = EventPipelineMetricRecorder()
        let proxy = EventPipelineMetricsReporterProxy(
            hubKind: .genericTask,
            reporter: recorder,
            snapshotInterval: .milliseconds(1),
            queueCapacity: 256
        )
        defer { proxy.cancelImmediately() }

        for index in 0..<40 {
            let consumerID = "stream-\(index)"
            proxy.report(
                .consumerState(
                    EventPipelineConsumerStateMetric(
                        partitionID: "proxy-terminal-race",
                        consumerID: consumerID,
                        queueDepth: 1,
                        droppedEventCount: index,
                        oldestQueuedEventAge: 0.01
                    )
                )
            )
            await Task.yield()

            await proxy.reportTerminalConsumerState(
                EventPipelineConsumerStateMetric(
                    partitionID: "proxy-terminal-race",
                    consumerID: consumerID,
                    queueDepth: 0,
                    droppedEventCount: index,
                    oldestQueuedEventAge: nil
                )
            )
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }

        try await Task.sleep(for: .milliseconds(20))

        let snapshots = try await waitForAggregateSnapshots(
            recorder: recorder,
            hubKind: .genericTask,
            minimumCount: 10
        )
        #expect(snapshots.contains(where: { $0.activeConsumerCount == 0 && $0.maxQueueDepth == 0 }))
        #expect(
            !snapshots.contains(where: {
                $0.activeConsumerCount > 0 && $0.maxQueueDepth == 0
            }))
    }

    @Test("Metrics proxy keeps subsequent snapshots cleared after awaited terminal eviction")
    func metricsProxyKeepsSubsequentSnapshotsClearedAfterAwaitedTerminalEviction() async throws {
        let recorder = EventPipelineMetricRecorder()
        let proxy = EventPipelineMetricsReporterProxy(
            hubKind: .genericTask,
            reporter: recorder,
            snapshotInterval: .milliseconds(1),
            queueCapacity: 256
        )
        defer { proxy.cancelImmediately() }

        proxy.report(
            .consumerState(
                EventPipelineConsumerStateMetric(
                    partitionID: "proxy-terminal-serialization",
                    consumerID: "stream-terminal-serialization",
                    queueDepth: 0,
                    droppedEventCount: 0,
                    oldestQueuedEventAge: nil
                )
            )
        )

        let activeSnapshot = try #require(
            await waitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: { $0.activeConsumerCount >= 1 && $0.maxQueueDepth == 0 }
            )
        )
        #expect(activeSnapshot.activeConsumerCount >= 1)

        await proxy.reportTerminalConsumerState(
            EventPipelineConsumerStateMetric(
                partitionID: "proxy-terminal-serialization",
                consumerID: "stream-terminal-serialization",
                queueDepth: 0,
                droppedEventCount: 7,
                oldestQueuedEventAge: nil
            )
        )

        let terminalMetric = try #require(
            await waitForConsumerMetric(
                recorder: recorder,
                partitionID: "proxy-terminal-serialization",
                consumerID: "stream-terminal-serialization",
                predicate: {
                    $0.queueDepth == 0 && $0.oldestQueuedEventAge == nil && $0.droppedEventCount == 7
                }
            )
        )
        #expect(terminalMetric.droppedEventCount == 7)

        let baselineSnapshotCount = recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
            guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
            return snapshot.hubKind == .genericTask ? snapshot : nil
        }.count
        let subsequentSnapshots = try await waitForAdditionalAggregateSnapshots(
            recorder: recorder,
            hubKind: .genericTask,
            existingCount: baselineSnapshotCount,
            additionalCount: 5
        )
        #expect(!subsequentSnapshots.isEmpty)
        #expect(
            subsequentSnapshots.allSatisfy {
                $0.activeConsumerCount == 0 && $0.maxQueueDepth == 0
            })
    }

    @Test("Metrics proxy guarantees terminal consumer eviction during input overflow")
    func metricsProxyGuaranteesTerminalConsumerEvictionUnderInputOverflow() async throws {
        let recorder = EventPipelineMetricRecorder()
        let proxy = EventPipelineMetricsReporterProxy(
            hubKind: .genericTask,
            reporter: recorder,
            snapshotInterval: .milliseconds(10),
            queueCapacity: 1
        )
        defer { proxy.cancelImmediately() }

        proxy.report(
            .consumerState(
                EventPipelineConsumerStateMetric(
                    partitionID: "proxy-terminal-overflow",
                    consumerID: "stream-terminal-overflow",
                    queueDepth: 1,
                    droppedEventCount: 0,
                    oldestQueuedEventAge: 0.01
                )
            )
        )

        let activeSnapshot = try #require(
            await waitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: { $0.activeConsumerCount >= 1 && $0.maxQueueDepth >= 1 }
            )
        )
        #expect(activeSnapshot.activeConsumerCount >= 1)

        await proxy.reportTerminalConsumerState(
            EventPipelineConsumerStateMetric(
                partitionID: "proxy-terminal-overflow",
                consumerID: "stream-terminal-overflow",
                queueDepth: 0,
                droppedEventCount: 3,
                oldestQueuedEventAge: nil
            )
        )

        for _ in 0..<5_000 {
            proxy.report(
                .consumerState(
                    EventPipelineConsumerStateMetric(
                        partitionID: "proxy-terminal-overflow",
                        consumerID: "stream-terminal-overflow",
                        queueDepth: 1,
                        droppedEventCount: 3,
                        oldestQueuedEventAge: 0.01
                    )
                )
            )
        }
        await Task.yield()

        let terminalMetric = try #require(
            await waitForConsumerMetric(
                recorder: recorder,
                partitionID: "proxy-terminal-overflow",
                consumerID: "stream-terminal-overflow",
                predicate: {
                    $0.queueDepth == 0 && $0.oldestQueuedEventAge == nil && $0.droppedEventCount == 3
                }
            )
        )
        #expect(terminalMetric.queueDepth == 0)

        let terminalMetricCount = recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
            guard case .consumerState(let state) = metric else { return nil }
            guard state.partitionID == "proxy-terminal-overflow" else { return nil }
            guard state.consumerID == "stream-terminal-overflow" else { return nil }
            return state.queueDepth == 0 && state.oldestQueuedEventAge == nil && state.droppedEventCount == 3
                ? state : nil
        }.count
        #expect(terminalMetricCount == 1)

        let clearedSnapshot = try #require(
            await waitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: { $0.activeConsumerCount == 0 && $0.maxQueueDepth == 0 }
            )
        )
        #expect(clearedSnapshot.activeConsumerCount == 0)

        let eventDropSnapshot = try #require(
            await waitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: {
                    $0.totalDroppedEventCount == 3 && $0.overflowEventCount == 3
                }
            )
        )
        #expect(eventDropSnapshot.totalDroppedEventCount == 3)
        #expect(eventDropSnapshot.overflowEventCount == 3)

        let metricOverflowSnapshot = try #require(
            await waitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: { $0.totalDroppedMetricCount > 0 }
            )
        )
        #expect(metricOverflowSnapshot.totalDroppedMetricCount > 0)
    }

    @Test("Low-latency consumer metrics are sampled")
    func lowLatencyConsumerMetricsAreSampled() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            metricsReporter: recorder,
            metricsSnapshotInterval: .seconds(60)
        )

        _ = await hub.addListener(taskID: "sampled-latency") { value in
            _ = value
        }

        for value in 0..<128 {
            await hub.publish(value, for: "sampled-latency")
        }
        try await Task.sleep(for: .milliseconds(100))

        let metrics = recorder.snapshot()
        let latencies = metrics.compactMap { metric -> EventPipelineConsumerDeliveryLatencyMetric? in
            guard case .consumerDeliveryLatency(let latency) = metric else { return nil }
            return latency.partitionID == "sampled-latency" ? latency : nil
        }
        #expect(!latencies.isEmpty)
        #expect(latencies.count < 128)
    }
}

private func waitForValues(
    store: IntEventStore,
    expectedCount: Int
) async throws -> [Int] {
    for _ in 0..<50 {
        let values = await store.snapshot()
        if values.count >= expectedCount {
            return values
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    return await store.snapshot()
}

private func waitForEventHubCondition(
    timeout: TimeInterval,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    return await condition()
}

private func waitForNetworkEvents(
    recorder: NetworkEventRecorder,
    expectedCount: Int
) async throws -> [NetworkEvent] {
    for _ in 0..<50 {
        let events = await recorder.snapshot()
        if events.count >= expectedCount {
            return events
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    return await recorder.snapshot()
}

private func waitForLatencyMetrics(
    recorder: EventPipelineMetricRecorder,
    partitionID: String,
    minimumCount: Int
) async throws -> [EventPipelineConsumerDeliveryLatencyMetric] {
    for _ in 0..<50 {
        let latencies = recorder.snapshot().compactMap { metric -> EventPipelineConsumerDeliveryLatencyMetric? in
            guard case .consumerDeliveryLatency(let latency) = metric else { return nil }
            return latency.partitionID == partitionID ? latency : nil
        }
        if latencies.count >= minimumCount {
            return latencies
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    return recorder.snapshot().compactMap { metric -> EventPipelineConsumerDeliveryLatencyMetric? in
        guard case .consumerDeliveryLatency(let latency) = metric else { return nil }
        return latency.partitionID == partitionID ? latency : nil
    }
}

/// Bounded poll for an exact TestClock waiter count. Used to observe a loop
/// stopping (waiters dropping), which waitForWaiters(count:) — an at-least
/// condition — cannot express.
private func waitForClockWaiterCount(
    _ clock: TestClock,
    exactly target: Int,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if clock.waiterCount == target { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return clock.waiterCount == target
}

private func waitForConsumerMetrics(
    recorder: EventPipelineMetricRecorder,
    partitionID: String,
    minimumCount: Int,
    minimumDroppedEventCount: Int = 0
) async throws -> [EventPipelineConsumerStateMetric] {
    for _ in 0..<50 {
        let metrics = recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
            guard case .consumerState(let state) = metric else { return nil }
            return state.partitionID == partitionID ? state : nil
        }
        let maxDroppedEventCount = metrics.map(\.droppedEventCount).max() ?? 0
        if metrics.count >= minimumCount, maxDroppedEventCount >= minimumDroppedEventCount {
            return metrics
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    return recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
        guard case .consumerState(let state) = metric else { return nil }
        return state.partitionID == partitionID ? state : nil
    }
}

private func waitForConsumerMetric(
    recorder: EventPipelineMetricRecorder,
    partitionID: String,
    consumerID: String,
    predicate: (EventPipelineConsumerStateMetric) -> Bool
) async -> EventPipelineConsumerStateMetric? {
    for _ in 0..<100 {
        let metric = recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
            guard case .consumerState(let state) = metric else { return nil }
            return state.partitionID == partitionID && state.consumerID == consumerID ? state : nil
        }.last(where: predicate)
        if let metric {
            return metric
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    return recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
        guard case .consumerState(let state) = metric else { return nil }
        return state.partitionID == partitionID && state.consumerID == consumerID ? state : nil
    }.last(where: predicate)
}

private func waitForAggregateSnapshots(
    recorder: EventPipelineMetricRecorder,
    hubKind: EventPipelineHubKind,
    minimumCount: Int
) async throws -> [EventPipelineAggregateSnapshotMetric] {
    for _ in 0..<50 {
        let snapshots = recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
            guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
            return snapshot.hubKind == hubKind ? snapshot : nil
        }
        if snapshots.count >= minimumCount {
            return snapshots
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    return recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
        guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
        return snapshot.hubKind == hubKind ? snapshot : nil
    }
}

private func waitForAdditionalAggregateSnapshots(
    recorder: EventPipelineMetricRecorder,
    hubKind: EventPipelineHubKind,
    existingCount: Int,
    additionalCount: Int
) async throws -> [EventPipelineAggregateSnapshotMetric] {
    for _ in 0..<100 {
        let snapshots = recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
            guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
            return snapshot.hubKind == hubKind ? snapshot : nil
        }
        if snapshots.count >= existingCount + additionalCount {
            return Array(snapshots.dropFirst(existingCount))
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    let snapshots = recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
        guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
        return snapshot.hubKind == hubKind ? snapshot : nil
    }
    return Array(snapshots.dropFirst(existingCount))
}

private func waitForAggregateSnapshot(
    recorder: EventPipelineMetricRecorder,
    hubKind: EventPipelineHubKind,
    predicate: (EventPipelineAggregateSnapshotMetric) -> Bool
) async -> EventPipelineAggregateSnapshotMetric? {
    for _ in 0..<100 {
        let snapshot = recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
            guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
            return snapshot.hubKind == hubKind ? snapshot : nil
        }.last(where: predicate)
        if let snapshot {
            return snapshot
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    return recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
        guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
        return snapshot.hubKind == hubKind ? snapshot : nil
    }.last(where: predicate)
}

private func requestID(of event: NetworkEvent) -> UUID {
    switch event {
    case .requestStart(let requestID, _, _, _):
        return requestID
    case .requestAdapted(let requestID, _, _, _):
        return requestID
    case .responseReceived(let requestID, _, _):
        return requestID
    case .retryScheduled(let requestID, _, _, _):
        return requestID
    case .requestFinished(let requestID, _, _):
        return requestID
    case .requestFailed(let requestID, _, _):
        return requestID
    case .cacheRevalidation(let originalID, _):
        return originalID
    }
}
