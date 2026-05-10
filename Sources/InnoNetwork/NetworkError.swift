//
//  NetworkError.swift
//  Network
//
//  Created by Chang Woo Son on 6/20/24.
//

import Foundation

/// Specific timeout that produced a ``NetworkError/timeout(reason:underlying:)``.
///
/// Distinguishing between request, resource, and connection timeouts lets
/// the UI surface targeted retry copy ("the request is taking longer than
/// expected" vs. "we couldn't reach the server") instead of a generic
/// transport failure.
///
/// Mapping behaviour (see ``NetworkError/mapTransportError(_:)``):
/// - `URLError.timedOut` → ``requestTimeout``.
/// - `URLError.cannotConnectToHost` → ``connectionTimeout``.
/// - Other `URLError` codes (`cannotFindHost`, `dnsLookupFailed`,
///   `networkConnectionLost`, `notConnectedToInternet`, …) intentionally
///   stay as ``NetworkError/underlying(_:_:)`` so callers can tell a real
///   timeout from a name-resolution or reachability failure.
/// - ``resourceTimeout`` is produced by the metrics-aware or
///   attempt-interval overloads only when the caller also supplies a true
///   `URLSessionConfiguration.timeoutIntervalForResource` budget.
///   `URLRequest.timeoutInterval` remains a request-level timeout and must
///   not be passed as that resource budget. The built-in request and stream
///   executors pass `nil` for `NetworkConfiguration.timeout` because that
///   value is applied to `URLRequest.timeoutInterval`. These overloads return
///   ``resourceTimeout`` for `URLError.timedOut` only when the task
///   interval reaches the resource budget; otherwise it falls back to
///   ``requestTimeout``. The single-argument
///   ``NetworkError/mapTransportError(_:)`` retains the 4.x behaviour
///   (`.requestTimeout` for every `URLError.timedOut`).
public enum TimeoutReason: Sendable, Equatable {
    /// The request timed out before the server responded with the first byte.
    /// Produced from `URLError.timedOut`.
    case requestTimeout
    /// The resource transfer exceeded its total time budget. Reserved for
    /// callers that observe URLSession task metrics, and for the built-in
    /// executors when their measured attempt interval reaches an explicitly
    /// known resource-timeout budget. `URLRequest.timeoutInterval` is a
    /// request-level timeout, so it still maps to ``requestTimeout``.
    /// `URLError` does not surface which timeout interval fired, so shorter
    /// or unmeasured attempts remain ``requestTimeout``.
    case resourceTimeout
    /// Connection establishment failed (for example, a captive portal
    /// blocking the TCP handshake or the server actively refusing the
    /// socket). Produced from `URLError.cannotConnectToHost`. Name
    /// resolution and reachability failures (`cannotFindHost`,
    /// `dnsLookupFailed`, `notConnectedToInternet`, …) stay as
    /// ``NetworkError/underlying(_:_:)`` instead of mapping here.
    case connectionTimeout
}


/// Stage of the response-decoding pipeline that produced a
/// ``NetworkError/decoding(stage:underlying:response:)``.
///
/// The stage tag lets callers route decoding failures to different
/// handlers without inspecting the underlying error. ``RetryPolicy``
/// and ``DecodingInterceptor`` use the stage tag to decide whether a
/// retry would change the outcome (it almost never does for decoding
/// failures, so the default policy treats every stage as terminal).
public enum DecodingStage: Sendable, Equatable {
    /// The full response body failed to decode into the declared
    /// `APIResponse` type. This is the most common stage and matches
    /// the legacy `objectMapping` case.
    case responseBody

    /// A single line/event/frame inside a streaming response failed
    /// to decode. The transport remains open; only the offending
    /// frame is rejected.
    case streamFrame
}


