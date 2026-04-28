import Foundation

/// Policy applied when a per-task send is dispatched while the task already
/// has ``WebSocketConfiguration/sendQueueLimit`` operations in flight.
public enum WebSocketSendOverflowPolicy: Sendable, Equatable {
    /// The send fails with ``WebSocketError/sendQueueOverflow``. The caller
    /// keeps the message and decides whether to retry, drop, or surface to
    /// the user.
    case fail

    /// The send is dropped silently (well — observably; an
    /// `WebSocketEvent.sendDropped` event is published) without throwing.
    /// Use this for fire-and-forget telemetry where back-pressure is
    /// acceptable but blocking the caller is not.
    case dropNewest
}


public struct WebSocketConfiguration: Sendable {
    package enum Presets {
        static func safeDefaults() -> WebSocketConfiguration {
            WebSocketConfiguration(
                maxConnectionsPerHost: 5,
                connectionTimeout: 30,
                heartbeatInterval: 30,
                pongTimeout: 10,
                maxMissedPongs: 1,
                reconnectDelay: 1.0,
                reconnectJitterRatio: 0.2,
                maxReconnectDelay: 0,
                maxReconnectAttempts: 5,
                allowsCellularAccess: true,
                sessionIdentifier: "com.innonetwork.websocket",
                requestHeaders: [:],
                eventDeliveryPolicy: .default,
                eventMetricsReporter: nil,
                sendQueueLimit: 256,
                sendQueueOverflowPolicy: .fail
            )
        }

        static func advancedTuning() -> WebSocketConfiguration {
            WebSocketConfiguration(
                maxConnectionsPerHost: 8,
                connectionTimeout: 45,
                heartbeatInterval: 15,
                pongTimeout: 5,
                maxMissedPongs: 2,
                reconnectDelay: 0.5,
                reconnectJitterRatio: 0.1,
                maxReconnectDelay: 0,
                maxReconnectAttempts: 8,
                allowsCellularAccess: true,
                sessionIdentifier: "com.innonetwork.websocket",
                requestHeaders: [:],
                eventDeliveryPolicy: EventDeliveryPolicy(
                    maxBufferedEventsPerPartition: 512,
                    maxBufferedEventsPerConsumer: 512,
                    overflowPolicy: .dropOldest
                ),
                eventMetricsReporter: nil,
                sendQueueLimit: 512,
                sendQueueOverflowPolicy: .fail
            )
        }
    }

    /// Maximum number of concurrent socket connections per host.
    /// Values lower than `1` are clamped to `1`.
    public let maxConnectionsPerHost: Int
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
    /// Optional upper bound in seconds on the exponential-backoff reconnect
    /// delay. When enabled, the randomized delay is sampled from a bounded
    /// range derived from the capped base so it never exceeds the ceiling.
    ///
    /// - `> 0`: cap enabled.
    /// - `<= 0`: cap disabled — the reconnect backoff remains unbounded.
    ///
    /// Negative values are clamped to `0` (cap disabled).
    public let maxReconnectDelay: TimeInterval
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
    public let eventDeliveryPolicy: EventDeliveryPolicy
    public let eventMetricsReporter: (any EventPipelineMetricsReporting)?

    /// Maximum number of concurrent `send(_:message:)` / `send(_:string:)`
    /// operations allowed per task. Operations beyond this limit are
    /// rejected or dropped per ``sendQueueOverflowPolicy``.
    /// Values lower than `1` are clamped to `1`. Default is `256`.
    public let sendQueueLimit: Int

    /// Behaviour when ``sendQueueLimit`` is exceeded for a task. Default is
    /// ``WebSocketSendOverflowPolicy/fail``.
    public let sendQueueOverflowPolicy: WebSocketSendOverflowPolicy

    public struct AdvancedBuilder: Sendable {
        public var maxConnectionsPerHost: Int
        public var connectionTimeout: TimeInterval
        public var heartbeatInterval: TimeInterval
        public var pongTimeout: TimeInterval
        public var maxMissedPongs: Int
        public var reconnectDelay: TimeInterval
        public var reconnectJitterRatio: Double
        public var maxReconnectDelay: TimeInterval
        public var maxReconnectAttempts: Int
        public var allowsCellularAccess: Bool
        public var sessionIdentifier: String
        public var requestHeaders: [String: String]
        public var eventDeliveryPolicy: EventDeliveryPolicy
        public var eventMetricsReporter: (any EventPipelineMetricsReporting)?
        public var sendQueueLimit: Int
        public var sendQueueOverflowPolicy: WebSocketSendOverflowPolicy

