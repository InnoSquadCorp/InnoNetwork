import Foundation

/// Inspects or rewrites a successful transport response before it reaches
/// the decoder.
///
/// Interceptors compose in an onion model that unwinds inner→outer for
/// responses, mirroring the request-side ordering:
///
/// 1. Per-endpoint interceptors run first
///    (`APIDefinition.responseInterceptors`). They see the raw transport
///    response — status code, headers, payload data — exactly as produced
///    by the network layer (after coalescing, caching, and circuit
///    breaker policies have settled).
/// 2. Configuration-level interceptors run last
///    (`NetworkConfiguration.responseInterceptors`). By the time they
///    execute, per-endpoint adapters have finished, so a session-level
///    interceptor sees the same response shape it would in a session-only
///    setup.
///
/// All stages run **before** acceptable-status-code validation and
/// decoding. An interceptor may rewrite headers, body, or status code to
/// influence the validation that follows, but it cannot intercept
/// decoding failures themselves.
///
/// ## Failure semantics
///
/// Throwing from `adapt(_:request:)` aborts the **current attempt**.
/// The thrown error is wrapped as a request-execution failure and
/// surfaced to the configured ``RetryPolicy`` exactly like a transport
/// error, so the policy still decides whether to retry. Throw a
/// ``NetworkError`` whose classification matches the desired retry
/// outcome (e.g. ``NetworkError/statusCode(_:)`` for a payload the policy
/// would re-attempt, or a non-retryable category for a permanent rejection).
///
/// ## Concurrency
///
/// Conforming types must be `Sendable`; the executor may invoke them
/// concurrently from multiple in-flight requests. `adapt(_:request:)` is
/// `async` to permit awaiting on actor-isolated state (logging actors,
/// metrics aggregators).
public protocol ResponseInterceptor: Sendable {
    /// Returns a new ``Response`` with adapter modifications applied.
    ///
    /// - Parameters:
    ///   - urlResponse: The response produced by the previous stage in
    ///     the chain (the raw transport response for the first
    ///     interceptor).
    ///   - request: The fully adapted request that produced
    ///     `urlResponse`. Useful for context-sensitive decisions
    ///     (correlating headers, recording per-endpoint metrics) without
    ///     having to thread state through the call site.
    /// - Returns: The adapted response to forward to the next stage.
    /// - Throws: Any error to abort the current attempt; the configured
    ///   ``RetryPolicy`` decides whether another attempt runs.
    func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response
}
