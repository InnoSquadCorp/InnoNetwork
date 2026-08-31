import Foundation
import os

final class HLSTimedMetadataEventHub: Sendable {
    private typealias Continuation =
        AsyncStream<HLSTimedMetadataEvent>.Continuation

    private struct State {
        var continuations: [UUID: Continuation] = [:]
        var isFinished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func events(
        maximumBufferedEventCount: Int
    ) -> AsyncStream<HLSTimedMetadataEvent> {
        AsyncStream(
            bufferingPolicy: .bufferingNewest(
                maximumBufferedEventCount
            )
        ) { continuation in
            let identifier = UUID()
            let shouldFinish = state.withLock { state in
                guard !state.isFinished else {
                    return true
                }
                state.continuations[identifier] = continuation
                return false
            }
            guard !shouldFinish else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(identifier)
            }
        }
    }

    func send(_ event: HLSTimedMetadataEvent) {
        let continuations: [Continuation] = state.withLock { state in
            guard !state.isFinished else {
                return []
            }
            return Array(state.continuations.values)
        }
        for continuation in continuations {
            // Each subscriber owns a bounded newest-event buffer. Native
            // callback drops are reported separately by the delegate.
            continuation.yield(event)
        }
    }

    func finish() {
        let continuations: [Continuation] = state.withLock { state in
            guard !state.isFinished else {
                return []
            }
            state.isFinished = true
            let continuations = Array(state.continuations.values)
            state.continuations.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeContinuation(_ identifier: UUID) {
        _ = state.withLock { state in
            state.continuations.removeValue(forKey: identifier)
        }
    }
}
