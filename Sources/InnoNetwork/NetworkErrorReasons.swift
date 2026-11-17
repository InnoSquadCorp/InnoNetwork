import Foundation

/// Why the library declined to send, continue, or accept an exchange.
///
/// A policy rejection is a local decision. It carries no information about
/// the server's health, and replaying the same request immediately produces
/// the same rejection, so the built-in retry policy never retries it and the
/// circuit breaker never counts it against the host.
public enum NetworkPolicyRejection: Sendable, Equatable {
    /// The response body is larger than the limit configured through
    /// ``ResponseBodyBufferingPolicy``.
    ///
    /// `observedBytes` is the number of bytes collected when the limit was
    /// crossed, or the declared `Content-Length` when the response was
    /// rejected before its body was read.
    case responseBodyLimitExceeded(limitBytes: Int64, observedBytes: Int64)
    /// The circuit breaker for the request's host is open.
    case circuitOpen(CircuitBreakerOpenError)
    /// The bounded rate-limit queue is full.
    case rateLimitQueueFull
    /// The bounded rate-limit scope registry is full.
    case rateLimitScopeLimitReached
    /// The bounded request-admission queue is full.
    case admissionQueueFull
    /// The request waited in the admission queue past its deadline.
    case admissionWaitExpired
    /// The transport delivered a response that is not an HTTP response.
    ///
    /// The library admits only `http` and `https` URLs, and `URLSession`
    /// reports every response to such a request as an `HTTPURLResponse`. A
    /// different response type can therefore only come from a custom
    /// `URLProtocol` or a session implementation supplied by the
    /// application. That is a local integration fault that every replay
    /// reproduces, not evidence about the server, so it is rejected locally
    /// like the other cases.
    case nonHTTPResponse
}

/// Why a request could not be authenticated.
///
/// A `401` that the server returns after a successful refresh is not an
/// authentication failure of this kind; it stays
/// ``NetworkError/statusCode(_:)``.
public enum NetworkAuthenticationFailure: Sendable, Equatable {
    /// The session refresh operation showed that the session cannot be
    /// renewed: the server rejected the refresh request with a non-transient
    /// status, the token response could not be decoded, or the refresh
    /// closure threw an error of its own. The associated value is the error
    /// the refresh operation produced.
    ///
    /// A refresh that failed for a reason that says nothing about the session
    /// is not reported here. Cancellation, a connectivity failure, a timeout,
    /// a `408`, `429` or `5xx` from the refresh endpoint, an unclassified
    /// transport error, a local policy rejection, and a trust failure keep
    /// their own ``NetworkError`` case, because the session may still be
    /// valid.
    ///
    /// Replaying the request cannot repair the session, so the built-in retry
    /// policy never retries this failure. Applications normally respond by
    /// asking the user to sign in again.
    case refreshFailed(SendableUnderlyingError)
    /// A named request credential could not be selected, acquired, or
    /// applied. See ``RequestSecurityFailure`` for the individual reasons.
    case credential(RequestSecurityFailure)
}

extension NetworkPolicyRejection {
    /// The stable ``NetworkErrorCode`` that identifies this rejection in
    /// ``NetworkError/errorCode`` and in bridged `NSError` values.
    package var code: NetworkErrorCode {
        switch self {
        case .responseBodyLimitExceeded: .responseBodyLimitExceeded
        case .circuitOpen: .circuitOpen
        case .rateLimitQueueFull: .rateLimitQueueRejected
        case .rateLimitScopeLimitReached: .rateLimitScopeRejected
        case .admissionQueueFull: .requestAdmissionRejected
        case .admissionWaitExpired: .requestAdmissionWaitExpired
        case .nonHTTPResponse: .nonHTTPResponse
        }
    }
}

extension NetworkAuthenticationFailure {
    /// The stable ``NetworkErrorCode`` that identifies this failure in
    /// ``NetworkError/errorCode`` and in bridged `NSError` values.
    package var code: NetworkErrorCode {
        switch self {
        case .refreshFailed: .authenticationRefreshFailed
        case .credential: .requestCredentialFailed
        }
    }
}
