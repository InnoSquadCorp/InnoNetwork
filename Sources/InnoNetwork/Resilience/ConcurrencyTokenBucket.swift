import Foundation
import os

/// Bounded counting semaphore implemented as an actor so the
/// fairness queue stays Sendable across structured-concurrency
/// boundaries.
///
/// `ConcurrencyTokenBucket` caps the number of in-flight tasks
/// holding a token: callers `acquire()` before doing the work and
/// `release()` after, exactly like `DispatchSemaphore` but without
/// blocking a thread. Pending acquirers are queued FIFO, so a busy
/// system makes forward progress per request rather than starving
/// some callers indefinitely.
///
/// ## Wiring
///
/// For normal request execution, prefer
/// ``ConcurrencyLimitExecutionPolicy`` in
/// ``ResiliencePack/customExecutionPolicies``. The policy owns the
/// acquire/release pair inside the executor chain, so tokens are
/// released after success, failure, and cancellation before the call
/// returns to the client.
///
/// The raw bucket remains useful for custom work outside the request
/// pipeline. If you wire it manually through a paired
/// ``RequestInterceptor`` / ``ResponseInterceptor``, be aware that
/// transport errors can skip the response interceptor:
///
/// ```swift
/// let bucket = ConcurrencyTokenBucket(maxConcurrent: 4)
///
/// struct AcquireInterceptor: RequestInterceptor {
///     let bucket: ConcurrencyTokenBucket
///     func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
///         try await bucket.acquire()
///         return urlRequest
///     }
/// }
///
/// struct ReleaseInterceptor: ResponseInterceptor {
///     let bucket: ConcurrencyTokenBucket
///     func adapt(_ response: HTTPURLResponse, data: Data) async throws
///         -> (HTTPURLResponse, Data)
///     {
///         await bucket.release()
///         return (response, data)
///     }
/// }
/// ```
///
/// > Important: an interceptor pair leaks tokens on transport
/// > errors (the response interceptor never runs). Production request
/// > paths should use ``ConcurrencyLimitExecutionPolicy`` instead.
///
/// ## Fairness and capacity
///
/// `acquire()` resumes pending waiters in insertion order; cancelled
/// waiters are removed before they can consume a future token. If no
/// waiters are queued and the bucket is below capacity, `release()`
/// returns the token to the available pool. The bucket never
/// over-releases past `maxConcurrent`, so a stray double-release
/// from caller code cannot exceed the configured cap.
public actor ConcurrencyTokenBucket {
    /// Maximum number of tokens the bucket hands out concurrently.
    public let maxConcurrent: Int

    /// Tokens currently available for immediate `acquire()`.
    public private(set) var available: Int

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []
    private let cancelMarks = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    /// Creates a bucket with the supplied concurrency cap. Values
    /// less than 1 are clamped to 1 so the bucket always permits at
    /// least one in-flight task.
    public init(maxConcurrent: Int) {
        let cap = Swift.max(1, maxConcurrent)
        self.maxConcurrent = cap
        self.available = cap
    }

    /// Acquires a token, suspending the caller if the cap is reached.
    /// Cancellation removes the caller from the FIFO queue and throws
    /// `CancellationError` before a future token can be consumed.
    public func acquire() async throws {
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
    public func release() {
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
    public var queuedWaitersCount: Int {
        waiters.count
    }
}
