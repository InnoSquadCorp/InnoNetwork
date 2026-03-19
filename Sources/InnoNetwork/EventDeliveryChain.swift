import Foundation


package actor EventDeliveryChain<Event: Sendable> {
    package typealias Handler = @Sendable (Event) async -> Void

    private struct QueuedEvent: Sendable {
        let event: Event
        let enqueuedAt: Date
    }

    private let handler: Handler
    private let partitionID: String
    private let consumerID: String
    private let policy: EventDeliveryPolicy
    private let metricsReporter: (any EventPipelineMetricsReporting)?
    private var queue = FIFOBuffer<QueuedEvent>()
    private var drainTask: Task<Void, Never>?
    private var isClosed = false
    private var droppedEventCount = 0

    package init(
        partitionID: String,
        consumerID: String,
        policy: EventDeliveryPolicy,
        metricsReporter: (any EventPipelineMetricsReporting)?,
        handler: @escaping Handler
    ) {
        self.partitionID = partitionID
        self.consumerID = consumerID
        self.policy = policy
        self.metricsReporter = metricsReporter
        self.handler = handler
    }

    package func enqueue(_ event: Event, enqueuedAt: Date = .now) {
        guard !isClosed else { return }
        if queue.count >= policy.maxBufferedEventsPerConsumer {
            droppedEventCount += 1
            switch policy.overflowPolicy {
            case .dropOldest:
                _ = queue.popFirst()
            case .dropNewest:
                reportQueueState()
                return
            }
        }

        queue.append(QueuedEvent(event: event, enqueuedAt: enqueuedAt))
        reportQueueState()
        startDrainIfNeeded()
    }

    package func finish() async {
        isClosed = true
        queue.removeAll()
        guard let drainTask else { return }
        self.drainTask = nil
        drainTask.cancel()
        await drainTask.value
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task {
            await drainLoop()
        }
    }

    private func drainLoop() async {
        while !Task.isCancelled {
            guard let queuedEvent = queue.popFirst() else { break }
            reportQueueState()
            await handler(queuedEvent.event)
            reportDeliveryLatency(Date.now.timeIntervalSince(queuedEvent.enqueuedAt))
        }

        drainTask = nil
        if !isClosed && !queue.isEmpty {
            startDrainIfNeeded()
        }
    }

    private func reportQueueState() {
        metricsReporter?.report(
            .consumerState(
                EventPipelineConsumerStateMetric(
                    partitionID: partitionID,
                    consumerID: consumerID,
                    queueDepth: queue.count,
                    droppedEventCount: droppedEventCount,
                    oldestQueuedEventAge: queue.first.map { Date.now.timeIntervalSince($0.enqueuedAt) }
                )
            )
        )
    }

    private func reportDeliveryLatency(_ latency: TimeInterval) {
        metricsReporter?.report(
            .consumerDeliveryLatency(
                EventPipelineConsumerDeliveryLatencyMetric(
                    partitionID: partitionID,
                    consumerID: consumerID,
                    latency: latency
                )
            )
        )
    }
}
