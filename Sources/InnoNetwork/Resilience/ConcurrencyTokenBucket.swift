import Foundation
import os

/// Package-owned FIFO semaphore behind ``ConcurrencyLimitExecutionPolicy``.
/// Keeping acquisition and release behind the execution policy prevents
/// callers from leaking tokens when transport failures skip a paired response
/// interceptor.
package actor ConcurrencyTokenBucket {
    package let maxConcurrent: Int
    package var available: Int

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []
    private let cancelMarks = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    /// Creates a bucket with the supplied concurrency cap. Values
    /// less than 1 are clamped to 1 so the bucket always permits at
    /// least one in-flight task.
    package init(maxConcurrent: Int) {
        let cap = Swift.max(1, maxConcurrent)
        self.maxConcurrent = cap
        self.available = cap
    }

    /// Acquires a token, suspending the caller if the cap is reached.
    /// Cancellation removes the caller from the FIFO queue and throws
    /// `CancellationError` before a future token can be consumed.
    package func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }

        let waiterID = UUID()
        var acquiredToken = false
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if consumeCancelMark(for: waiterID) || Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            } onCancel: { [weak self] in
                self?.cancelMarks.withLock { marks in
                    _ = marks.insert(waiterID)
                }
                Task { [weak self] in
                    await self?.cancelWaiter(id: waiterID)
                }
            }
            acquiredToken = true
            try Task.checkCancellation()
        } catch {
            if acquiredToken {
                release()
            }
            throw error
        }
    }

    /// Releases a token. If a waiter is queued it is resumed;
    /// otherwise the token returns to the available pool. The
    /// bucket never exceeds `maxConcurrent` available tokens, so a
    /// duplicate release is a no-op.
    package func release() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if consumeCancelMark(for: next.id) {
                next.continuation.resume(throwing: CancellationError())
                continue
            }
            next.continuation.resume()
            return
        }
        if available < maxConcurrent {
            available += 1
        }
    }

    private func cancelWaiter(id: UUID) {
        _ = consumeCancelMark(for: id)
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func consumeCancelMark(for id: UUID) -> Bool {
        cancelMarks.withLock { marks in
            marks.remove(id) != nil
        }
    }

    /// Number of acquirers currently queued behind the cap. Useful
    /// for diagnostics; not intended as a production metric source.
    package var queuedWaitersCount: Int {
        waiters.count
    }
}
