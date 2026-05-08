import Foundation

package actor NetworkEventHub {
    private struct PendingEvent: Sendable {
        let event: NetworkEvent
        let observers: [any NetworkEventObserving]
        let enqueuedAt: Date
    }

    private struct PartitionState {
        var queue = FIFOBuffer<PendingEvent>()
        var observerChains: [Int: EventDeliveryChain<NetworkEvent>] = [:]
        var isDraining = false
        var isClosed = false
        var droppedEventCount = 0
    }

    private var partitions: [UUID: PartitionState] = [:]
    private let policy: EventDeliveryPolicy
    private let metricsProxy: EventPipelineMetricsReporterProxy?
    private var metricsReporter: (any EventPipelineMetricsReporting)? { metricsProxy }

    /// Monotonically increasing per-hub sequence counter, allocated through
    /// ``allocateSequenceID()``. Held inside the hub actor so increments are
    /// totally ordered with respect to publish calls. Currently advisory —
    /// the 4.0.0 ordered-event-queue change wires it into the delivery
    /// chain so consumers can correlate observed events with the publish
    /// order that produced them.
    private var nextSequenceID: UInt64 = 0

    /// Returns the next monotonic sequence ID and advances the counter.
    /// Wrap-around on `UInt64.max` is treated as a 0-restart; callers that
    /// store sequence IDs across very-long-running hubs should not assume
    /// strict monotonicity beyond the wrap point. In practice the counter
    /// only needs to be unique within a single request lifecycle.
    private func allocateSequenceID() -> UInt64 {
        if nextSequenceID == .max {
            nextSequenceID = 0
        } else {
            nextSequenceID += 1
        }
        return nextSequenceID
    }

    /// Returns the most recently allocated sequence ID. Exposed to the
    /// package's own test target (and only the test target) so the prep
    /// counter introduced ahead of the ordered-event-queue change can be
    /// verified to advance on every publish call. Production code does
    /// not read this value.
    package func currentSequenceIDForTesting() -> UInt64 {
        nextSequenceID
    }

    package init(
        policy: EventDeliveryPolicy = .default,
        metricsReporter: (any EventPipelineMetricsReporting)? = nil,
        hubKind: EventPipelineHubKind = .networkRequest,
        metricsSnapshotInterval: Duration = .seconds(30)
    ) {
        self.policy = policy
        self.metricsProxy = metricsReporter.map {
            EventPipelineMetricsReporterProxy(
                hubKind: hubKind,
                reporter: $0,
                snapshotInterval: metricsSnapshotInterval
            )
        }
    }

    deinit {
        metricsProxy?.shutdown()
    }

    /// Enqueues `event` for delivery to `observers` partitioned by `requestID`.
    ///
    /// Observers are bound at publish time, so this hub does not retain
    /// historical events for late subscribers. After ``finish(requestID:)``
    /// is called, subsequent `publish` calls for the same partition are
    /// silently dropped — request lifecycles are terminal, and resurrecting
    /// a closed partition with new events would risk delivering them after
    /// the awaiting consumer has already cleaned up.
    package func publish(_ event: NetworkEvent, requestID: UUID, observers: [any NetworkEventObserving]) {
        guard !observers.isEmpty else { return }
        // Advance the per-hub sequence counter so subsequent enqueues land
        // with a strictly increasing tag. The 4.0.0 ordered-event-queue
        // change consumes this value in `EventDeliveryChain` to break ties
        // when two observers race the actor scheduler; for now the result
        // is intentionally discarded.
        _ = allocateSequenceID()
        var partition = partitions[requestID] ?? PartitionState()
        guard !partition.isClosed else { return }
        if partition.queue.count >= policy.maxBufferedEventsPerPartition {
            partition.droppedEventCount += 1
            switch policy.overflowPolicy {
            case .dropOldest:
                _ = partition.queue.popFirst()
            case .dropNewest:
                partitions[requestID] = partition
                reportPartitionMetric(for: requestID, partition: partition)
                return
            }
        }
        partition.queue.append(PendingEvent(event: event, observers: observers, enqueuedAt: .now))
        partitions[requestID] = partition
        reportPartitionMetric(for: requestID, partition: partition)
        startDrainIfNeeded(requestID: requestID)
    }

    package func finish(requestID: UUID) async {
        guard var partition = partitions[requestID] else { return }
        partition.isClosed = true
        partitions[requestID] = partition
        await cleanupPartitionIfPossible(requestID: requestID)
    }

    private func startDrainIfNeeded(requestID: UUID) {
        guard var partition = partitions[requestID], !partition.isDraining else { return }
        partition.isDraining = true
        partitions[requestID] = partition
        Task {
            await drain(requestID: requestID)
        }
    }

    private func drain(requestID: UUID) async {
        while let pending = popNextEvent(requestID: requestID) {
            for (index, observer) in pending.observers.enumerated() {
                let chain = observerChain(for: requestID, index: index, observer: observer)
                await chain.enqueue(pending.event, enqueuedAt: pending.enqueuedAt)
            }
        }

        guard var partition = partitions[requestID] else { return }
        partition.isDraining = false
        partitions[requestID] = partition

        if !partition.queue.isEmpty {
            startDrainIfNeeded(requestID: requestID)
            return
        }

        await cleanupPartitionIfPossible(requestID: requestID)
    }

    private func popNextEvent(requestID: UUID) -> PendingEvent? {
        guard var partition = partitions[requestID] else { return nil }
        let pending = partition.queue.popFirst()
        partitions[requestID] = partition
        reportPartitionMetric(for: requestID, partition: partition)
        return pending
    }

    private func observerChain(
        for requestID: UUID,
        index: Int,
        observer: any NetworkEventObserving
    ) -> EventDeliveryChain<NetworkEvent> {
        var partition = partitions[requestID] ?? PartitionState()
        if let existing = partition.observerChains[index] {
            partitions[requestID] = partition
            return existing
        }

        let partitionID = requestID.uuidString
        let consumerID = "observer-\(index)"
        let chain = EventDeliveryChain<NetworkEvent>(
            partitionID: partitionID,
            consumerID: consumerID,
            policy: policy,
            metricsReporter: metricsReporter
        ) { event in
            await observer.handle(event)
        }
        partition.observerChains[index] = chain
        partitions[requestID] = partition
        return chain
    }

    private func cleanupPartitionIfPossible(requestID: UUID) async {
        guard let partition = partitions[requestID] else { return }
        guard partition.isClosed, !partition.isDraining, partition.queue.isEmpty else { return }

        partitions.removeValue(forKey: requestID)
        for chain in partition.observerChains.values {
            await chain.finish()
        }
    }

    private func reportPartitionMetric(for requestID: UUID, partition: PartitionState) {
        metricsReporter?.report(
            .partitionState(
                EventPipelinePartitionStateMetric(
                    partitionID: requestID.uuidString,
                    queueDepth: partition.queue.count,
                    droppedEventCount: partition.droppedEventCount,
                    oldestQueuedEventAge: partition.queue.first.map { Date.now.timeIntervalSince($0.enqueuedAt) }
                )
            )
        )
    }
}
