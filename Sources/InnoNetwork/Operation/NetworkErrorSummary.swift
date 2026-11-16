import Foundation

/// Declares whether restarting an operation can safely repeat its request.
///
/// This value governs only the recovery recommendation in
/// ``NetworkErrorSummary``. The built-in retry policy remains independently
/// responsible for attempt budgets, backoff, and the request actually sent.
public enum NetworkOperationReplaySafety: String, Sendable, Equatable {
    /// Infer replay safety from the HTTP method. GET, HEAD, OPTIONS, and TRACE
    /// are replayable; other methods are not.
    case methodDefault

    /// The caller guarantees that every operation restart reuses the same
    /// application-owned idempotency key.
    ///
    /// A key generated from InnoNetwork's per-operation request identifier is
    /// not sufficient because a restarted operation receives a new identifier.
    case stableIdempotencyKey

    /// Never recommend repeating the request, including for safe methods. A
    /// failure before anything was sent, such as an offline device, still
    /// recommends ``NetworkRecoveryDisposition/waitForConnectivity``.
    case never
}

/// Recommended application response to a failure.
public enum NetworkRecoveryDisposition: String, Sendable, Equatable {
    /// The request can be replayed, but the caller still owns its retry budget
    /// and backoff. Do not turn this value into an unbounded retry loop.
    case retry
    /// Wait for connectivity before offering or scheduling another attempt.
    case waitForConnectivity
    /// Re-establish the user session. This does not authorize automatic replay
    /// of a request after authentication succeeds.
    case reauthenticate
    /// The same operation should not be replayed automatically.
    case doNotRetry
    /// No recovery action applies, for example after caller cancellation.
    case none
}

/// A payload-free description of a ``NetworkError``.
///
/// A summary keeps the classification of a failure — its category, stable
/// numeric code, HTTP status, and recommended recovery — and nothing else. It
/// carries no response body, headers, URL, or underlying error text, so it is
/// safe to store in view state, compare in tests, or send to analytics.
///
/// Obtain one from ``NetworkError/summary`` or, when the request's method and
/// authentication are known, from
/// ``NetworkError/summary(method:authentication:replaySafety:)``. A
/// ``NetworkOperation`` reports the contextual form in
/// ``NetworkOperationEvent/failed(id:summary:)``.
public struct NetworkErrorSummary: Sendable, Equatable {
    /// Coarse recovery bucket of the failure.
    public let category: NetworkErrorCategory
    /// The stable ``NetworkErrorCode`` raw value of the failure.
    public let code: Int
    /// The HTTP status code when the server produced one.
    public let statusCode: Int?
    /// What the application should do next.
    public let recovery: NetworkRecoveryDisposition
    /// The active stage when an operation-wide deadline expired. `nil` for
    /// transport timeouts and every failure that is not a deadline expiry.
    public let deadlineStage: NetworkOperationDeadlineStage?

    /// Creates a summary from its parts.
    ///
    /// The library derives summaries from errors, so application code
    /// normally reads ``NetworkError/summary`` instead. Use this initializer
    /// for expected values in tests and for test doubles that emit
    /// ``NetworkOperationEvent/failed(id:summary:)``. The values are stored
    /// as given; nothing checks that they describe a failure the library
    /// could produce.
    ///
    /// - Parameters:
    ///   - category: The coarse category of the failure.
    ///   - code: A ``NetworkErrorCode`` raw value.
    ///   - statusCode: The HTTP status, when the server produced one.
    ///   - recovery: The recommended next step.
    ///   - deadlineStage: The active stage when an operation deadline
    ///     expired, or `nil`.
    public init(
        category: NetworkErrorCategory,
        code: Int,
        statusCode: Int? = nil,
        recovery: NetworkRecoveryDisposition,
        deadlineStage: NetworkOperationDeadlineStage? = nil
    ) {
        self.category = category
        self.code = code
        self.statusCode = statusCode
        self.recovery = recovery
        self.deadlineStage = deadlineStage
    }
}

