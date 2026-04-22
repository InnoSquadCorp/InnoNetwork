import Foundation


package actor TaskEventHub<Event: Sendable> {
    package typealias Listener = @Sendable (Event) async -> Void

    private struct PendingEvent: Sendable {
        let event: Event
        let enqueuedAt: Date
    }

    private struct StreamConsumerState {
        let consumerID: String
        var continuation: AsyncStream<Event>.Continuation
        var queuedEventDates = FIFOBuffer<Date>()
        var droppedEventCount = 0

        init(id: UUID, continuation: AsyncStream<Event>.Continuation) {
            self.consumerID = "stream-\(id.uuidString)"
            self.continuation = continuation
        }

        mutating func recordYieldResult(
            _ result: AsyncStream<Event>.Continuation.YieldResult,
            enqueuedAt: Date,
            maxBufferedEvents: Int
        ) {
            switch result {
            case .enqueued(let remaining):
                queuedEventDates.append(enqueuedAt)
                reconcileQueueDepth(actualDepth: max(0, maxBufferedEvents - remaining))
            case .dropped:
                droppedEventCount += 1
                _ = queuedEventDates.popFirst()
                queuedEventDates.append(enqueuedAt)
                reconcileQueueDepth(actualDepth: maxBufferedEvents)
            case .terminated:
                queuedEventDates.removeAll()
            @unknown default:
                queuedEventDates.removeAll()
            }
        }

        var queueDepth: Int {
            queuedEventDates.count
        }

        var oldestQueuedEventAge: TimeInterval? {
            queuedEventDates.first.map { Date.now.timeIntervalSince($0) }
        }

        private mutating func reconcileQueueDepth(actualDepth: Int) {
            while queuedEventDates.count > actualDepth {
                _ = queuedEventDates.popFirst()
            }
        }
    }

    private struct PartitionState {
        var listeners: [UUID: EventDeliveryChain<Event>] = [:]
        var streamConsumers: [UUID: StreamConsumerState] = [:]
        var queue = FIFOBuffer<PendingEvent>()
        var isDraining = false
        var isClosed = false
        var droppedEventCount = 0
    }

    private var partitions: [String: PartitionState] = [:]
    private let policy: EventDeliveryPolicy
    private let metricsProxy: EventPipelineMetricsReporterProxy?
    private let metricsSnapshotInterval: Duration?
    private var streamMetricsReconciliationTask: Task<Void, Never>?
    private var metricsReporter: (any EventPipelineMetricsReporting)? { metricsProxy }

    package init(
        policy: EventDeliveryPolicy = .default,
        metricsReporter: (any EventPipelineMetricsReporting)? = nil,
        hubKind: EventPipelineHubKind = .genericTask,
        metricsSnapshotInterval: Duration = .seconds(30)
    ) {
        self.policy = policy
        self.metricsSnapshotInterval = metricsReporter == nil ? nil : metricsSnapshotInterval
        self.metricsProxy = metricsReporter.map {
            EventPipelineMetricsReporterProxy(
                hubKind: hubKind,
                reporter: $0,
                snapshotInterval: metricsSnapshotInterval
            )
        }
    }

    deinit {
        streamMetricsReconciliationTask?.cancel()
        metricsProxy?.shutdown()
    }

    package func addListener(taskID: String, listener: @escaping Listener) -> UUID {
        let listenerID = UUID()
        var partition = partitions[taskID] ?? PartitionState()
        partition.listeners[listenerID] = EventDeliveryChain(
            partitionID: taskID,
            consumerID: listenerID.uuidString,
            policy: policy,
            metricsReporter: metricsReporter,
            handler: listener
        )
        partitions[taskID] = partition
        return listenerID
    }

    package func removeListener(taskID: String, listenerID: UUID) async {
        guard var partition = partitions[taskID] else { return }
        let chain = partition.listeners.removeValue(forKey: listenerID)
        partitions[taskID] = partition
        await chain?.finish()
        await cleanupPartitionIfPossible(taskID: taskID)
    }

    package func listenerCount(taskID: String) -> Int {
        partitions[taskID]?.listeners.count ?? 0
    }

    package func stream(for taskID: String) -> AsyncStream<Event> {
        let stream = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(policy.maxBufferedEventsPerConsumer)
        )
        let continuationID = UUID()
        var partition = partitions[taskID] ?? PartitionState()
        partition.streamConsumers[continuationID] = StreamConsumerState(
            id: continuationID,
            continuation: stream.continuation
        )
        partitions[taskID] = partition
        updateStreamMetricsReconciliationTaskState()
        stream.continuation.onTermination = { @Sendable _ in
            Task {
                await self.removeContinuation(taskID: taskID, continuationID: continuationID)
            }
        }
        return stream.stream
    }

    package func publish(_ event: Event, for taskID: String) {
        var partition = partitions[taskID] ?? PartitionState()
        guard !partition.isClosed else { return }
        if partition.queue.count >= policy.maxBufferedEventsPerPartition {
            partition.droppedEventCount += 1
            switch policy.overflowPolicy {
            case .dropOldest:
                _ = partition.queue.popFirst()
            case .dropNewest:
                partitions[taskID] = partition
                reportPartitionMetric(for: taskID, partition: partition)
                return
            }
        }
        partition.queue.append(PendingEvent(event: event, enqueuedAt: .now))
        partitions[taskID] = partition
        reportPartitionMetric(for: taskID, partition: partition)
        startDrainIfNeeded(taskID: taskID)
    }

    package func finish(taskID: String) async {
        guard var partition = partitions[taskID] else { return }
        partition.isClosed = true
        partitions[taskID] = partition
        await cleanupPartitionIfPossible(taskID: taskID)
    }

    private func removeContinuation(taskID: String, continuationID: UUID) async {
        guard var partition = partitions[taskID] else { return }
        partition.streamConsumers.removeValue(forKey: continuationID)
        partitions[taskID] = partition
        updateStreamMetricsReconciliationTaskState()
        await cleanupPartitionIfPossible(taskID: taskID)
    }

    private func startDrainIfNeeded(taskID: String) {
        guard var partition = partitions[taskID], !partition.isDraining else { return }
        partition.isDraining = true
        partitions[taskID] = partition
        Task {
            await drain(taskID: taskID)
        }
    }

    private func drain(taskID: String) async {
        while let pendingEvent = popNextEvent(taskID: taskID) {
            guard var partition = partitions[taskID] else { break }

            for (consumerID, var streamConsumer) in partition.streamConsumers {
                let result = streamConsumer.continuation.yield(pendingEvent.event)
                switch result {
                case .terminated:
                    partition.streamConsumers.removeValue(forKey: consumerID)
                default:
                    streamConsumer.recordYieldResult(
                        result,
                        enqueuedAt: pendingEvent.enqueuedAt,
                        maxBufferedEvents: policy.maxBufferedEventsPerConsumer
                    )
                    partition.streamConsumers[consumerID] = streamConsumer
                    reportStreamConsumerMetric(for: taskID, consumer: streamConsumer)
                }
            }

            partitions[taskID] = partition
            updateStreamMetricsReconciliationTaskState()
            let listeners = Array(partition.listeners.values)
            for listener in listeners {
                await listener.enqueue(pendingEvent.event, enqueuedAt: pendingEvent.enqueuedAt)
            }
        }

        guard var partition = partitions[taskID] else { return }
        partition.isDraining = false
        partitions[taskID] = partition

        if !partition.queue.isEmpty {
            startDrainIfNeeded(taskID: taskID)
            return
        }

        await cleanupPartitionIfPossible(taskID: taskID)
    }

    private func popNextEvent(taskID: String) -> PendingEvent? {
        guard var partition = partitions[taskID] else { return nil }
        let event = partition.queue.popFirst()
        partitions[taskID] = partition
        reportPartitionMetric(for: taskID, partition: partition)
        return event
    }

    private func cleanupPartitionIfPossible(taskID: String) async {
        guard let partition = partitions[taskID] else { return }
        guard partition.isClosed, !partition.isDraining, partition.queue.isEmpty else { return }

        partitions.removeValue(forKey: taskID)
        updateStreamMetricsReconciliationTaskState()

        for consumer in partition.streamConsumers.values {
            consumer.continuation.finish()
        }

        for listener in partition.listeners.values {
            await listener.finish()
        }
    }

    private func reportPartitionMetric(for taskID: String, partition: PartitionState) {
        metricsReporter?.report(
            .partitionState(
                EventPipelinePartitionStateMetric(
                    partitionID: taskID,
                    queueDepth: partition.queue.count,
                    droppedEventCount: partition.droppedEventCount,
                    oldestQueuedEventAge: partition.queue.first.map { Date.now.timeIntervalSince($0.enqueuedAt) }
                )
            )
        )
    }

    private func reportStreamConsumerMetric(for taskID: String, consumer: StreamConsumerState) {
        metricsReporter?.report(
            .consumerState(
                EventPipelineConsumerStateMetric(
                    partitionID: taskID,
                    consumerID: consumer.consumerID,
                    queueDepth: consumer.queueDepth,
                    droppedEventCount: consumer.droppedEventCount,
                    oldestQueuedEventAge: consumer.oldestQueuedEventAge
                )
            )
        )
    }

    private func updateStreamMetricsReconciliationTaskState() {
        guard metricsReporter != nil, let metricsSnapshotInterval else {
            streamMetricsReconciliationTask?.cancel()
            streamMetricsReconciliationTask = nil
            return
        }

        guard hasActiveStreamConsumers else {
            streamMetricsReconciliationTask?.cancel()
            streamMetricsReconciliationTask = nil
            return
        }

        guard streamMetricsReconciliationTask == nil else { return }

        streamMetricsReconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: metricsSnapshotInterval)
                } catch {
                    return
                }

                guard let self else { return }
                await self.reconcileStreamConsumerMetrics()
            }
        }
    }

    private var hasActiveStreamConsumers: Bool {
        partitions.values.contains { !$0.streamConsumers.isEmpty }
    }

    private func reconcileStreamConsumerMetrics() {
        guard metricsReporter != nil, hasActiveStreamConsumers else {
            streamMetricsReconciliationTask?.cancel()
            streamMetricsReconciliationTask = nil
            return
        }

        for (taskID, partition) in partitions {
            for consumer in partition.streamConsumers.values {
                reportStreamConsumerMetric(for: taskID, consumer: consumer)
            }
        }
    }
}
