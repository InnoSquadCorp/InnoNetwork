import Foundation
import os

extension TaskEventHub {
    /// Demand-driven buffer used by `AsyncStream(unfolding:)`. Keeping the
    /// bounded queue here avoids the double-buffering of a continuation-based
    /// stream, where the hub could drain into Foundation's hidden buffer and
    /// lose control of both overflow policy and guaranteed terminal admission.
    final class StreamMailbox: Sendable {
        private struct Item: Sendable {
            let event: Event
            let enqueuedAt: Date
        }

        struct Snapshot: Sendable {
            let queueDepth: Int
            let waiterCount: Int
            let droppedEventCount: Int
            let oldestQueuedEventAge: TimeInterval?
        }

        enum EnqueueResult: Sendable {
            case accepted
            case dropped
            case terminated
        }

        private struct Waiter: Sendable {
            let id: UUID
            let continuation: CheckedContinuation<Event?, Never>
        }

        private struct State: Sendable {
            var queue = FIFOBuffer<Item>()
            var waiters: [Waiter] = []
            var droppedEventCount = 0
            var isFinished = false
        }

        private enum NextAction {
            case waiting
            case resume(CheckedContinuation<Event?, Never>, Event?)
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let clock: any InnoNetworkClock

        init(clock: any InnoNetworkClock = SystemClock()) {
            self.clock = clock
        }

        func enqueue(
            _ event: Event,
            enqueuedAt: Date,
            maxBufferedEvents: Int,
            overflowPolicy: EventPipelineOverflowPolicy,
            guaranteesAdmission: Bool
        ) -> EnqueueResult {
            let action = state.withLock { state -> (CheckedContinuation<Event?, Never>?, EnqueueResult) in
                guard !state.isFinished else { return (nil, .terminated) }
                if !state.waiters.isEmpty {
                    let waiter = state.waiters.removeFirst()
                    return (waiter.continuation, .accepted)
                }

                if state.queue.count >= maxBufferedEvents {
                    state.droppedEventCount += 1
                    if guaranteesAdmission || overflowPolicy == .dropOldest {
                        _ = state.queue.popFirst()
                    } else {
                        return (nil, .dropped)
                    }
                }
                state.queue.append(Item(event: event, enqueuedAt: enqueuedAt))
                return (nil, .accepted)
            }
            action.0?.resume(returning: event)
            return action.1
        }

        func next() async -> Event? {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let wasAlreadyCancelled = Task.isCancelled
                    let action = state.withLock { state -> NextAction in
                        if let item = state.queue.popFirst() {
                            return .resume(continuation, item.event)
                        }
                        if state.isFinished || wasAlreadyCancelled {
                            return .resume(continuation, nil)
                        }
                        state.waiters.append(
                            Waiter(id: waiterID, continuation: continuation)
                        )
                        return .waiting
                    }
                    if case .resume(let continuation, let event) = action {
                        continuation.resume(returning: event)
                    }

                    // Cancellation can run after the initial task-state read
                    // but before this waiter is installed. Re-check after the
                    // registration so that race cannot strand a continuation.
                    if Task.isCancelled {
                        cancelWaiter(id: waiterID)
                    }
                }
            } onCancel: {
                cancelWaiter(id: waiterID)
            }
        }

        func finish() {
            let waiters = state.withLock { state -> [CheckedContinuation<Event?, Never>] in
                state.isFinished = true
                let waiters = state.waiters.map(\.continuation)
                state.waiters.removeAll(keepingCapacity: false)
                return waiters
            }
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }

        func cancel() {
            let waiters = state.withLock { state -> [CheckedContinuation<Event?, Never>] in
                state.isFinished = true
                state.queue.removeAll()
                let waiters = state.waiters.map(\.continuation)
                state.waiters.removeAll(keepingCapacity: false)
                return waiters
            }
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }

        func snapshot() -> Snapshot {
            state.withLock { state in
                Snapshot(
                    queueDepth: state.queue.count,
                    waiterCount: state.waiters.count,
                    droppedEventCount: state.droppedEventCount,
                    oldestQueuedEventAge: state.queue.first.map {
                        clock.now().timeIntervalSince($0.enqueuedAt)
                    }
                )
            }
        }

        private func cancelWaiter(id: UUID) {
            let continuation = state.withLock { state -> CheckedContinuation<Event?, Never>? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.waiters.remove(at: index).continuation
            }
            continuation?.resume(returning: nil)
        }
    }

    final class StreamRemovalToken: Sendable {
        private let didRemove = OSAllocatedUnfairLock(initialState: false)
        private let operation: @Sendable () -> Void

        init(operation: @escaping @Sendable () -> Void) {
            self.operation = operation
        }

        func remove() {
            let shouldRemove = didRemove.withLock { removed in
                guard !removed else { return false }
                removed = true
                return true
            }
            if shouldRemove { operation() }
        }

        deinit {
            remove()
        }
    }

    final class DeliveryCompletion: Sendable {
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

    final class PartitionRetirementBarrier: Sendable {
        private struct State: Sendable {
            var isComplete = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func wait() async {
            await withCheckedContinuation { continuation in
                let isAlreadyComplete = state.withLock { state in
                    guard !state.isComplete else { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if isAlreadyComplete {
                    continuation.resume()
                }
            }
        }

        func complete() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                guard !state.isComplete else { return [] }
                state.isComplete = true
                let waiters = state.waiters
                state.waiters.removeAll(keepingCapacity: false)
                return waiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    struct PendingEvent: Sendable {
        let event: Event
        let enqueuedAt: Date
        let listenerIDs: [UUID]
        let streamConsumerIDs: [UUID]
        let completion: DeliveryCompletion?
        let completionMode: CompletionMode
        let guaranteesAdmission: Bool
    }

    enum CompletionMode: Sendable {
        case none
        case listenerEnqueue
        case listenerDelivery
    }

    struct StreamConsumerState {
        let consumerID: String
        let mailbox: StreamMailbox

        init(id: UUID, mailbox: StreamMailbox) {
            self.consumerID = "stream-\(id.uuidString)"
            self.mailbox = mailbox
        }

        func makeMetric(partitionID: String) -> EventPipelineConsumerStateMetric {
            let snapshot = mailbox.snapshot()
            return EventPipelineConsumerStateMetric(
                partitionID: partitionID,
                consumerID: consumerID,
                queueDepth: snapshot.queueDepth,
                droppedEventCount: snapshot.droppedEventCount,
                oldestQueuedEventAge: snapshot.oldestQueuedEventAge
            )
        }

        func makeTerminalMetric(partitionID: String) -> EventPipelineConsumerStateMetric {
            let snapshot = mailbox.snapshot()
            return EventPipelineConsumerStateMetric(
                partitionID: partitionID,
                consumerID: consumerID,
                queueDepth: 0,
                droppedEventCount: snapshot.droppedEventCount,
                oldestQueuedEventAge: nil
            )
        }
    }

    struct PartitionState {
        let generation = UUID()
        var listeners: [UUID: EventDeliveryChain<Event>] = [:]
        var streamConsumers: [UUID: StreamConsumerState] = [:]
        var queue = FIFOBuffer<PendingEvent>()
        var isDraining = false
        var isClosed = false
        var droppedEventCount = 0
    }

    struct PartitionKey: Hashable {
        let taskID: String
        let generation: UUID

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.taskID == rhs.taskID && lhs.generation == rhs.generation
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(taskID)
            hasher.combine(generation)
        }
    }
}