/// All execution-level failures the library surfaces to callers.
///
/// `NetworkError` is **not** `@frozen` and the project does not promise
/// to keep that constant: the resilience and observability features in
/// the roadmap will introduce new failure modes (notably circuit-breaker
/// trips and richer rate-limit / reachability diagnostics). To stay
/// forward-compatible against the 4.x line, every exhaustive `switch` over a
/// `NetworkError` value should include a `@unknown default` arm:
///
/// ```swift
/// catch let error as NetworkError {
///     switch error {
///     case .statusCode(let response):           handleStatus(response)
///     case .timeout(let reason, _):             handleTimeout(reason)
///     case .configuration(reason: .invalidBaseURL(_)),
///          .configuration(reason: .invalidRequest(_)):
///                                                handleConfigurationError()
///     // ... other cases
///     @unknown default:
///         assertionFailure("Unhandled NetworkError case — update the switch.")
///     }
/// }
/// ```
/// Configuration-shaped failure reason carried by ``NetworkError/configuration(reason:)``.
///
/// The 4.0.0 API uses this payload so configuration-shaped failures
/// (`invalidBaseURL`, `invalidRequest`, and `offline`, raised by
/// ``ReachabilityCheckExecutionPolicy`` when the device is known to be
/// offline) share a single switch arm. The old standalone
/// `NetworkError.invalidBaseURL` and
/// `NetworkError.invalidRequestConfiguration` cases are not available in
/// the 4.0.0 surface.
public enum NetworkConfigurationFailureReason: Sendable, Equatable {
    /// The base URL the request would resolve against is malformed or
    /// missing a scheme.
    case invalidBaseURL(String)
    /// The request configuration cannot be assembled (for example,
    /// missing refresh-token policy for an auth-required endpoint).
    case invalidRequest(String)
    /// The device is known to be offline (the configured
    /// ``NetworkMonitoring`` snapshot reports `.unsatisfied`). Surfaced by
    /// ``ReachabilityCheckExecutionPolicy``.
    case offline(String)
}

public enum NetworkError: Error, Sendable {
    /// Consolidated configuration-shaped failure. Carries a typed
    /// ``NetworkConfigurationFailureReason`` payload distinguishing
    /// invalidBaseURL / invalidRequest / offline failures.
    case configuration(reason: NetworkConfigurationFailureReason)
    /// Indicates a response failed with an invalid HTTP status code.
    case statusCode(Response)
    /// Indicates a response failed to decode into the declared `APIResponse`
    /// type. Carries a ``DecodingStage`` tag so callers can route
    /// envelope/multipart/stream-frame failures separately from a top-level
    /// body decode error.
    case decoding(stage: DecodingStage, underlying: SendableUnderlyingError, response: Response)

    case underlying(SendableUnderlyingError, Response?)
    case trustEvaluationFailed(TrustFailureReason)

    case cancelled
    /// The request did not complete within its configured timeout window.
    ///
    /// `underlying` preserves the original transport error when the timeout is
    /// produced by the built-in mapper, so diagnostics can still inspect the
    /// associated value directly or use `NSError.userInfo[NSUnderlyingErrorKey]`
    /// after bridging.
    case timeout(reason: TimeoutReason, underlying: SendableUnderlyingError? = nil)
    /// The transport completed but produced a response body larger than
    /// ``NetworkConfiguration/responseBodyLimit``. Raised so the executor can
    /// short-circuit decoding and so callers can choose a recovery strategy
    /// (raise the limit, fall back to streaming, or surface a paged retry)
    /// rather than silently OOM the process or pass an oversized payload to
    /// `JSONDecoder`.
    ///
    /// A 304 Not Modified revalidation against the cached response
    /// failed at the conditional-request layer (header merge produced
    /// an unparseable response, the cached body was unreadable, or the
    /// stored `Vary` snapshot disagreed with what the server returned).
    /// Carries the underlying error and the cached entry so consumers
    /// can choose to fall through to a fresh transport attempt or
    /// surface the failure.
    ///
    /// - Parameters:
    ///   - underlying: The error raised by the revalidation pipeline.
    ///   - cached: The previously-stored response that the revalidation
    ///     attempt was working from. The bytes have already been
    ///     redacted via ``NetworkError/redactingFailurePayload()`` unless
    ///     ``NetworkConfiguration/captureFailurePayload`` is set.
    case cacheRevalidationFailed(underlying: SendableUnderlyingError, cached: Response)
}


