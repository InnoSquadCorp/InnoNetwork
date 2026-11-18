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
    /// A locally configured policy rejected the exchange: body limit, open
    /// circuit, admission or rate-limit queue, or a non-HTTP response.
    case policy
    /// A session refresh or a request credential failed.
    case authentication
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
        case .policyRejected:
            return .policy
        case .authentication:
            return .authentication
        }
    }

    /// Conservative hint for UI and policy code that needs a retry affordance.
    ///
    /// This does not override ``RetryPolicy``. It only answers whether the
    /// error class is usually transient.
    public var isRetriableHint: Bool {
        isTransient
    }

    /// Whether the error is normally worth surfacing to an end user.
    ///
    /// Request credential failures that report a contract the integrating
    /// code got wrong — invalid requirements, an origin mismatch, a
    /// credential conflict, or an unsupported execution path — are not: the
    /// user cannot act on them.
    public var isUserVisible: Bool {
        switch self {
        case .configuration(reason: .offline):
            return true
        case .configuration(reason: .invalidBaseURL),
            .configuration(reason: .invalidPayload),
            .configuration(reason: .invalidRequest),
            .cancelled:
            return false
        case .authentication(.credential(let failure)):
            return !failure.isIntegrationMistake
        case .statusCode,
            .decoding,
            .underlying,
            .reachability,
            .trustEvaluationFailed,
            .timeout,
            .policyRejected,
            .authentication:
            return true
        }
    }
}

// MARK: - Shared recovery classification

extension NetworkError {
    /// Whether replaying the same request, with nothing else changed, can
    /// plausibly succeed.
    ///
    /// This is the single transience rule of the library. ``isRetriableHint``,
    /// ``ExponentialBackoffRetryPolicy`` and ``NetworkErrorSummary`` all read
    /// it, so a failure cannot be transient for one of them and terminal for
    /// another.
    package var isTransient: Bool {
        switch self {
        case .statusCode(let response):
            response.statusCode == 408
                || response.statusCode == 429
                || (500...599).contains(response.statusCode)
        case .underlying(let error, _):
            !Self.isCancellation(error) && !Self.isDeterministicTransportFailure(error)
        case .reachability, .timeout:
            true
        case .configuration,
            .decoding,
            .trustEvaluationFailed,
            .cancelled,
            .policyRejected,
            .authentication:
            false
        }
    }

    /// `URLError` codes whose outcome replaying the same request cannot
    /// change: App Transport Security blocked it, the URL is malformed or
    /// unsupported, the redirects loop or lead nowhere, the system does not
    /// trust the certificate, the credential was refused, or a local file or
    /// size limit failed. Neither the network nor the host can cure them, so
    /// they are not transient and say nothing about a host's health.
    private static let deterministicTransportCodes: Set<Int> = [
        URLError.Code.appTransportSecurityRequiresSecureConnection.rawValue,
        URLError.Code.badURL.rawValue,
        URLError.Code.unsupportedURL.rawValue,
        URLError.Code.httpTooManyRedirects.rawValue,
        URLError.Code.redirectToNonExistentLocation.rawValue,
        URLError.Code.serverCertificateUntrusted.rawValue,
        URLError.Code.serverCertificateHasBadDate.rawValue,
        URLError.Code.serverCertificateNotYetValid.rawValue,
        URLError.Code.serverCertificateHasUnknownRoot.rawValue,
        URLError.Code.clientCertificateRejected.rawValue,
        URLError.Code.clientCertificateRequired.rawValue,
        URLError.Code.userAuthenticationRequired.rawValue,
        URLError.Code.userCancelledAuthentication.rawValue,
        URLError.Code.fileDoesNotExist.rawValue,
        URLError.Code.fileIsDirectory.rawValue,
        URLError.Code.noPermissionsToReadFile.rawValue,
        URLError.Code.dataLengthExceedsMaximum.rawValue,
    ]

    /// Whether `error` is a transport failure that replaying the same
    /// request cannot cure, as listed in `deterministicTransportCodes`.
    package static func isDeterministicTransportFailure(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && deterministicTransportCodes.contains(error.code)
    }

    /// Whether a locally configured policy rejected the exchange.
    package var isLocalPolicyRejection: Bool {
        if case .policyRejected = self { return true }
        return false
    }

    /// Whether request authentication could not be established.
    package var isAuthenticationFailure: Bool {
        if case .authentication = self { return true }
        return false
    }

