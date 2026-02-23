import Foundation


public struct WebSocketConfiguration: Sendable {
    /// Maximum number of concurrent socket connections per host.
    /// Values lower than `1` are clamped to `1`.
    public let maxConcurrentConnections: Int
    /// Connection timeout in seconds used for initial handshake requests.
    /// Negative values are clamped to `0`.
    public let connectionTimeout: TimeInterval
    /// Heartbeat ping interval in seconds.
    /// Set to `0` to disable heartbeat.
    public let heartbeatInterval: TimeInterval
    /// Maximum time in seconds to wait for each pong response.
    /// Negative values are clamped to `0`.
    public let pongTimeout: TimeInterval
    /// Number of consecutive missed pongs tolerated before declaring ping timeout.
    /// Values lower than `1` are clamped to `1`.
    public let maxMissedPongs: Int
    /// Base reconnect delay in seconds before jitter/backoff is applied.
    /// Negative values are clamped to `0`.
    public let reconnectDelay: TimeInterval
    /// Jitter ratio applied to reconnect delay (`0.0...1.0`).
    /// Values outside the range are clamped.
    public let reconnectJitterRatio: Double
    /// Number of reconnect retries after the initial connection attempt.
    /// Total connection attempts are `1 + maxReconnectAttempts`.
    public let maxReconnectAttempts: Int
    /// Whether cellular data is allowed for socket connections.
    public let allowsCellularAccess: Bool
    /// Reserved for API compatibility with managers that support background sessions.
    /// WebSocketManager currently uses a default URLSession configuration.
    public let sessionIdentifier: String
    /// Additional HTTP headers sent when establishing the WebSocket handshake.
    public let requestHeaders: [String: String]

    public init(
        maxConcurrentConnections: Int = 5,
        connectionTimeout: TimeInterval = 30,
        heartbeatInterval: TimeInterval = 30,
        pongTimeout: TimeInterval = 10,
        maxMissedPongs: Int = 1,
        reconnectDelay: TimeInterval = 1.0,
        reconnectJitterRatio: Double = 0.2,
        maxReconnectAttempts: Int = 5,
        allowsCellularAccess: Bool = true,
        sessionIdentifier: String = "com.innonetwork.websocket",
        requestHeaders: [String: String] = [:]
    ) {
        self.maxConcurrentConnections = max(1, maxConcurrentConnections)
        self.connectionTimeout = max(0, connectionTimeout)
        self.heartbeatInterval = max(0, heartbeatInterval)
        self.pongTimeout = max(0, pongTimeout)
        self.maxMissedPongs = max(1, maxMissedPongs)
        self.reconnectDelay = max(0, reconnectDelay)
        self.reconnectJitterRatio = min(1.0, max(0.0, reconnectJitterRatio))
        self.maxReconnectAttempts = max(0, maxReconnectAttempts)
        self.allowsCellularAccess = allowsCellularAccess
        self.sessionIdentifier = sessionIdentifier
        self.requestHeaders = requestHeaders
    }

    public static let `default` = WebSocketConfiguration()

    func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = connectionTimeout
        config.allowsCellularAccess = allowsCellularAccess
        config.httpMaximumConnectionsPerHost = maxConcurrentConnections
        return config
    }
}
