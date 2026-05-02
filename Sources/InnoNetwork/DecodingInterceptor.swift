import Foundation

/// Observes or rewrites the response decode boundary.
///
/// `DecodingInterceptor` runs at two well-defined points the
/// existing ``ResponseInterceptor`` chain cannot reach:
///
/// 1. ``willDecode(data:response:)`` is invoked **after** all
///    response interceptors have settled and **before** the configured
///    decoder runs. Use it to unwrap a JSON envelope, repair malformed
///    dates, or sanitize a payload that the decoder would otherwise
///    reject.
/// 2. ``didDecode(_:response:)`` is invoked **after** the decoder
///    succeeds. Use it to record decode metrics, attach correlation
///    metadata to the typed value, or return a normalized instance of
///    the **same** `APIResponse` type. The hook cannot change the
///    response type — the generic signature requires the returned
///    value to match the input.
///
/// Interceptors are applied in declaration order for both hooks
/// (`configuration.decodingInterceptors[0]` runs first on the way in
/// and first on the way out). Throwing from either hook aborts the
/// **current attempt** with the thrown error and skips any remaining
/// interceptors. The error is then surfaced to the configured
/// ``RetryPolicy`` exactly like a transport failure, so the policy
/// still decides whether to retry the request — throw a ``NetworkError``
/// whose classification reflects the desired retry outcome (e.g.
/// ``NetworkError/decoding(stage:underlying:response:)`` with
/// ``DecodingStage/responseBody`` for a non-retryable schema mismatch).
///
/// All conforming types must be `Sendable` because the executor may
/// invoke them concurrently from multiple in-flight requests. Both
/// hooks are `async` so adapters can read actor-isolated state
/// (metric aggregators, correlation stores).
public protocol DecodingInterceptor: Sendable {
    /// Inspect or rewrite the raw response payload before decoding.
    ///
    /// - Parameters:
    ///   - data: The bytes produced by the previous interceptor in the
    ///     chain (the raw response body for the first interceptor).
    ///   - response: Status, headers, and request context for the
    ///     response that produced `data`.
    /// - Returns: The bytes to forward to the next stage; return `data`
    ///   unchanged to act as a passive observer.
    /// - Throws: Any error to abort the request without decoding.
    func willDecode(data: Data, response: Response) async throws -> Data

    /// Inspect or rewrite the decoded value before returning to the
    /// caller.
    ///
    /// - Parameters:
    ///   - value: The typed response produced by the decoder or the
    ///     previous interceptor in the chain.
    ///   - response: The same response metadata observed by
    ///     ``willDecode(data:response:)`` so adapters can correlate
    ///     headers with the decoded value.
    /// - Returns: The typed value to forward to the next stage; return
    ///   `value` unchanged to act as a passive observer.
    /// - Throws: Any error to abort the current attempt; the configured
    ///   ``RetryPolicy`` decides whether another attempt runs.
    func didDecode<APIResponse>(
        _ value: APIResponse,
        response: Response
    ) async throws -> APIResponse where APIResponse: Sendable
}

public extension DecodingInterceptor {
    func willDecode(data: Data, response: Response) async throws -> Data { data }

    func didDecode<APIResponse>(
        _ value: APIResponse,
        response: Response
    ) async throws -> APIResponse where APIResponse: Sendable {
        value
    }
}
