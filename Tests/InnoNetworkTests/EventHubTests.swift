import Darwin
import Foundation
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

        let values = try await waitForValues(store: store, expectedCount: 2)
        #expect(values == [1, 3] || values == [2, 3])

        let metrics = recorder.snapshot()
        let consumerMetrics = metrics.compactMap { metric -> EventPipelineConsumerStateMetric? in
            guard case .consumerState(let state) = metric else { return nil }
            return state.partitionID == "task-overflow" ? state : nil
        }
        #expect(consumerMetrics.contains(where: { $0.droppedEventCount > 0 }))
        #expect(consumerMetrics.allSatisfy { !$0.consumerID.hasPrefix("stream-") })
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
            snapshot.totalDroppedEventCount >= 2 &&
            snapshot.overflowEventCount >= 2 &&
            snapshot.totalDroppedMetricCount == 0 &&
            snapshot.metricsOverflowCount == 0
        }
        #expect(hasExpectedOverflowSnapshot)

        let bufferedValue = try #require(await iterator.next())
        #expect(bufferedValue == 3)

        await hub.finish(taskID: "stream-overflow")
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
        let hub = TaskEventHub<Int>(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 8,
                maxBufferedEventsPerConsumer: 2,
                overflowPolicy: .dropOldest
            ),
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(30)
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

        try await Task.sleep(for: .milliseconds(250))

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

        try await Task.sleep(for: .milliseconds(250))

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
        #expect(snapshots.contains(where: {
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
                metric.consumerID.hasPrefix("stream-") &&
                metric.queueDepth == 1 &&
                metric.droppedEventCount == 2
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
            $0.consumerID.hasPrefix("stream-") &&
            $0.queueDepth == 1 &&
            $0.droppedEventCount == 2
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
                    $0.queueDepth == 0 &&
                    $0.oldestQueuedEventAge == nil &&
                    $0.droppedEventCount == 2
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
        #expect(subsequentSnapshots.allSatisfy {
            $0.activeConsumerCount == 0 && $0.maxQueueDepth == 0
        })
    }

    @Test("TaskEventHub stops idle stream reconciliation and restarts on a new stream")
    func taskEventHubStopsAndRestartsStreamReconciliation() async throws {
        let recorder = EventPipelineMetricRecorder()
        let hub = TaskEventHub<Int>(
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(100)
        )

        let firstConsumerID: String
        do {
            let firstStream = await hub.stream(for: "stream-lifecycle")
            let firstConsumerTask = Task {
                var iterator = firstStream.makeAsyncIterator()
                while await iterator.next() != nil {}
            }

            let firstMetrics = try await waitForConsumerMetrics(
                recorder: recorder,
                partitionID: "stream-lifecycle",
                minimumCount: 1
            )
            firstConsumerID = try #require(firstMetrics.last?.consumerID)

            firstConsumerTask.cancel()
            _ = await firstConsumerTask.result
        }

        try await Task.sleep(for: .milliseconds(250))

        let metricsAfterShutdown = recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
            guard case .consumerState(let state) = metric else { return nil }
            return state.partitionID == "stream-lifecycle" ? state : nil
        }
        let idleBaselineCount = metricsAfterShutdown.count

        try await Task.sleep(for: .milliseconds(250))

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
        #expect(consumerMetrics.contains(where: {
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
        #expect(snapshots.contains(where: {
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

    @Test("Metrics proxy carries reporter-side overflow across snapshot windows without polluting event overflow counts")
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
        defer { proxy.shutdown() }

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

        let snapshots = try await waitForAggregateSnapshots(
            recorder: recorder,
            hubKind: .genericTask,
            minimumCount: 3
        )
        #expect(zip(snapshots, snapshots.dropFirst()).allSatisfy {
            $1.totalDroppedMetricCount >= $0.totalDroppedMetricCount
        })
        #expect(snapshots.contains(where: { $0.totalDroppedMetricCount > 0 }))
        #expect(snapshots.dropFirst().contains(where: { $0.metricsOverflowCount > 0 }))
        #expect(snapshots.allSatisfy {
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
        defer { proxy.shutdown() }

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
        #expect(!snapshots.contains(where: {
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
        defer { proxy.shutdown() }

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
                    $0.queueDepth == 0 &&
                    $0.oldestQueuedEventAge == nil &&
                    $0.droppedEventCount == 7
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
        #expect(subsequentSnapshots.allSatisfy {
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
        defer { proxy.shutdown() }

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
                    $0.queueDepth == 0 &&
                    $0.oldestQueuedEventAge == nil &&
                    $0.droppedEventCount == 3
                }
            )
        )
        #expect(terminalMetric.queueDepth == 0)

        let terminalMetricCount = recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
            guard case .consumerState(let state) = metric else { return nil }
            guard state.partitionID == "proxy-terminal-overflow" else { return nil }
            guard state.consumerID == "stream-terminal-overflow" else { return nil }
            return state.queueDepth == 0 && state.oldestQueuedEventAge == nil && state.droppedEventCount == 3 ? state : nil
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

        let overflowSnapshot = try #require(
            await waitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: {
                    $0.totalDroppedMetricCount > 0 &&
                    $0.totalDroppedEventCount == 3 &&
                    $0.overflowEventCount == 3
                }
            )
        )
        #expect(overflowSnapshot.totalDroppedMetricCount > 0)
        #expect(overflowSnapshot.totalDroppedEventCount == 3)
        #expect(overflowSnapshot.overflowEventCount == 3)
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
    }
}
