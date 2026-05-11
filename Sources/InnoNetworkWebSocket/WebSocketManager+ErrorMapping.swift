import Foundation
import InnoNetwork

// Split out of `WebSocketManager.swift` so the disposition →
// `WebSocketError` factories, the manual-disconnect / manager-shutdown
// canned errors, and the static reconnect predicates live in one place.
// All methods stay either actor-isolated or `static`; this file only
// relocates code, no behaviour changes.
extension WebSocketManager {

    func makeDisconnectedError(closeDisposition: WebSocketCloseDisposition) -> WebSocketError {
        switch closeDisposition {
        case .manual(let closeCode):
            return makeManualDisconnectError(closeCode: closeCode)
        case .peerNormal(let closeCode, let reason),
            .peerRetryable(let closeCode, let reason),
            .peerProtocolFailure(let closeCode, let reason),
            .peerApplicationFailure(let closeCode, let reason),
            .peerTerminal(let closeCode, let reason):
            guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .disconnected(nil)
            }
            return .disconnected(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.CloseReason",
                    code: Int(closeCode.rawValue),
                    message: reason
                )
            )
        case .handshakeTimeout(let closeCode):
            return .disconnected(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.HandshakeTimeout",
                    code: Int(closeCode.rawValue),
                    message: "WebSocket close handshake timed out."
                )
            )
        case .handshakeUnauthorized,
            .handshakeForbidden,
            .handshakeServerUnavailable,
            .handshakeTransientNetwork,
            .handshakeTerminalHTTP:
            return makeFailureError(closeDisposition: closeDisposition)
        case .transportFailure(let error):
            return error
        }
    }

    func makeFailureError(closeDisposition: WebSocketCloseDisposition) -> WebSocketError {
        switch closeDisposition {
        case .manual,
            .peerNormal,
            .peerRetryable,
            .peerProtocolFailure,
            .peerApplicationFailure,
            .peerTerminal,
            .handshakeTimeout:
            return makeDisconnectedError(closeDisposition: closeDisposition)
        case .handshakeUnauthorized(let statusCode):
            return .connectionFailed(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.Handshake",
                    code: statusCode,
                    message: "WebSocket handshake failed with unauthorized response."
                )
            )
        case .handshakeForbidden(let statusCode):
            return .connectionFailed(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.Handshake",
                    code: statusCode,
                    message: "WebSocket handshake failed with forbidden response."
                )
            )
        case .handshakeServerUnavailable(let statusCode):
            return .connectionFailed(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.Handshake",
                    code: statusCode,
                    message: "WebSocket handshake failed with retryable server response."
                )
            )
        case .handshakeTransientNetwork(let error):
            return .connectionFailed(error)
        case .handshakeTerminalHTTP(let statusCode):
            return .connectionFailed(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.Handshake",
                    code: statusCode,
                    message: "WebSocket handshake failed with terminal HTTP response."
                )
            )
        case .transportFailure(let error):
            return error
        }
    }

    func makeManualDisconnectError(closeCode: WebSocketCloseCode) -> WebSocketError {
        .disconnected(
            SendableUnderlyingError(
                domain: "InnoNetworkWebSocket.ManualDisconnect",
                code: Int(closeCode.rawValue),
                message: "Client initiated disconnect."
            )
        )
    }

    static func managerShutdownError() -> WebSocketError {
        .connectionFailed(
            SendableUnderlyingError(
                domain: "InnoNetworkWebSocket.Manager",
                code: 1,
                message: "WebSocketManager has been shut down."
            )
        )
    }

    static func shouldReconnect(currentState: WebSocketState, autoReconnectEnabled: Bool) -> Bool {
        guard autoReconnectEnabled else { return false }
        switch currentState {
        case .failed, .disconnected, .reconnecting:
            return true
        case .idle, .connecting, .connected, .disconnecting:
            return false
        }
    }

    static func shouldRetryReconnect(after reconnectCount: Int, maxReconnectAttempts: Int) -> Bool {
        reconnectCount <= maxReconnectAttempts
    }
}
