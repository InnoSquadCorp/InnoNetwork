import Foundation

/// Coarse recovery bucket for ``NetworkError``.
///
/// Use this when call sites need a UI, retry, or logging decision without
/// exhaustively switching over every `NetworkError` payload.
public enum NetworkErrorCategory: Sendable, Equatable {
    /// Client configuration or request construction failed.
    case configuration
    /// The server returned a non-acceptable HTTP status code.
    case statusCode
    /// Response body or streaming frame decoding failed.
    case decoding
    /// URLSession or lower-level transport failed without a narrower category.
    case transport
    /// DNS, offline, or connection-loss reachability failure.
    case reachability
    /// TLS trust or pinning evaluation failed.
    case trust
    /// The caller cancelled the request or stream.
    case cancellation
    /// Request, resource, or connection timeout.
    case timeout
}

extension NetworkError {
    /// Coarse recovery bucket for this error.
    public var category: NetworkErrorCategory {
        switch self {
        case .configuration:
            return .configuration
        case .statusCode:
            return .statusCode
        case .decoding:
            return .decoding
        case .underlying:
            return .transport
        case .reachability:
            return .reachability
        case .trustEvaluationFailed:
            return .trust
        case .cancelled:
            return .cancellation
        case .timeout:
            return .timeout
        }
    }

    /// Conservative hint for UI and policy code that needs a retry affordance.
    ///
    /// This does not override ``RetryPolicy``. It only answers whether the
    /// error class is usually transient.
    public var isRetriableHint: Bool {
        switch self {
        case .statusCode(let response):
            response.statusCode == 408
                || response.statusCode == 429
                || (500...599).contains(response.statusCode)
        case .underlying(let error, _):
            !Self.isCancellation(error)
        case .reachability, .timeout:
            true
        case .configuration, .decoding, .trustEvaluationFailed, .cancelled:
            false
        }
    }

    /// Whether the error is normally worth surfacing to an end user.
    public var isUserVisible: Bool {
        switch self {
        case .configuration(reason: .offline):
            return true
        case .configuration(reason: .invalidBaseURL),
            .configuration(reason: .invalidRequest),
            .cancelled:
            return false
        case .statusCode,
            .decoding,
            .underlying,
            .reachability,
            .trustEvaluationFailed,
            .timeout:
            return true
        }
    }
}
