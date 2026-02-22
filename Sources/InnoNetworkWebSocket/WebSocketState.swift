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


public enum WebSocketError: Error, Sendable {
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
