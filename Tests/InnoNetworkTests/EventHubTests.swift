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
