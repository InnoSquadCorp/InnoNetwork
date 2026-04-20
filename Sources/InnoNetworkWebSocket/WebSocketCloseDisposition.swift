import Foundation
import InnoNetwork


/// Observable classification of how a WebSocket connection terminated. The
/// library classifies every close into one of these cases so the manager can
/// decide whether to reconnect; exposing the enum publicly lets consumers
/// observe that same classification via ``WebSocketTask/closeDisposition``
/// and branch their own UX on it (e.g. surface a "retrying..." state for
/// ``WebSocketCloseDisposition/peerRetryable(_:_:)``).
///
/// The *classification policy* (how a specific close code or status code
/// maps to a case) remains library-owned — the static `classifyPeerClose`
/// and `classifyHandshake` factories stay `package`-scoped. Consumers only
/// read the result, they do not customize the mapping.
///
/// > Note: New cases may be added in minor releases. When switching
/// > exhaustively, prefer `@unknown default` to stay forward compatible.
public enum WebSocketCloseDisposition: Sendable, Equatable {
    /// Client invoked ``WebSocketManager/disconnect(_:closeCode:)`` or
    /// ``WebSocketManager/disconnectAll(closeCode:)``. Reconnect is
    /// disabled for this path.
    case manual(WebSocketCloseCode)
    /// Peer closed normally (1000 Normal Closure). No reconnect.
    case peerNormal(WebSocketCloseCode, String?)
    /// Peer closed with a retryable code (1001 Going Away, 1011 Internal
    /// Server Error, 1012 Service Restart, 1013 Try Again Later, 1014
    /// Bad Gateway, 1015 TLS Handshake Failure, 1006 Abnormal Closure).
    /// Reconnect will be attempted per the configuration's backoff policy.
    case peerRetryable(WebSocketCloseCode, String?)
    /// Peer closed with a terminal code (protocol error, policy violation,
    /// unsupported data, etc.) or a `.custom(_)` library/application code.
    /// No reconnect.
    case peerTerminal(WebSocketCloseCode, String?)
    /// Handshake responded with HTTP 401. Terminal.
    case handshakeUnauthorized(Int)
    /// Handshake responded with HTTP 403. Terminal.
    case handshakeForbidden(Int)
    /// Handshake responded with a retryable server error (429, 500-599).
    /// Reconnect attempted.
    case handshakeServerUnavailable(Int)
    /// Transient network-layer error during handshake (DNS, connection
    /// lost, timeout). Reconnect attempted.
    case handshakeTransientNetwork(SendableUnderlyingError)
    /// Handshake responded with a terminal 4xx status other than 401/403.
    case handshakeTerminalHTTP(Int)
    /// Client initiated a close but the peer never acknowledged within
    /// the handshake timeout. Treated as terminal.
    case handshakeTimeout(WebSocketCloseCode)
    /// A transport-level error surfaced after the handshake completed
    /// (e.g. ping timeout, read error). Reconnect attempted.
    case transportFailure(WebSocketError)

    /// Whether the reconnect coordinator should attempt another connection
    /// after observing this disposition. Mirrors the library's internal
    /// policy.
    public var shouldReconnect: Bool {
        switch self {
        case .peerRetryable, .handshakeServerUnavailable, .handshakeTransientNetwork, .transportFailure:
            return true
        case .manual, .peerNormal, .peerTerminal, .handshakeUnauthorized, .handshakeForbidden, .handshakeTerminalHTTP, .handshakeTimeout:
            return false
        }
    }

    /// Classifies a peer-initiated close using the library's typed close-code
    /// enum. Package-scoped: the classification policy is library-owned.
    /// Consumers observe the result via
    /// ``WebSocketTask/closeDisposition``.
    package static func classifyPeerClose(
        _ code: WebSocketCloseCode,
        reason: String?
    ) -> WebSocketCloseDisposition {
        switch code {
        case .normalClosure:
            return .peerNormal(code, reason)
        case .goingAway,
             .abnormalClosure,
             .internalServerError,
             .serviceRestart,
             .tryAgainLater,
             .badGateway,
             .tlsHandshakeFailure:
            return .peerRetryable(code, reason)
        case .unsupportedData,
             .invalidFramePayloadData,
             .policyViolation,
             .messageTooBig,
             .mandatoryExtensionMissing,
             .protocolError,
             .noStatusReceived,
             .custom:
            return .peerTerminal(code, reason)
        }
    }

    package static func classifyHandshake(
        statusCode: Int?,
        error: SendableUnderlyingError
    ) -> WebSocketCloseDisposition {
        if let statusCode {
            switch statusCode {
            case 401:
                return .handshakeUnauthorized(statusCode)
            case 403:
                return .handshakeForbidden(statusCode)
            case 429, 503, 500...599:
                return .handshakeServerUnavailable(statusCode)
            case 400...499:
                return .handshakeTerminalHTTP(statusCode)
            default:
                return .transportFailure(.connectionFailed(error))
            }
        }

        if isTransientNetworkError(error) {
            return .handshakeTransientNetwork(error)
        }

        return .transportFailure(.connectionFailed(error))
    }

    private static func isTransientNetworkError(_ error: SendableUnderlyingError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }

        switch URLError.Code(rawValue: error.code) {
        case .timedOut,
             .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .resourceUnavailable,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    public static func == (lhs: WebSocketCloseDisposition, rhs: WebSocketCloseDisposition) -> Bool {
        switch (lhs, rhs) {
        case (.manual(let l), .manual(let r)):
            return l == r
        case (.peerNormal(let lc, let lr), .peerNormal(let rc, let rr)):
            return lc == rc && lr == rr
        case (.peerRetryable(let lc, let lr), .peerRetryable(let rc, let rr)):
            return lc == rc && lr == rr
        case (.peerTerminal(let lc, let lr), .peerTerminal(let rc, let rr)):
            return lc == rc && lr == rr
        case (.handshakeUnauthorized(let l), .handshakeUnauthorized(let r)):
            return l == r
        case (.handshakeForbidden(let l), .handshakeForbidden(let r)):
            return l == r
        case (.handshakeServerUnavailable(let l), .handshakeServerUnavailable(let r)):
            return l == r
        case (.handshakeTransientNetwork(let l), .handshakeTransientNetwork(let r)):
            return l == r
        case (.handshakeTerminalHTTP(let l), .handshakeTerminalHTTP(let r)):
            return l == r
        case (.handshakeTimeout(let l), .handshakeTimeout(let r)):
            return l == r
        case (.transportFailure(let l), .transportFailure(let r)):
            return l == r
        default:
            return false
        }
    }
}
