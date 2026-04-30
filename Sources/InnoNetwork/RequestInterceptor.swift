import Foundation

/// Mutates an outgoing `URLRequest` before it is sent.
///
/// Interceptors compose in an onion model around each request attempt:
///
/// 1. Configuration-level interceptors run first
///    (`NetworkConfiguration.requestInterceptors`). They apply to every
///    endpoint that uses the same client and are intended for cross-cutting
///    concerns like auth headers, request IDs, or telemetry tags.
/// 2. Per-endpoint interceptors run next
///    (`APIDefinition.requestInterceptors`). They layer on top of the
///    configuration interceptors for a single endpoint.
/// 3. The active `RefreshTokenPolicy` (if any) applies its current token
///    last so per-endpoint adapters can read or override it.
///
/// All three stages run again on every retry attempt so dynamic values
/// (auth tokens, signing nonces, idempotency keys) stay fresh.
///
/// ## Failure semantics
///
/// Throwing from `adapt(_:)` aborts the request immediately. The thrown
/// error is propagated to the caller as-is, except that conforming to
/// `Error` types other than ``NetworkError`` are wrapped via
/// ``NetworkError/underlying(_:_:)``. The retry policy is **not**
/// consulted for adapter failures — adapter errors typically indicate
/// programmer error or unrecoverable state (missing credentials, malformed
/// configuration) rather than transient transport issues.
///
/// ## Concurrency
///
/// Interceptors are stored as `[any RequestInterceptor]` and may be invoked
/// concurrently from multiple in-flight requests, so conforming types must
/// be `Sendable`. `adapt(_:)` is `async` to allow awaiting on actor-isolated
/// state (token caches, signing services).
public protocol RequestInterceptor: Sendable {
    /// Returns a new `URLRequest` with adapter modifications applied.
    ///
    /// - Parameter urlRequest: The request as built by the executor or
    ///   produced by the previous interceptor in the chain.
    /// - Returns: The adapted request to forward to the next stage.
    /// - Throws: Any error to abort the request without retrying.
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest
}
