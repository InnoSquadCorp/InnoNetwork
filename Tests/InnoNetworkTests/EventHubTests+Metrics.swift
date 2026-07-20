import Darwin
import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

extension EventHubTests {
    @Test("TaskEventHub reports AsyncStream overflow metrics and aggregate snapshots")
    func taskEventHubReportsStreamOverflowMetrics() async throws {
        let recorder = EventHubMetricRecorder()
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

        let consumerMetrics = try await eventHubWaitForConsumerMetrics(
            recorder: recorder,
            partitionID: "stream-overflow",
            minimumCount: 3,
            minimumDroppedEventCount: 2
        )
        let streamMetrics = consumerMetrics.filter { $0.consumerID.hasPrefix("stream-") }
        #expect(!streamMetrics.isEmpty)
        #expect(Set(streamMetrics.map(\.droppedEventCount)).isSuperset(of: [1, 2]))
        #expect(streamMetrics.contains(where: { $0.queueDepth == 1 }))

        let snapshots = try await eventHubWaitForAggregateSnapshots(
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
        let recorder = EventHubMetricRecorder()
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
            await eventHubWaitForAggregateSnapshot(
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

        let subsequentSnapshots = try await eventHubWaitForAdditionalAggregateSnapshots(
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
        let recorder = EventHubMetricRecorder()
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

        let consumerMetrics = try await eventHubWaitForConsumerMetrics(
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
        let recorder = EventHubMetricRecorder()
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

        let initialMetrics = try await eventHubWaitForConsumerMetrics(
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

        let reconciledBaselineMetrics = try await eventHubWaitForConsumerMetrics(
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

        let latestMetrics = try await eventHubWaitForConsumerMetrics(
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

        let snapshots = try await eventHubWaitForAggregateSnapshots(
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
        let recorder = EventHubMetricRecorder()
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

            let initialMetrics = try await eventHubWaitForConsumerMetrics(
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
                await eventHubWaitForAggregateSnapshot(
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
            await eventHubWaitForConsumerMetric(
                recorder: recorder,
                partitionID: "stream-cancelled",
                consumerID: consumerID,
                predicate: { $0.queueDepth == 0 && $0.oldestQueuedEventAge == nil }
            )
        )
        #expect(terminalMetric.droppedEventCount == 2)

        let clearedSnapshot = try #require(
            await eventHubWaitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: { $0.activeConsumerCount == 0 && $0.maxQueueDepth == 0 }
            )
        )
        #expect(clearedSnapshot.activeConsumerCount == 0)
    }

    @Test("TaskEventHub finish evicts active AsyncStream consumers from aggregate snapshots")
    func taskEventHubFinishEvictsActiveStreamConsumersFromAggregateSnapshots() async throws {
        let recorder = EventHubMetricRecorder()
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

            let initialMetrics = try await eventHubWaitForConsumerMetrics(
                recorder: recorder,
                partitionID: "stream-finish",
                minimumCount: 1
            )
            consumerID = try #require(
                initialMetrics.last(where: { $0.consumerID.hasPrefix("stream-") })?.consumerID
            )

            let activeSnapshot = try #require(
                await eventHubWaitForAggregateSnapshot(
                    recorder: recorder,
                    hubKind: .genericTask,
                    predicate: { $0.activeConsumerCount >= 1 }
                )
            )
            #expect(activeSnapshot.activeConsumerCount >= 1)

            await hub.finish(taskID: "stream-finish")

            let clearedSnapshot = try #require(
                await eventHubWaitForAggregateSnapshot(
                    recorder: recorder,
                    hubKind: .genericTask,
                    predicate: { $0.activeConsumerCount == 0 }
                )
            )
            #expect(clearedSnapshot.activeConsumerCount == 0)

            _ = await consumerTask.result
        }

        let terminalMetric = try #require(
            await eventHubWaitForConsumerMetric(
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
        let recorder = EventHubMetricRecorder()
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

        let initialMetrics = try await eventHubWaitForConsumerMetrics(
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
            await eventHubWaitForAggregateSnapshot(
                recorder: recorder,
                hubKind: .genericTask,
                predicate: { $0.activeConsumerCount >= 1 && $0.maxQueueDepth >= 1 }
            )
        )
        #expect(activeSnapshot.activeConsumerCount >= 1)

        await hub.finish(taskID: "stream-finish-serialization")

        let terminalMetric = try #require(
            await eventHubWaitForConsumerMetric(
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

    @Test("TaskEventHub stops idle stream reconciliation and restarts on a new stream")
    func taskEventHubStopsAndRestartsStreamReconciliation() async throws {
        let recorder = EventHubMetricRecorder()
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
            let firstMetrics = try await eventHubWaitForConsumerMetrics(
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
        #expect(await eventHubWaitForClockWaiterCount(clock, exactly: 1))

        // Consumer removal evicts aggregator state synchronously, but its
        // terminal metric still crosses the proxy's asynchronous reporter
        // queue. Include that final metric in the baseline before proving the
        // stopped reconciliation task emits nothing while idle.
        let metricsAfterShutdown = try await eventHubWaitForConsumerMetrics(
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
            let resumedMetrics = try await eventHubWaitForConsumerMetrics(
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
        let recorder = EventHubMetricRecorder()
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

        let consumerMetrics = try await eventHubWaitForConsumerMetrics(
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
        let recorder = EventHubMetricRecorder()
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
        let latencies = try await eventHubWaitForLatencyMetrics(
            recorder: recorder,
            partitionID: "latency",
            minimumCount: 1
        )
        #expect(latencies.contains(where: { $0.latency >= 0 }))
    }

    @Test("TaskEventHub coalesces partition state metrics within one second")
    func taskEventHubCoalescesPartitionStateMetrics() async throws {
        let recorder = EventHubMetricRecorder()
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
        let recorder = EventHubMetricRecorder()
        let hub = TaskEventHub<Int>(
            metricsReporter: recorder,
            metricsSnapshotInterval: .milliseconds(50)
        )
        let store = EventHubIntEventStore()

        _ = await hub.addListener(taskID: "aggregate") { value in
            await store.append(value)
        }

        await hub.publish(1, for: "aggregate")
        _ = try await eventHubWaitForValues(store: store, expectedCount: 1)
        let snapshots = try await eventHubWaitForAggregateSnapshots(
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

}
