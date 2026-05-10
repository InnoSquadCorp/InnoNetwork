import Foundation

/// Caps the number of in-flight transport attempts by funnelling each
/// attempt through a ``ConcurrencyTokenBucket``.
///
/// `ConcurrencyLimitExecutionPolicy` wraps the rest of the
/// ``RequestExecutionPolicy`` chain in an `acquire` / `defer release`
/// pair, so a request only proceeds to the underlying transport once a
/// token is available. This is the executor-integrated form of the
/// raw ``ConcurrencyTokenBucket`` primitive: instead of pairing a
/// request and a response interceptor manually, callers register the
/// policy on ``ResiliencePack/customExecutionPolicies``
/// and the surrounding execution machinery handles the token lifecycle
/// — including transport errors, where the `defer` arm guarantees a
/// release even if the chain throws.
///
/// ```swift
/// let bucket = ConcurrencyTokenBucket(maxConcurrent: 4)
/// let limit = ConcurrencyLimitExecutionPolicy(bucket: bucket)
///
/// let configuration = NetworkConfiguration.advanced(
///     baseURL: baseURL,
///     resilience: ResiliencePack(customExecutionPolicies: [limit])
/// )
/// ```
///
/// Because `RequestExecutionPolicy` runs around each transport
/// attempt (including retries), a request that retries `N` times
/// acquires and releases the bucket `N` times — which matches the
/// "in-flight tokens cap concurrent transport pressure" semantics
/// users expect from a per-host or per-endpoint rate limit. Sharing
/// a bucket across multiple `NetworkClient` instances scopes the cap
/// across them; passing distinct buckets keeps the caps independent.
public struct ConcurrencyLimitExecutionPolicy: RequestExecutionPolicy {
    public let bucket: ConcurrencyTokenBucket

    public init(bucket: ConcurrencyTokenBucket) {
        self.bucket = bucket
    }

    public func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        await bucket.acquire()
        // The defer arm relies on a Task wrapper because release is
        // an actor-isolated method and `defer` cannot suspend; the
        // Task hop completes asynchronously without blocking the
        // caller's release boundary.
        defer { Task { await bucket.release() } }
        return try await next.execute(input.request)
    }
}