extension NetworkError: LocalizedError {
    /// Localized human-readable summary of the failure.
    ///
    /// Strings are loaded from
    /// `Sources/InnoNetwork/Resources/<lang>.lproj/Localizable.strings`
    /// (currently `en` and `ko`). New locales can be added by dropping a
    /// sibling `<lang>.lproj/Localizable.strings` file with the same keys.
    /// Keys are stable and treated as part of the
    /// ``InnoNetwork`` Provisionally Stable contract — see
    /// `API_STABILITY.md`.
    public var errorDescription: String? {
        switch self {
        case .configuration(let reason):
            switch reason {
            case .invalidBaseURL(let s):
                return localizedFormat("NetworkError.invalidBaseURL", s)
            case .invalidRequest(let s):
                return localizedFormat("NetworkError.invalidRequestConfiguration", s)
            case .offline(let s):
                return localizedFormat("NetworkError.offline", s)
            }
        case .decoding(let stage, let error, _):
            return localizedFormat(
                "NetworkError.decoding",
                String(describing: stage),
                error.message
            )
        case .statusCode:
            return localized("NetworkError.statusCode")
        case .underlying(let error, _):
            return error.message
        case .trustEvaluationFailed(let reason):
            return localizedTrustFailureDescription(for: reason)
        case .cancelled:
            return localized("NetworkError.cancelled")
        case .timeout(let reason, _):
            switch reason {
            case .requestTimeout:
                return localized("NetworkError.timeout.request")
            case .resourceTimeout:
                return localized("NetworkError.timeout.resource")
            case .connectionTimeout:
                return localized("NetworkError.timeout.connection")
            }
        case .cacheRevalidationFailed(let underlying, _):
            return localizedFormat(
                "NetworkError.cacheRevalidationFailed",
                underlying.message
            )
        }
    }
}


// MARK: - Localization helpers

@inline(__always)
private func localized(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "NetworkError description")
}

@inline(__always)
private func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), locale: Locale.current, arguments: arguments)
}

private func localizedTrustFailureDescription(for reason: TrustFailureReason) -> String {
    switch reason {
    case .unsupportedAuthenticationMethod(let method):
        return localizedFormat(
            "NetworkError.trust.unsupportedAuthenticationMethod",
            method
        )
    case .missingServerTrust:
        return localized("NetworkError.trust.missingServerTrust")
    case .systemTrustEvaluationFailed(let reason):
        if let reason {
            return localizedFormat(
                "NetworkError.trust.systemTrustEvaluationFailedWithReason",
                reason
            )
        }
        return localized("NetworkError.trust.systemTrustEvaluationFailed")
    case .hostNotPinned(let host):
        return localizedFormat("NetworkError.trust.hostNotPinned", host)
    case .publicKeyExtractionFailed:
        return localized("NetworkError.trust.publicKeyExtractionFailed")
    case .pinMismatch(let host):
        return localizedFormat("NetworkError.trust.pinMismatch", host)
    case .custom(let message):
        return message
    }
}

// MARK: - Package-internal localization probe

/// Looks up the raw localized string for `key` in the InnoNetwork resource
/// bundle, restricted to the localization identified by `localization`
/// (for example `"en"` or `"ko"`). Returns `nil` when either the
/// localization sub-bundle or the key itself is missing.
///
/// This helper exists for the package's own test targets. Production
/// callers should rely on ``NetworkError/errorDescription`` and let
/// `Foundation` resolve the active localization. Listed as
/// `package`-scope so it never crosses the public API surface.
package func _localizedNetworkErrorString(
    forKey key: String,
    localization: String
) -> String? {
    guard
        let path = Bundle.module.path(forResource: localization, ofType: "lproj"),
        let bundle = Bundle(path: path)
    else {
        return nil
    }
    let sentinel = "<<missing>>"
    let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
    return value == sentinel ? nil : value
}

public extension NetworkError {
    /// Depending on error type, returns a `Response` object.
    var response: Response? {
        switch self {
        case .configuration: return nil
        case .decoding(_, _, let response): return response
        case .statusCode(let response): return response
        case .underlying(_, let response): return response
        case .trustEvaluationFailed: return nil
        case .cancelled: return nil
        case .timeout: return nil
        case .cacheRevalidationFailed(_, let response): return response
        }
    }

    /// Depending on error type, returns an underlying `Error`.
    internal var underlyingError: SendableUnderlyingError? {
        switch self {
        case .configuration: return nil
        case .decoding(_, let error, _): return error
        case .statusCode: return nil
        case .underlying(let error, _): return error
        case .trustEvaluationFailed: return nil
        case .cancelled: return nil
        case .timeout(_, let underlying): return underlying
        case .cacheRevalidationFailed(let underlying, _): return underlying
        }
    }

