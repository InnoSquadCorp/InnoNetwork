import Foundation


package actor EventDeliveryChain<Event: Sendable> {
    package typealias Handler = @Sendable (Event) async -> Void

    private final class DeliveryCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()

            continuation?.resume()
        }
    }

    private struct QueuedEvent: Sendable {
        let event: Event
        let enqueuedAt: Date
        let completion: DeliveryCompletion?
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
        enqueue(event, enqueuedAt: enqueuedAt, completion: nil)
    }

    package func enqueueAndWaitForDelivery(_ event: Event, enqueuedAt: Date = .now) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                enqueuedAt: enqueuedAt,
                completion: DeliveryCompletion(continuation)
            )
        }
    }

    private func enqueue(
        _ event: Event,
        enqueuedAt: Date,
        completion: DeliveryCompletion?
    ) {
        guard !isClosed else {
            completion?.resume()
            return
        }
        if queue.count >= policy.maxBufferedEventsPerConsumer {
            droppedEventCount += 1
            switch policy.overflowPolicy {
            case .dropOldest:
                queue.popFirst()?.completion?.resume()
            case .dropNewest:
                reportQueueState()
                completion?.resume()
                return
            }
        }

        queue.append(QueuedEvent(event: event, enqueuedAt: enqueuedAt, completion: completion))
        reportQueueState()
        startDrainIfNeeded()
    }

    package func finish() async {
        isClosed = true
        while let queuedEvent = queue.popFirst() {
            queuedEvent.completion?.resume()
        }
        guard let drainTask else { return }
        self.drainTask = nil
        drainTask.cancel()
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
            queuedEvent.completion?.resume()
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