    /// Maps a failure of the session refresh operation to the error surfaced
    /// to the caller.
    ///
    /// Only a failure that shows the session itself cannot be renewed becomes
    /// ``NetworkError/authentication(_:)`` with
    /// ``NetworkAuthenticationFailure/refreshFailed(_:)``, whose recovery is
    /// reauthentication: a refresh request the server rejected with a
    /// non-transient status (for example `400 invalid_grant` or `401`) or
    /// with a credential-rejection `URLError` such as
    /// `.userAuthenticationRequired`, a token response that cannot be
    /// decoded, or an application-defined error thrown by the refresh
    /// closure. It is never retried automatically, because replaying the
    /// request cannot repair the session.
    ///
    /// A failure that says nothing about the session keeps its own identity,
    /// because the session may still be valid:
    ///
    /// - cancellation;
    /// - a transient transport or server failure of the refresh request — a
    ///   connectivity failure, a timeout, a `408`, `429` or `5xx` status, or
    ///   an unclassified transport error. The request then follows the
    ///   ordinary retry and recovery rules; a status failure carries the
    ///   refresh endpoint's response;
    /// - a transport failure of the refresh request that a replay cannot
    ///   cure and that does not reject a credential — a server certificate
    ///   the system does not trust, a malformed URL, a redirect loop, or a
    ///   local limit. It is not retried, but signing in again cannot cure it
    ///   either;
    /// - a configuration failure (including an offline device), a local
    ///   policy rejection, a trust evaluation failure, or a failure that is
    ///   already an authentication failure.
    ///
    /// Only errors that come from a transport — a ``NetworkError`` or a
    /// `URLError` — can keep their identity this way. Any other error type is
    /// the refresh closure's own verdict and is reported as a failed refresh.
    package static func sessionRefreshFailed(_ error: any Error) -> NetworkError {
        if let readFailure = error as? SessionTokenReadFailure {
            // No renewal ran: a peer had refreshed and only reading its token
            // failed. Classify it like that read on a first attempt.
            let underlying = readFailure.underlying
            if isCancellation(underlying) { return .cancelled }
            return (underlying as? NetworkError) ?? mapTransportError(underlying)
        }
        if isCancellation(error) {
            return .cancelled
        }
        let mapped = (error as? NetworkError) ?? mapTransportError(error)
        switch mapped {
        case .authentication, .policyRejected, .trustEvaluationFailed, .configuration:
            return mapped
        default:
            break
        }
        if isCredentialNeutralTransportFailure(error) {
            if case .statusCode(let response) = mapped {
                // The response belongs to the token exchange, whose request
                // can carry the refresh token. Keep the status and headers
                // the retry decision reads, never that request.
                return .statusCode(response.droppingRequest())
            }
            return mapped
        }
        return .authentication(
            .refreshFailed(mapped.underlyingError ?? SendableUnderlyingError(error))
        )
    }

    /// Whether `error` is a transport failure that replaying the exchange
    /// can plausibly cure: a connectivity failure, a timeout, a transient
    /// HTTP status, or an unclassified transport error.
    ///
    /// Only a ``NetworkError`` or a `URLError` qualifies. An application
    /// error that ``mapTransportError(_:)`` would wrap as
    /// ``NetworkError/underlying(_:_:)`` is not evidence of a transport
    /// problem, and a `URLError` that reports a rejected credential is never
    /// transient here.
    package static func isTransientTransportFailure(_ error: any Error) -> Bool {
        guard let mapped = transportFailure(error) else { return false }
        if case .underlying(let underlying, _) = mapped, isCredentialRejection(underlying) {
            return false
        }
        return mapped.isTransient || mapped.isConnectivityFailure
    }

    /// Whether `error` is a transport failure that is no verdict on a
    /// credential or a session: a transient one, as
    /// ``isTransientTransportFailure(_:)`` decides, or a `URLError` that a
    /// replay cannot change and that does not report a rejected credential —
    /// a server certificate the system does not trust, a malformed or
    /// unsupported URL, a redirect loop, an App Transport Security block, or
    /// a local file or size limit.
    ///
    /// Credential and refresh paths use this instead of ``isTransient`` to
    /// decide whether a failure says anything about the credential. A
    /// deterministic failure is not retried, but signing in again cannot cure
    /// it either, so it keeps its own classification instead of becoming a
    /// failed renewal or a missing credential.
    package static func isCredentialNeutralTransportFailure(_ error: any Error) -> Bool {
        if isTransientTransportFailure(error) { return true }
        guard case .underlying(let underlying, _)? = transportFailure(error) else { return false }
        return isDeterministicTransportFailure(underlying) && !isCredentialRejection(underlying)
    }

    /// The transport classification `error` carries, or `nil` when it is
    /// neither a ``NetworkError`` nor a `URLError`.
    private static func transportFailure(_ error: any Error) -> NetworkError? {
        if let networkError = error as? NetworkError { return networkError }
        if error is URLError { return mapTransportError(error) }
        return nil
    }

    /// `URLError` codes with which the URL loading system reports that the
    /// server refused the client's credentials. For a refresh or credential
    /// request they mean the credential is invalid, not that the transport
    /// failed.
    private static let credentialRejectionCodes: Set<Int> = [
        URLError.Code.userAuthenticationRequired.rawValue,
        URLError.Code.userCancelledAuthentication.rawValue,
        URLError.Code.clientCertificateRejected.rawValue,
        URLError.Code.clientCertificateRequired.rawValue,
    ]

    private static func isCredentialRejection(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && credentialRejectionCodes.contains(error.code)
    }

    /// Whether this failure means the device currently has no usable route to
    /// the host. Only these failures can be cured by a network path change, so
    /// they are the only ones for which ``RetryPolicy/waitsForNetworkChanges``
    /// defers a retry.
    package var isConnectivityFailure: Bool {
        switch self {
        case .reachability, .configuration(reason: .offline):
            return true
        default:
            return false
        }
    }
}
