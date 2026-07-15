import Foundation
import InnoNetwork
import os

/// Single-consumer bridge from synchronous URLSession delegate callbacks to
/// the actor-isolated download lifecycle.
///
/// Completion events are always retained in FIFO order. Progress callbacks
/// are coalesced per URL task while they occupy the same pending segment, so a
/// slow consumer uses at most one progress payload per active segment rather
/// than one allocation per delegate callback. A completion closes the current
/// segment; any later progress for the same identifier is queued after that
/// completion and therefore cannot be reordered ahead of it.
final class DownloadDelegateEventChannel: Sendable {
    typealias Event = DownloadManager.DelegateEvent

    private struct ProgressPayload: Sendable {
        let taskIdentifier: Int
        var bytesWritten: Int64
        var totalBytesWritten: Int64
        var totalBytesExpectedToWrite: Int64

        mutating func merge(
            bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            self.bytesWritten = Self.saturatingAdd(self.bytesWritten, bytesWritten)
            self.totalBytesWritten = totalBytesWritten
            self.totalBytesExpectedToWrite = totalBytesExpectedToWrite
        }

        var event: Event {
            .progress(
                taskIdentifier: taskIdentifier,
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }

        private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
            guard overflowed else { return sum }
            return rhs >= 0 ? .max : .min
        }
    }

    private enum QueuedEvent: Sendable {
        case progress(taskIdentifier: Int, segmentID: UInt64)
        case lossless(Event)
    }

    private struct State: Sendable {
        var queue: [QueuedEvent] = []
        var queueHeadIndex = 0
        var progressBySegment: [UInt64: ProgressPayload] = [:]
        var activeProgressSegmentByTask: [Int: UInt64] = [:]
        var nextSegmentID: UInt64 = 0
        var waiter: CheckedContinuation<Event?, Never>?
        var isFinished = false

        var isQueueEmpty: Bool {
            queueHeadIndex >= queue.count
        }

        var queuedEventCount: Int {
            queue.count - queueHeadIndex
        }

        mutating func append(_ event: QueuedEvent) {
            queue.append(event)
        }

        mutating func popFirst() -> QueuedEvent? {
            guard queueHeadIndex < queue.count else { return nil }
            let event = queue[queueHeadIndex]
            queueHeadIndex += 1
            if queueHeadIndex > 32, queueHeadIndex * 2 >= queue.count {
                queue.removeFirst(queueHeadIndex)
                queueHeadIndex = 0
            }
            return event
        }

        mutating func allocateSegmentID() -> UInt64 {
            let firstCandidate = nextSegmentID
            repeat {
                let candidate = nextSegmentID
                nextSegmentID &+= 1
                if progressBySegment[candidate] == nil {
                    return candidate
                }
            } while nextSegmentID != firstCandidate

            preconditionFailure("Download progress segment identifier space exhausted")
        }
    }

    private enum CompletionSendAction: Sendable {
        case queued
        case resume(CheckedContinuation<Event?, Never>)
        case rejected
    }

