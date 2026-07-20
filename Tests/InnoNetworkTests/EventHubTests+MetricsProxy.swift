import Darwin
import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

extension EventHubTests {
    @Test("Slow metrics reporters do not block listener delivery")
    func slowMetricsReportersDoNotBlockListeners() async throws {
        let recorder = EventHubMetricRecorder()
        let slowReporter = EventHubSlowMetricReporter(downstream: recorder)
        let hub = TaskEventHub<Int>(
            metricsReporter: slowReporter,
            metricsSnapshotInterval: .seconds(60)
        )
        let store = EventHubIntEventStore()

        _ = await hub.addListener(taskID: "metrics-fast") { value in
            await store.append(value)
        }

        await hub.publish(1, for: "metrics-fast")
        let values = try await eventHubWaitForValues(store: store, expectedCount: 1)
        #expect(values == [1])
    }

    @Test("Metrics proxy drains accepted metrics before shutdown returns")
    func metricsProxyDrainsAcceptedMetricsDuringShutdown() async {
        let recorder = EventHubMetricRecorder()
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
        let recorder = EventHubMetricRecorder()
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
        let recorder = EventHubMetricRecorder()
        let slowReporter = EventHubSlowMetricReporter(
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

        let overflowSnapshot = await eventHubWaitForAggregateSnapshot(
            recorder: recorder,
            hubKind: .genericTask
        ) {
            $0.totalDroppedMetricCount > 0 && $0.metricsOverflowCount > 0
        }
        #expect(overflowSnapshot != nil)

        let snapshots = try await eventHubWaitForAggregateSnapshots(
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
        let recorder = EventHubMetricRecorder()
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

        let snapshots = try await eventHubWaitForAggregateSnapshots(
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
        let recorder = EventHubMetricRecorder()
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
            await eventHubWaitForAggregateSnapshot(
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
            await eventHubWaitForConsumerMetric(
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
        let subsequentSnapshots = try await eventHubWaitForAdditionalAggregateSnapshots(
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
        let recorder = EventHubMetricRecorder()
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
            await eventHubWaitForAggregateSnapshot(
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
            await eventHubWaitForConsumerMetric(
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
            await eventHubWaitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: { $0.activeConsumerCount == 0 && $0.maxQueueDepth == 0 }
            )
        )
        #expect(clearedSnapshot.activeConsumerCount == 0)

        let eventDropSnapshot = try #require(
            await eventHubWaitForAggregateSnapshot(
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
            await eventHubWaitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: { $0.totalDroppedMetricCount > 0 }
            )
        )
        #expect(metricOverflowSnapshot.totalDroppedMetricCount > 0)
    }

    @Test("Low-latency consumer metrics are sampled")
    func lowLatencyConsumerMetricsAreSampled() async throws {
        let recorder = EventHubMetricRecorder()
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