    /// Returns `true` for any failure produced inside the response-decoding
    /// pipeline. Built-in retry policies treat decoding failures as terminal
    /// because retrying the same request against the same server yields the
    /// same body shape; consumers writing their own retry strategy can use
    /// this helper to express the same rule without enumerating
    /// ``DecodingStage`` cases.
    var isDecodingFailure: Bool {
        if case .decoding = self {
            return true
        }
        return false
    }
}

// MARK: - Error User Info

extension NetworkError: CustomNSError {
    public static var errorDomain: String {
        "com.innosquad.innonetwork"
    }

    public var errorCode: Int {
        switch self {
        case .configuration(let reason):
            switch reason {
            case .invalidBaseURL: return 1001
            case .invalidRequest: return 1002
            case .offline: return 1003
            }
        case .decoding:
            return 2002
        case .statusCode:
            return 3001
        case .underlying:
            return 4001
        case .trustEvaluationFailed:
            return 5001
        case .cancelled:
            return NSURLErrorCancelled
        case .timeout:
            return NSURLErrorTimedOut
        case .cacheRevalidationFailed:
            return 6002
        }
    }

    public var errorUserInfo: [String: Any] {
        var userInfo: [String: Any] = [:]
        userInfo[NSLocalizedDescriptionKey] = errorDescription ?? "Network error"
        if let underlyingError {
            userInfo[NSUnderlyingErrorKey] = underlyingError
        }
        return userInfo
    }
}

// MARK: - Redaction

public extension NetworkError {
    /// Returns a copy of the error with any attached failure payload
    /// (`Response.data`) zeroed out. Status code, request, and headers are
    /// preserved so callers can still classify the failure. Used by the
    /// request executor when ``NetworkConfiguration/captureFailurePayload``
    /// is disabled (the default), so PII in failure bodies cannot leak into
    /// logs, crash reports, or analytics through the error chain.
    func redactingFailurePayload() -> NetworkError {
        switch self {
        case .decoding(let stage, let underlying, let response):
            return .decoding(stage: stage, underlying: underlying, response: response.redactingData())
        case .statusCode(let response):
            return .statusCode(response.redactingData())
        case .underlying(let err, let response?):
            return .underlying(err, response.redactingData())
        case .cacheRevalidationFailed(let underlying, let cached):
            return .cacheRevalidationFailed(underlying: underlying, cached: cached.redactingData())
        case .configuration,
            .underlying(_, nil),
            .trustEvaluationFailed,
            .cancelled,
            .timeout:
            return self
        }
    }
}

// MARK: - Cancellation Check

extension NetworkError {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if case .cancelled = error as? NetworkError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    /// Maps a raw transport error from `URLSession` (or a configured
    /// transport adapter) into the public ``NetworkError`` surface.
    ///
    /// The mapping is **intentionally narrow** for `URLError`:
    /// - `URLError.timedOut` →
    ///   ``NetworkError/timeout(reason:underlying:)`` with
    ///   ``TimeoutReason/requestTimeout``.
    /// - `URLError.cannotConnectToHost` → `.timeout` with
    ///   ``TimeoutReason/connectionTimeout`` (the TCP handshake failed
    ///   inside the connect budget — a captive portal or refused socket).
    /// - All other `URLError` codes — including `cannotFindHost`,
    ///   `dnsLookupFailed`, `networkConnectionLost`, and
    ///   `notConnectedToInternet` — stay as ``NetworkError/underlying(_:_:)``.
    ///   These are *not* timeouts: name resolution and reachability
    ///   failures must be distinguishable from a server that simply took
    ///   too long, because the right user-facing copy and retry policy
    ///   diverges between the two. Callers that need to recognize them
    ///   should pattern-match the underlying `URLError` from
    ///   ``SendableUnderlyingError``.
    ///
    /// `CancellationError` and `URLError.cancelled` collapse to
    /// ``NetworkError/cancelled`` so cooperative cancellation is uniform.
    /// `TrustEvaluationError` is forwarded as
    /// ``NetworkError/trustEvaluationFailed(_:)``.
    ///
    /// > Important: This mapping is part of the public API contract — it is
    /// > locked by `NetworkErrorTimeoutTests` (see the contract-lock test
    /// > group). Do not widen the `.timeout` arm without a paired test
    /// > update; collapsing additional `URLError` codes into `.timeout`
    /// > silently changes consumer retry semantics.
    static func mapTransportError(_ error: Error) -> NetworkError {
        mapTransportError(error, metrics: nil, resourceTimeoutInterval: nil)
    }