        fileprivate init(preset: WebSocketConfiguration) {
            self.maxConnectionsPerHost = preset.maxConnectionsPerHost
            self.connectionTimeout = preset.connectionTimeout
            self.heartbeatInterval = preset.heartbeatInterval
            self.pongTimeout = preset.pongTimeout
            self.maxMissedPongs = preset.maxMissedPongs
            self.reconnectDelay = preset.reconnectDelay
            self.reconnectJitterRatio = preset.reconnectJitterRatio
            self.maxReconnectDelay = preset.maxReconnectDelay
            self.maxReconnectAttempts = preset.maxReconnectAttempts
            self.allowsCellularAccess = preset.allowsCellularAccess
            self.sessionIdentifier = preset.sessionIdentifier
            self.requestHeaders = preset.requestHeaders
            self.eventDeliveryPolicy = preset.eventDeliveryPolicy
            self.eventMetricsReporter = preset.eventMetricsReporter
            self.sendQueueLimit = preset.sendQueueLimit
            self.sendQueueOverflowPolicy = preset.sendQueueOverflowPolicy
        }

        fileprivate func build() -> WebSocketConfiguration {
            WebSocketConfiguration(
                maxConnectionsPerHost: maxConnectionsPerHost,
                connectionTimeout: connectionTimeout,
                heartbeatInterval: heartbeatInterval,
                pongTimeout: pongTimeout,
                maxMissedPongs: maxMissedPongs,
                reconnectDelay: reconnectDelay,
                reconnectJitterRatio: reconnectJitterRatio,
                maxReconnectDelay: maxReconnectDelay,
                maxReconnectAttempts: maxReconnectAttempts,
                allowsCellularAccess: allowsCellularAccess,
                sessionIdentifier: sessionIdentifier,
                requestHeaders: requestHeaders,
                eventDeliveryPolicy: eventDeliveryPolicy,
                eventMetricsReporter: eventMetricsReporter,
                sendQueueLimit: sendQueueLimit,
                sendQueueOverflowPolicy: sendQueueOverflowPolicy
            )
        }
    }

    public static func safeDefaults() -> WebSocketConfiguration {
        Presets.safeDefaults()
    }

    public static func advanced(_ configure: (inout AdvancedBuilder) -> Void) -> WebSocketConfiguration {
        var builder = AdvancedBuilder(preset: Presets.advancedTuning())
        configure(&builder)
        return builder.build()
    }

    public init(
        maxConnectionsPerHost: Int = 5,
        connectionTimeout: TimeInterval = 30,
        heartbeatInterval: TimeInterval = 30,
        pongTimeout: TimeInterval = 10,
        maxMissedPongs: Int = 1,
        reconnectDelay: TimeInterval = 1.0,
        reconnectJitterRatio: Double = 0.2,
        maxReconnectDelay: TimeInterval = 0,
        maxReconnectAttempts: Int = 5,
        allowsCellularAccess: Bool = true,
        sessionIdentifier: String = "com.innonetwork.websocket",
        requestHeaders: [String: String] = [:],
        eventDeliveryPolicy: EventDeliveryPolicy = .default,
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil,
        sendQueueLimit: Int = 256,
        sendQueueOverflowPolicy: WebSocketSendOverflowPolicy = .fail
    ) {
        self.maxConnectionsPerHost = max(1, maxConnectionsPerHost)
        self.connectionTimeout = max(0, connectionTimeout)
        self.heartbeatInterval = max(0, heartbeatInterval)
        self.pongTimeout = max(0, pongTimeout)
        self.maxMissedPongs = max(1, maxMissedPongs)
        self.reconnectDelay = max(0, reconnectDelay)
        self.reconnectJitterRatio = min(1.0, max(0.0, reconnectJitterRatio))
        self.maxReconnectDelay = max(0, maxReconnectDelay)
        self.maxReconnectAttempts = max(0, maxReconnectAttempts)
        self.allowsCellularAccess = allowsCellularAccess
        self.sessionIdentifier = sessionIdentifier
        self.requestHeaders = requestHeaders
        self.eventDeliveryPolicy = eventDeliveryPolicy
        self.eventMetricsReporter = eventMetricsReporter
        self.sendQueueLimit = max(1, sendQueueLimit)
        self.sendQueueOverflowPolicy = sendQueueOverflowPolicy
    }

    public static let `default` = safeDefaults()

    func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = connectionTimeout
        config.allowsCellularAccess = allowsCellularAccess
        config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        return config
    }
}