    private enum NextAction: Sendable {
        case waiting
        case resume(Event?)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func sendProgress(
        taskIdentifier: Int,
        bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let event = Event.progress(
            taskIdentifier: taskIdentifier,
            bytesWritten: bytesWritten,
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )

        let waiter = state.withLock { state -> CheckedContinuation<Event?, Never>? in
            guard !state.isFinished else { return nil }

            if let pendingWaiter = state.waiter {
                state.waiter = nil
                return pendingWaiter
            }

            if let segmentID = state.activeProgressSegmentByTask[taskIdentifier] {
                state.progressBySegment[segmentID]?.merge(
                    bytesWritten: bytesWritten,
                    totalBytesWritten: totalBytesWritten,
                    totalBytesExpectedToWrite: totalBytesExpectedToWrite
                )
                return nil
            }

            let segmentID = state.allocateSegmentID()
            state.activeProgressSegmentByTask[taskIdentifier] = segmentID
            state.progressBySegment[segmentID] = ProgressPayload(
                taskIdentifier: taskIdentifier,
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
            state.append(
                .progress(taskIdentifier: taskIdentifier, segmentID: segmentID)
            )
            return nil
        }

        waiter?.resume(returning: event)
    }

    func sendCompletion(
        taskIdentifier: Int,
        taskDescription: String? = nil,
        originalRequestURL: URL? = nil,
        currentRequestURL: URL? = nil,
        payload: DownloadCompletionPayload?,
        error: SendableUnderlyingError?
    ) {
        let event = Event.completion(
            taskIdentifier: taskIdentifier,
            taskDescription: taskDescription,
            originalRequestURL: originalRequestURL,
            currentRequestURL: currentRequestURL,
            payload: payload,
            error: error
        )
        sendLossless(event)
    }

    /// Package-test compatibility path. URLSession production callbacks use
    /// the typed journal payload overload above.
    func sendCompletion(
        taskIdentifier: Int,
        taskDescription: String? = nil,
        originalRequestURL: URL? = nil,
        currentRequestURL: URL? = nil,
        location: URL?,
        error: SendableUnderlyingError?
    ) {
        sendCompletion(
            taskIdentifier: taskIdentifier,
            taskDescription: taskDescription,
            originalRequestURL: originalRequestURL,
            currentRequestURL: currentRequestURL,
            payload: location.map(DownloadCompletionPayload.legacy),
            error: error
        )
    }

    func sendRestorationBoundary() {
        sendLossless(.restorationBoundary)
    }

    func sendBackgroundEventsFinished(completion: (@Sendable () -> Void)?) {
        sendLossless(.backgroundEventsFinished(completion: completion))
    }

    private func sendLossless(_ event: Event) {
        let action = state.withLock { state -> CompletionSendAction in
            guard !state.isFinished else {
                return .rejected
            }

            // Every completion is a global ordering boundary. Progress that
            // arrives afterwards must occupy a new queue segment even when it
            // belongs to a different task, otherwise coalescing could move
            // post-completion bytes ahead of the completion in delegate order.
            state.activeProgressSegmentByTask.removeAll(keepingCapacity: true)

            if let pendingWaiter = state.waiter {
                state.waiter = nil
                return .resume(pendingWaiter)
            } else {
                state.append(.lossless(event))
                return .queued
            }
        }

        switch action {
        case .queued:
            break
        case .resume(let waiter):
            waiter.resume(returning: event)
        case .rejected:
            DownloadManager.removeStagedLocationIfNeeded(from: event)
        }
    }

    /// Returns the next delegate event, or `nil` after `finish()` once every
    /// event accepted before the finish boundary has been drained.
    ///
    /// `DownloadManager` owns the sole consumer. Concurrent `next()` calls are
    /// a programmer error because they would weaken delegate FIFO ordering.
    func next() async -> Event? {
        await withCheckedContinuation { continuation in
            let action = state.withLock { state -> NextAction in
                if let event = Self.popFirst(from: &state) {
                    return .resume(event)
                } else if state.isFinished {
                    return .resume(nil)
                } else {
                    precondition(
                        state.waiter == nil,
                        "DownloadDelegateEventChannel supports one consumer"
                    )
                    state.waiter = continuation
                    return .waiting
                }
            }

            if case .resume(let event) = action {
                continuation.resume(returning: event)
            }
        }
    }

    /// Stops accepting new delegate callbacks while preserving every event
    /// already accepted. A waiting consumer is terminated immediately only
    /// when there is no buffered work left.
    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<Event?, Never>? in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            if state.isQueueEmpty {
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            }
            return nil
        }

        waiter?.resume(returning: nil)
    }

    deinit {
        let (waiter, abandonedEvents) = state.withLock {
            state -> (CheckedContinuation<Event?, Never>?, [Event]) in
            state.isFinished = true
            let waiter = state.waiter
            state.waiter = nil

            var events: [Event] = []
            events.reserveCapacity(state.queuedEventCount)
            while let event = Self.popFirst(from: &state) {
                events.append(event)
            }
            return (waiter, events)
        }

        waiter?.resume(returning: nil)
        for event in abandonedEvents {
            DownloadManager.removeStagedLocationIfNeeded(from: event)
        }
    }

    private static func popFirst(from state: inout State) -> Event? {
        while let queuedEvent = state.popFirst() {
            switch queuedEvent {
            case .lossless(let event):
                return event
            case .progress(let taskIdentifier, let segmentID):
                guard let progress = state.progressBySegment.removeValue(forKey: segmentID) else {
                    continue
                }
                if state.activeProgressSegmentByTask[taskIdentifier] == segmentID {
                    state.activeProgressSegmentByTask.removeValue(forKey: taskIdentifier)
                }
                return progress.event
            }
        }
        return nil
    }
}
