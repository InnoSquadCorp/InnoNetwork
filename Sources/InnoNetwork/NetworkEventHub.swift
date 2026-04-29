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

    package func publish(_ event: NetworkEvent, requestID: UUID, observers: [any NetworkEventObserving]) {
        guard !observers.isEmpty else { return }
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
