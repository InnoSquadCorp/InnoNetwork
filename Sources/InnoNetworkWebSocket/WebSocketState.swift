import Foundation
import InnoNetwork


public enum WebSocketState: String, Sendable {
    case idle
    case connecting
    case connected
    case disconnecting
    case disconnected
    case reconnecting
    case failed
}

public extension WebSocketState {
    /// Returns all documented next states from the current lifecycle point.
    var nextStates: Set<Self> {
        switch self {
        case .idle:
            [.connecting]
        case .connecting:
            [.connected, .disconnected, .failed, .disconnecting]
        case .connected:
            [.disconnecting, .disconnected, .reconnecting, .failed]
        case .disconnecting:
            [.disconnected]
        case .disconnected:
            [.connecting, .reconnecting, .failed]
        case .reconnecting:
            [.connecting, .connected, .failed, .disconnected]
        case .failed:
            [.idle, .connecting]
        }
    }

    /// Whether the socket is in a terminal state from the manager's perspective.
    var isTerminal: Bool {
        switch self {
        case .disconnected, .failed:
            return true
        case .idle, .connecting, .connected, .disconnecting, .reconnecting:
            return false
        }
    }

    /// Documents the intended connection lifecycle transitions.
    ///
    /// This keeps reconnect and disconnect semantics explicit without turning
    /// the whole networking stack into a generic automata framework.
    func canTransition(to next: Self) -> Bool {
        next == self || nextStates.contains(next)
    }
}


public enum WebSocketError: Error, Sendable, Equatable {
    case invalidURL(String)
    case connectionFailed(SendableUnderlyingError)
    case disconnected(SendableUnderlyingError?)
    case pingTimeout
    case maxReconnectAttemptsExceeded
    case cancelled
    case unknown
}


extension WebSocketError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid WebSocket URL: \(url)"
        case .connectionFailed(let error):
            return "WebSocket connection failed: \(error.message)"
        case .disconnected(let error):
            if let error = error {
                return "WebSocket disconnected with error: \(error.message)"
            }
            return "WebSocket disconnected"
        case .pingTimeout:
            return "WebSocket ping timed out"
        case .maxReconnectAttemptsExceeded:
            return "Maximum reconnect attempts exceeded"
        case .cancelled:
            return "WebSocket connection was cancelled"
        case .unknown:
            return "Unknown WebSocket error occurred"
        }
    }
}
