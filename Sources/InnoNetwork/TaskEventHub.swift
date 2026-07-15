import Foundation
import os

package actor TaskEventHub<Event: Sendable> {
    package typealias Listener = @Sendable (Event) async -> Void

    /// Demand-driven buffer used by `AsyncStream(unfolding:)`. Keeping the
    /// bounded queue here avoids the double-buffering of a continuation-based
    /// stream, where the hub could drain into Foundation's hidden buffer and
    /// lose control of both overflow policy and guaranteed terminal admission.
    private final class StreamMailbox: Sendable {
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
                        Date.now.timeIntervalSince($0.enqueuedAt)
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

    private final class StreamRemovalToken: Sendable {
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

    private final class PartitionRetirementBarrier: Sendable {
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

    private struct PendingEvent: Sendable {
        let event: Event
        let enqueuedAt: Date
        let listenerIDs: [UUID]
        let streamConsumerIDs: [UUID]
        let completion: DeliveryCompletion?
        let completionMode: CompletionMode
        let guaranteesAdmission: Bool
    }

    private enum CompletionMode: Sendable {
        case none
        case listenerEnqueue
        case listenerDelivery
    }

    private struct StreamConsumerState {
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

    private struct PartitionState {
        let generation = UUID()
        var listeners: [UUID: EventDeliveryChain<Event>] = [:]
        var streamConsumers: [UUID: StreamConsumerState] = [:]
        var queue = FIFOBuffer<PendingEvent>()
        var isDraining = false
        var isClosed = false
        var droppedEventCount = 0
    }

    private struct PartitionKey: Hashable {
        let taskID: String
        let generation: UUID
    }

    private var partitions: [String: PartitionState] = [:]
    /// Waiters used by lifecycle owners that must not finish retirement until
    /// a closed partition has been fully detached. Listener handlers are still
    /// allowed to drain asynchronously after detachment.
    private var partitionRetirementBarriers: [PartitionKey: PartitionRetirementBarrier] = [:]
    private let policy: EventDeliveryPolicy
    private let metricsProxy: EventPipelineMetricsReporterProxy?
    private let metricsSnapshotInterval: Duration?
    private let partitionRetirementHook: (@Sendable (String, UUID) async -> Void)?
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
        self.partitionRetirementHook = nil
    }

    package init(
        policy: EventDeliveryPolicy = .default,
        metricsReporter: (any EventPipelineMetricsReporting)? = nil,
        hubKind: EventPipelineHubKind = .genericTask,
        metricsSnapshotInterval: Duration = .seconds(30),
        partitionRetirementHook: @escaping @Sendable (String, UUID) async -> Void
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
        self.partitionRetirementHook = partitionRetirementHook
    }

    deinit {
        streamMetricsReconciliationTask?.cancel()
        metricsProxy?.shutdown()
    }

    package func addListener(taskID: String, listener: @escaping Listener) async -> UUID {
        await waitForClosedPartitionRetirement(taskID: taskID)
        let listenerID = UUID()
        var partition = partition(for: taskID)
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

    package func streamConsumerCount(taskID: String) -> Int {
        partitions[taskID]?.streamConsumers.count ?? 0
    }

    /// Deterministic observation used by concurrency tests to wait until
    /// `AsyncStream(unfolding:)` calls have actually suspended in their
    /// mailboxes. This stays package-scoped and does not affect consumer API.
    package func streamWaiterCount(taskID: String) -> Int {
        partitions[taskID]?.streamConsumers.values.reduce(into: 0) { count, consumer in
            count += consumer.mailbox.snapshot().waiterCount
        } ?? 0
    }

    package func stream(for taskID: String) async -> AsyncStream<Event> {
        await waitForClosedPartitionRetirement(taskID: taskID)
        let continuationID = UUID()
        let mailbox = StreamMailbox()
        let removalToken = StreamRemovalToken { [weak self, mailbox] in
            // `AsyncStream(unfolding:)` cannot forcibly unwind a producer that
            // is suspended in a checked continuation. End the mailbox first so
            // cancellation never depends on this actor still being alive or
            // available to process the bookkeeping hop below.
            mailbox.cancel()
            guard let self else { return }
            Task.detached { [self] in
                await self.removeContinuation(taskID: taskID, continuationID: continuationID)
            }
        }
        var partition = partition(for: taskID)
        partition.streamConsumers[continuationID] = StreamConsumerState(
            id: continuationID,
            mailbox: mailbox
        )
        partitions[taskID] = partition
        updateStreamMetricsReconciliationTaskState()
        return AsyncStream(
            unfolding: {
                _ = removalToken
                return await mailbox.next()
            },
            onCancel: {
                removalToken.remove()
            }
        )
    }

    /// A terminal publisher may have sealed a partition while its final
    /// event is still draining. New consumers must join the next partition,
    /// not the closed predecessor whose enqueue guard would discard replay.
    private func waitForClosedPartitionRetirement(taskID: String) async {
        while let partition = partitions[taskID], partition.isClosed {
            let barrier = retirementBarrier(taskID: taskID, partition: partition)
            await barrier.wait()
        }
    }

    package func publish(_ event: Event, for taskID: String) {
        enqueue(
            event,
            for: taskID,
            completion: nil,
            completionMode: .none,
            guaranteesAdmission: false
        )
    }

    /// Validates a producer epoch before admitting a nonterminal event.
    /// Validation suspends this actor, allowing an already-started terminal
    /// publisher to seal the partition first. Once validation succeeds, the
    /// enqueue happens in the same actor turn, so terminal ordering is total.
    @discardableResult
    package func publishIfCurrent(
        _ event: Event,
        for taskID: String,
        validate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        guard await validate() else { return false }
        guard partitions[taskID]?.isClosed != true else { return false }
        enqueue(
            event,
            for: taskID,
            completion: nil,
            completionMode: .none,
            guaranteesAdmission: false
        )
        return true
    }

    package func publishAndWaitForEnqueue(_ event: Event, for taskID: String) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                for: taskID,
                completion: DeliveryCompletion(continuation),
                completionMode: .listenerEnqueue,
                guaranteesAdmission: false
            )
        }
    }

    /// Admits the final terminal outcome even when `.dropNewest` queues are
    /// saturated, then waits until it has reached every currently registered
    /// consumer's queue. Delivery remains asynchronous under each consumer's
    /// policy. Earlier notifications in a multi-event terminal burst retain
    /// the configured bounded overflow behavior.
    package func publishTerminalAndWaitForEnqueue(_ event: Event, for taskID: String) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                for: taskID,
                completion: DeliveryCompletion(continuation),
                completionMode: .listenerEnqueue,
                guaranteesAdmission: true
            )
        }
    }

    /// Admits the final terminal outcome and atomically seals its partition.
    ///
    /// Sealing in the same actor turn prevents a late nonterminal publisher
    /// from displacing the guaranteed event in a `.dropOldest` listener queue
    /// or an `AsyncStream.bufferingNewest` buffer. Events already admitted
    /// ahead of the terminal outcome retain their configured overflow policy.
    package func publishTerminalAndFinish(_ event: Event, for taskID: String) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                for: taskID,
                completion: DeliveryCompletion(continuation),
                completionMode: .listenerEnqueue,
                guaranteesAdmission: true
            )
            if var partition = partitions[taskID] {
                partition.isClosed = true
                partitions[taskID] = partition
            }
        }
    }

    package func publishAndWaitForDelivery(_ event: Event, for taskID: String) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                for: taskID,
                completion: DeliveryCompletion(continuation),
                completionMode: .listenerDelivery,
                guaranteesAdmission: false
            )
        }
    }

    private func enqueue(
        _ event: Event,
        for taskID: String,
        completion: DeliveryCompletion?,
        completionMode: CompletionMode,
        guaranteesAdmission: Bool
    ) {
        var partition = partition(for: taskID)
        guard !partition.isClosed else {
            completion?.resume()
            return
        }
        if partition.queue.count >= policy.maxBufferedEventsPerPartition {
            partition.droppedEventCount += 1
            if guaranteesAdmission {
                partition.queue.popFirst()?.completion?.resume()
            } else {
                switch policy.overflowPolicy {
                case .dropOldest:
                    partition.queue.popFirst()?.completion?.resume()
                case .dropNewest:
                    partitions[taskID] = partition
                    reportPartitionMetric(for: taskID, partition: partition)
                    completion?.resume()
                    return
                }
            }
        }
        partition.queue.append(
            PendingEvent(
                event: event,
                enqueuedAt: .now,
                listenerIDs: Array(partition.listeners.keys),
                streamConsumerIDs: Array(partition.streamConsumers.keys),
                completion: completion,
                completionMode: completionMode,
                guaranteesAdmission: guaranteesAdmission
            )
        )
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

    /// Closes a partition and waits until the hub has detached it.
    ///
    /// This stronger boundary is intended for task lifecycles that must retire
    /// their event partition before a successor can be registered. It waits
    /// for the partition-level queue to drain, but not for user listener
    /// handlers: their delivery chains retain the asynchronous semantics
    /// established by ``finish(taskID:)``.
    package func finishAndWaitForClosure(taskID: String) async {
        guard var partition = partitions[taskID] else { return }
        let retirementBarrier = retirementBarrier(taskID: taskID, partition: partition)
        partition.isClosed = true
        partitions[taskID] = partition
        await cleanupPartitionIfPossible(taskID: taskID)
        await retirementBarrier.wait()
    }

    private func removeContinuation(taskID: String, continuationID: UUID) async {
        guard var partition = partitions[taskID] else { return }
        let removedConsumer = removeStreamConsumer(
            continuationID: continuationID,
            from: &partition
        )
        partitions[taskID] = partition
        if let removedConsumer {
            removedConsumer.mailbox.cancel()
            await reportStreamConsumerRemoval(for: taskID, consumer: removedConsumer)
            updateStreamMetricsReconciliationTaskState()
        }
        await cleanupPartitionIfPossible(taskID: taskID)
    }

    private func startDrainIfNeeded(taskID: String) {
        guard var partition = partitions[taskID], !partition.isDraining else { return }
        partition.isDraining = true
        partitions[taskID] = partition
        Task.detached { [self] in
            await drain(taskID: taskID)
        }
    }

    private func drain(taskID: String) async {
        while let pendingEvent = popNextEvent(taskID: taskID) {
            guard var partition = partitions[taskID] else {
                pendingEvent.completion?.resume()
                break
            }
            var removedConsumers: [StreamConsumerState] = []

            for consumerID in pendingEvent.streamConsumerIDs {
                guard let streamConsumer = partition.streamConsumers[consumerID] else {
                    continue
                }
                let result = streamConsumer.mailbox.enqueue(
                    pendingEvent.event,
                    enqueuedAt: pendingEvent.enqueuedAt,
                    maxBufferedEvents: policy.maxBufferedEventsPerConsumer,
                    overflowPolicy: policy.overflowPolicy,
                    guaranteesAdmission: pendingEvent.guaranteesAdmission
                )
                switch result {
                case .terminated:
                    if let removedConsumer = removeStreamConsumer(
                        continuationID: consumerID,
                        from: &partition
                    ) {
                        removedConsumers.append(removedConsumer)
                    }
                case .accepted, .dropped:
                    reportStreamConsumerMetric(for: taskID, consumer: streamConsumer)
                }
            }

            partitions[taskID] = partition
            if !removedConsumers.isEmpty {
                for removedConsumer in removedConsumers {
                    await reportStreamConsumerRemoval(for: taskID, consumer: removedConsumer)
                }
                updateStreamMetricsReconciliationTaskState()
            }
            let listeners = pendingEvent.listenerIDs.compactMap { partition.listeners[$0] }
            switch pendingEvent.completionMode {
            case .none:
                for listener in listeners {
                    if pendingEvent.guaranteesAdmission {
                        await listener.enqueueGuaranteed(
                            pendingEvent.event,
                            enqueuedAt: pendingEvent.enqueuedAt
                        )
                    } else {
                        await listener.enqueue(pendingEvent.event, enqueuedAt: pendingEvent.enqueuedAt)
                    }
                }
            case .listenerEnqueue:
                for listener in listeners {
                    if pendingEvent.guaranteesAdmission {
                        await listener.enqueueGuaranteed(
                            pendingEvent.event,
                            enqueuedAt: pendingEvent.enqueuedAt
                        )
                    } else {
                        await listener.enqueue(pendingEvent.event, enqueuedAt: pendingEvent.enqueuedAt)
                    }
                }
                pendingEvent.completion?.resume()
            case .listenerDelivery:
                await deliverAndWait(
                    event: pendingEvent.event,
                    enqueuedAt: pendingEvent.enqueuedAt,
                    to: listeners
                )
                pendingEvent.completion?.resume()
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

    private func deliverAndWait(
        event: Event,
        enqueuedAt: Date,
        to listeners: [EventDeliveryChain<Event>]
    ) async {
        guard !listeners.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for listener in listeners {
                group.addTask {
                    await listener.enqueueAndWaitForDelivery(event, enqueuedAt: enqueuedAt)
                }
            }

            await group.waitForAll()
        }
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

        let key = PartitionKey(taskID: taskID, generation: partition.generation)
        let retirementBarrier = partitionRetirementBarriers[key]
        partitions.removeValue(forKey: taskID)
        await partitionRetirementHook?(taskID, partition.generation)

        for consumer in partition.streamConsumers.values {
            await reportStreamConsumerRemoval(for: taskID, consumer: consumer)
        }
        updateStreamMetricsReconciliationTaskState()

        for consumer in partition.streamConsumers.values {
            consumer.mailbox.finish()
        }

        for listener in partition.listeners.values {
            await listener.finish(deliverQueuedEvents: true)
        }

        retirementBarrier?.complete()
        partitionRetirementBarriers.removeValue(forKey: key)
    }

    private func partition(for taskID: String) -> PartitionState {
        partitions[taskID] ?? PartitionState()
    }

    private func retirementBarrier(
        taskID: String,
        partition: PartitionState
    ) -> PartitionRetirementBarrier {
        let key = PartitionKey(taskID: taskID, generation: partition.generation)
        if let barrier = partitionRetirementBarriers[key] {
            return barrier
        }
        let barrier = PartitionRetirementBarrier()
        partitionRetirementBarriers[key] = barrier
        return barrier
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
        metricsReporter?.report(.consumerState(consumer.makeMetric(partitionID: taskID)))
    }

    private func reportStreamConsumerRemoval(for taskID: String, consumer: StreamConsumerState) async {
        if let metricsProxy {
            await metricsProxy.reportTerminalConsumerState(
                consumer.makeTerminalMetric(partitionID: taskID)
            )
        }
    }

    private func removeStreamConsumer(
        continuationID: UUID,
        from partition: inout PartitionState
    ) -> StreamConsumerState? {
        return partition.streamConsumers.removeValue(forKey: continuationID)
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
            updateStreamMetricsReconciliationTaskState()
            return
        }

        for (taskID, partition) in partitions {
            for consumer in partition.streamConsumers.values {
                reportStreamConsumerMetric(for: taskID, consumer: consumer)
            }
        }
    }
}
