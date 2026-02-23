import Foundation


public struct WebSocketConfiguration: Sendable {
    public let maxConcurrentConnections: Int
    public let connectionTimeout: TimeInterval
    public let heartbeatInterval: TimeInterval
    public let pongTimeout: TimeInterval
    public let maxMissedPongs: Int
    public let reconnectDelay: TimeInterval
    public let reconnectJitterRatio: Double
    /// Number of reconnect retries after the initial connection attempt.
    /// Total connection attempts are `1 + maxReconnectAttempts`.
    public let maxReconnectAttempts: Int
    public let allowsCellularAccess: Bool
    /// Reserved for API compatibility with managers that support background sessions.
    /// WebSocketManager currently uses a default URLSession configuration.
    public let sessionIdentifier: String
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
