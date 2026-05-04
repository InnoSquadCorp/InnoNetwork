import Foundation
import os

package actor EventDeliveryChain<Event: Sendable> {
    package typealias Handler = @Sendable (Event) async -> Void

    private final class DeliveryCompletion: Sendable {
        private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = OSAllocatedUnfairLock(initialState: continuation)
        }

        func resume() {
            let continuation = continuation.withLock { state in
                let continuation = state
                state = nil
                return continuation
            }

            continuation?.resume()
        }
    }

    private struct QueuedEvent: Sendable {
        let event: Event
        let enqueuedAt: Date
        let handlerStartCompletion: DeliveryCompletion?
        let deliveryCompletion: DeliveryCompletion?
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
        enqueue(
            event,
            enqueuedAt: enqueuedAt,
            handlerStartCompletion: nil,
            deliveryCompletion: nil
        )
    }

    package func enqueueAndWaitForHandlerStart(_ event: Event, enqueuedAt: Date = .now) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                enqueuedAt: enqueuedAt,
                handlerStartCompletion: DeliveryCompletion(continuation),
                deliveryCompletion: nil
            )
        }
    }

    package func enqueueAndWaitForDelivery(_ event: Event, enqueuedAt: Date = .now) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                enqueuedAt: enqueuedAt,
                handlerStartCompletion: nil,
                deliveryCompletion: DeliveryCompletion(continuation)
            )
        }
    }

    private func enqueue(
        _ event: Event,
        enqueuedAt: Date,
        handlerStartCompletion: DeliveryCompletion?,
        deliveryCompletion: DeliveryCompletion?
    ) {
        guard !isClosed else {
            handlerStartCompletion?.resume()
            deliveryCompletion?.resume()
            return
        }
        if queue.count >= policy.maxBufferedEventsPerConsumer {
            droppedEventCount += 1
            switch policy.overflowPolicy {
            case .dropOldest:
                if let droppedEvent = queue.popFirst() {
                    droppedEvent.handlerStartCompletion?.resume()
                    droppedEvent.deliveryCompletion?.resume()
                }
            case .dropNewest:
                reportQueueState()
                handlerStartCompletion?.resume()
                deliveryCompletion?.resume()
                return
            }
        }

        queue.append(
            QueuedEvent(
                event: event,
                enqueuedAt: enqueuedAt,
                handlerStartCompletion: handlerStartCompletion,
                deliveryCompletion: deliveryCompletion
            )
        )
        reportQueueState()
        startDrainIfNeeded()
    }

    package func finish() async {
        isClosed = true
        while let queuedEvent = queue.popFirst() {
            queuedEvent.handlerStartCompletion?.resume()
            queuedEvent.deliveryCompletion?.resume()
        }
        // `finish()` can be called by the active handler while self-removing;
        // leave the drain task alive so in-flight delivery is not cancelled.
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
            queuedEvent.handlerStartCompletion?.resume()
            await handler(queuedEvent.event)
            reportDeliveryLatency(Date.now.timeIntervalSince(queuedEvent.enqueuedAt))
            queuedEvent.deliveryCompletion?.resume()
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
