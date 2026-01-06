import Foundation


public struct WebSocketConfiguration: Sendable {
    public let maxConcurrentConnections: Int
    public let connectionTimeout: TimeInterval
    public let pingInterval: TimeInterval
    public let pingTimeout: TimeInterval
    public let reconnectDelay: TimeInterval
    public let maxReconnectAttempts: Int
    public let allowsCellularAccess: Bool
    public let sessionIdentifier: String
    public let requestHeaders: [String: String]

    public init(
        maxConcurrentConnections: Int = 5,
        connectionTimeout: TimeInterval = 30,
        pingInterval: TimeInterval = 30,
        pingTimeout: TimeInterval = 10,
        reconnectDelay: TimeInterval = 1.0,
        maxReconnectAttempts: Int = 5,
        allowsCellularAccess: Bool = true,
        sessionIdentifier: String = "com.innonetwork.websocket",
        requestHeaders: [String: String] = [:]
    ) {
        self.maxConcurrentConnections = maxConcurrentConnections
        self.connectionTimeout = connectionTimeout
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        self.reconnectDelay = reconnectDelay
        self.maxReconnectAttempts = maxReconnectAttempts
        self.allowsCellularAccess = allowsCellularAccess
        self.sessionIdentifier = sessionIdentifier
        self.requestHeaders = requestHeaders
    }

    public static let `default` = WebSocketConfiguration()

    func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = connectionTimeout
        config.timeoutIntervalForResource = pingInterval + pingTimeout
        config.allowsCellularAccess = allowsCellularAccess
        config.httpMaximumConnectionsPerHost = maxConcurrentConnections
        return config
    }
}
