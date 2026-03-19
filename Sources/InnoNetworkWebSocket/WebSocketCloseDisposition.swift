import Foundation


package enum WebSocketCloseDisposition: Sendable, Equatable {
    case manual(URLSessionWebSocketTask.CloseCode)
    case peerNormal(URLSessionWebSocketTask.CloseCode, String?)
    case peerRetryable(URLSessionWebSocketTask.CloseCode, String?)
    case peerTerminal(URLSessionWebSocketTask.CloseCode, String?)
    case handshakeUnauthorized(Int)
    case handshakeForbidden(Int)
    case handshakeServerUnavailable(Int)
    case handshakeTransientNetwork(SendableUnderlyingError)
    case handshakeTerminalHTTP(Int)
    case handshakeTimeout(URLSessionWebSocketTask.CloseCode)
    case transportFailure(WebSocketError)

    var shouldReconnect: Bool {
        switch self {
        case .peerRetryable, .handshakeServerUnavailable, .handshakeTransientNetwork, .transportFailure:
            return true
        case .manual, .peerNormal, .peerTerminal, .handshakeUnauthorized, .handshakeForbidden, .handshakeTerminalHTTP, .handshakeTimeout:
            return false
        }
    }

    static func classifyPeerClose(
        closeCode: URLSessionWebSocketTask.CloseCode,
        reason: String?
    ) -> WebSocketCloseDisposition {
        switch Int(closeCode.rawValue) {
        case 1000:
            return .peerNormal(closeCode, reason)
        case 1001, 1006, 1011, 1012, 1013, 1015:
            return .peerRetryable(closeCode, reason)
        case 1003, 1007, 1008, 1009:
            return .peerTerminal(closeCode, reason)
        default:
            return .peerTerminal(closeCode, reason)
        }
    }

    static func classifyHandshake(
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

    package static func == (lhs: WebSocketCloseDisposition, rhs: WebSocketCloseDisposition) -> Bool {
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
            return l.localizedDescription == r.localizedDescription
        default:
            return false
        }
    }
}