extension NetworkErrorSummary: CustomStringConvertible {
    /// A generic sentence for the failure category. It never contains request
    /// or response details.
    public var description: String {
        switch category {
        case .configuration: "The request configuration is invalid."
        case .statusCode: "The server returned an unsuccessful response."
        case .decoding: "The response could not be decoded."
        case .transport: "The network transport failed."
        case .reachability: "A usable network connection is unavailable."
        case .trust: "The server trust policy rejected the connection."
        case .cancellation: "The request was cancelled."
        case .timeout: "The request timed out."
        case .policy: "A local network policy rejected the request."
        case .authentication: "The request could not be authenticated."
        }
    }
}

extension NetworkError {
    /// A payload-free summary of this failure.
    ///
    /// Without the request's method and authentication the summary cannot
    /// know whether a replay is safe, so it never recommends
    /// ``NetworkRecoveryDisposition/retry`` or
    /// ``NetworkRecoveryDisposition/waitForConnectivity`` for a failure that
    /// followed transport, and recommends
    /// ``NetworkRecoveryDisposition/reauthenticate`` only for an explicit
    /// ``NetworkError/authentication(_:)`` failure. Use
    /// ``summary(method:authentication:replaySafety:)`` when that context is
    /// available.
    public var summary: NetworkErrorSummary {
        makeSummary(method: nil, authentication: nil, replaySafety: .never)
    }

    /// A payload-free summary whose recovery recommendation accounts for the
    /// request that failed.
    ///
    /// - Parameters:
    ///   - method: The HTTP method of the failed request.
    ///   - authentication: The session-authentication intent of the request.
    ///     A `401` recommends ``NetworkRecoveryDisposition/reauthenticate``
    ///     only for requests that use session authentication.
    ///   - replaySafety: Whether a restart may repeat the request.
    public func summary(
        method: HTTPMethod,
        authentication: SessionAuthentication,
        replaySafety: NetworkOperationReplaySafety = .methodDefault
    ) -> NetworkErrorSummary {
        makeSummary(method: method, authentication: authentication, replaySafety: replaySafety)
    }

    private func makeSummary(
        method: HTTPMethod?,
        authentication: SessionAuthentication?,
        replaySafety: NetworkOperationReplaySafety
    ) -> NetworkErrorSummary {
        let allowsReplay = Self.allowsReplay(method: method, replaySafety: replaySafety)
        let statusCode: Int?
        if case .statusCode(let response) = self {
            statusCode = response.statusCode
        } else {
            statusCode = nil
        }
        let deadlineStage: NetworkOperationDeadlineStage?
        if case .timeout(.operationDeadline(let stage), _) = self {
            deadlineStage = stage
        } else {
            deadlineStage = nil
        }
        return NetworkErrorSummary(
            category: category,
            code: errorCode,
            statusCode: statusCode,
            recovery: recovery(authentication: authentication, allowsReplay: allowsReplay),
            deadlineStage: deadlineStage
        )
    }

    private func recovery(
        authentication: SessionAuthentication?,
        allowsReplay: Bool
    ) -> NetworkRecoveryDisposition {
        switch self {
        case .cancelled:
            return .none
        case .configuration(reason: .offline):
            // Nothing was sent, so waiting for connectivity is safe for any
            // method.
            return .waitForConnectivity
        case .reachability:
            return allowsReplay ? .waitForConnectivity : .doNotRetry
        case .statusCode(let response)
        where response.statusCode == 401
            && (authentication == .optional || authentication == .required):
            return .reauthenticate
        case .authentication(.refreshFailed):
            return .reauthenticate
        case .authentication(.credential(let reason)):
            switch reason {
            case .credentialExpired, .refreshFailed:
                return .reauthenticate
            default:
                return .doNotRetry
            }
        case .configuration,
            .statusCode,
            .decoding,
            .underlying,
            .trustEvaluationFailed,
            .timeout,
            .policyRejected:
            // The single transience rule decides whether a replay can help;
            // replay safety decides whether it is allowed.
            return isTransient && allowsReplay ? .retry : .doNotRetry
        }
    }

    private static func allowsReplay(
        method: HTTPMethod?,
        replaySafety: NetworkOperationReplaySafety
    ) -> Bool {
        switch replaySafety {
        case .methodDefault:
            guard let method else { return false }
            return method == .get || method == .head || method == .options || method == .trace
        case .stableIdempotencyKey:
            return true
        case .never:
            return false
        }
    }
}
