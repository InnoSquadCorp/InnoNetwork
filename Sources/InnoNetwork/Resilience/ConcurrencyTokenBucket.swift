import Foundation

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
/// The library does not yet integrate the bucket directly into
/// ``RequestExecutor``'s pre-flight stage — that integration is on
/// the 5.x roadmap alongside ``CircuitBreakerPolicy`` and the
/// reachability work. In the meantime, adopters can wire the bucket
/// through a paired ``RequestInterceptor`` /
/// ``ResponseInterceptor`` so request lifecycles still bound the
/// in-flight count:
///
/// ```swift
/// let bucket = ConcurrencyTokenBucket(maxConcurrent: 4)
///
/// struct AcquireInterceptor: RequestInterceptor {
///     let bucket: ConcurrencyTokenBucket
///     func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
///         await bucket.acquire()
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
/// > errors (the response interceptor never runs). The pattern is
/// > acceptable for short-running clients and tests; production
/// > deployments should wait for the executor-integrated build.
///
/// ## Fairness and capacity
///
/// `acquire()` resumes pending waiters in insertion order; if no
/// waiters are queued and the bucket is below capacity, `release()`
/// returns the token to the available pool. The bucket never
/// over-releases past `maxConcurrent`, so a stray double-release
/// from caller code cannot exceed the configured cap.
public actor ConcurrencyTokenBucket {
    /// Maximum number of tokens the bucket hands out concurrently.
    public let maxConcurrent: Int

    /// Tokens currently available for immediate `acquire()`.
    public private(set) var available: Int

    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a bucket with the supplied concurrency cap. Values
    /// less than 1 are clamped to 1 so the bucket always permits at
    /// least one in-flight task.
    public init(maxConcurrent: Int) {
        let cap = Swift.max(1, maxConcurrent)
        self.maxConcurrent = cap
        self.available = cap
    }

    /// Acquires a token, suspending the caller if the cap is
    /// reached. Cancellation does not interrupt the wait — the
    /// caller is expected to release the token in the matching
    /// `defer` or response interceptor.
    public func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// Releases a token. If a waiter is queued it is resumed;
    /// otherwise the token returns to the available pool. The
    /// bucket never exceeds `maxConcurrent` available tokens, so a
    /// duplicate release is a no-op.
    public func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
            return
        }
        if available < maxConcurrent {
            available += 1
        }
    }

    /// Number of acquirers currently queued behind the cap. Useful
    /// for diagnostics; not intended as a production metric source.
    public var queuedWaitersCount: Int {
        waiters.count
    }
}