    /// Metrics-aware variant of ``mapTransportError(_:)`` that can
    /// distinguish ``TimeoutReason/resourceTimeout`` from
    /// ``TimeoutReason/requestTimeout`` when the caller has the
    /// `URLSessionTaskMetrics` for the failed request.
    ///
    /// `URLError.timedOut` collapses both timeouts on Foundation's
    /// surface, so this overload only resolves the distinction when
    /// **both** of the following are available:
    /// - `metrics` from `URLSessionTaskDelegate`
    ///   `urlSession(_:task:didFinishCollecting:)`, providing the
    ///   actual task interval.
    /// - `resourceTimeoutInterval`, the configured
    ///   `timeoutIntervalForResource` for the URLSession that ran the
    ///   task. Do not pass `URLRequest.timeoutInterval` here: Foundation
    ///   treats it as a request-level timeout, not the resource-wide
    ///   transfer budget.
    ///
    /// When either input is missing, the mapping falls back to the
    /// 4.x behaviour (`.requestTimeout` for `URLError.timedOut`).
    /// `.resourceTimeout` is produced only when the task interval
    /// elapsed at or above the configured resource timeout, which
    /// matches Foundation's "we hit the resource budget" signal more
    /// precisely than inferring from the error code alone.
    static func mapTransportError(
        _ error: Error,
        metrics: URLSessionTaskMetrics?,
        resourceTimeoutInterval: TimeInterval?
    ) -> NetworkError {
        mapTransportError(
            error,
            taskInterval: metrics?.taskInterval,
            resourceTimeoutInterval: resourceTimeoutInterval
        )
    }

    /// Attempt-interval variant used by built-in executors when URLSession
    /// task metrics are not available on the throwing path. The mapping keeps
    /// the same conservative rule as the metrics overload: only a timed-out
    /// attempt whose measured elapsed time reaches an explicitly configured
    /// resource timeout is classified as ``TimeoutReason/resourceTimeout``.
    /// Passing `nil` preserves request-level timeout semantics.
    static func mapTransportError(
        _ error: Error,
        startedAt: Date,
        endedAt: Date,
        resourceTimeoutInterval: TimeInterval?
    ) -> NetworkError {
        let intervalEnd = endedAt < startedAt ? startedAt : endedAt
        return mapTransportError(
            error,
            taskInterval: DateInterval(start: startedAt, end: intervalEnd),
            resourceTimeoutInterval: resourceTimeoutInterval
        )
    }

    static func mapTransportError(
        _ error: Error,
        taskInterval: DateInterval?,
        resourceTimeoutInterval: TimeInterval?
    ) -> NetworkError {
        if let networkError = error as? NetworkError {
            return networkError
        }

        if let trustEvaluationError = error as? TrustEvaluationError {
            switch trustEvaluationError {
            case .failed(let reason, _):
                return .trustEvaluationFailed(reason)
            }
        }

        if isCancellation(error) {
            return .cancelled
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                let reason = resolveTimeoutReason(
                    taskInterval: taskInterval,
                    resourceTimeoutInterval: resourceTimeoutInterval
                )
                return .timeout(reason: reason, underlying: SendableUnderlyingError(urlError))
            case .cannotConnectToHost:
                return .timeout(reason: .connectionTimeout, underlying: SendableUnderlyingError(urlError))
            default:
                break
            }
        }

        return .underlying(SendableUnderlyingError(error), nil)
    }

    /// Decides between ``TimeoutReason/requestTimeout`` and
    /// ``TimeoutReason/resourceTimeout`` for a `URLError.timedOut`,
    /// using the task interval reported by URLSession metrics.
    ///
    /// Returns ``TimeoutReason/resourceTimeout`` only when the task
    /// interval is at or beyond the configured resource budget; any
    /// shorter elapsed time is treated as ``TimeoutReason/requestTimeout``.
    private static func resolveTimeoutReason(
        taskInterval: DateInterval?,
        resourceTimeoutInterval: TimeInterval?
    ) -> TimeoutReason {
        guard let taskInterval, let resourceTimeoutInterval, resourceTimeoutInterval > 0 else {
            return .requestTimeout
        }
        let elapsed = taskInterval.duration
        return elapsed + 0.001 >= resourceTimeoutInterval ? .resourceTimeout : .requestTimeout
    }
}
