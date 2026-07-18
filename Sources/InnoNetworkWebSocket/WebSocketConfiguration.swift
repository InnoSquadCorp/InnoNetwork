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


/// Async, throwing hook applied to every WebSocket handshake request before the
/// underlying `URLSessionWebSocketTask` is created.
///
/// Use this when a reconnect attempt must fetch fresh authentication headers
/// or rotate per-connection metadata. Static
/// ``WebSocketConfiguration/requestHeaders`` are applied first, then
/// subprotocol headers, then adapters in array order.
public struct WebSocketHandshakeRequestAdapter: Sendable {
    private let adaptRequest: @Sendable (URLRequest) async throws -> URLRequest

    public init(_ adaptRequest: @escaping @Sendable (URLRequest) async throws -> URLRequest) {
        self.adaptRequest = adaptRequest
    }

    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        try await adaptRequest(request)
    }
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
                reconnectMaxTotalDuration: 0,
                allowsCellularAccess: true,
                allowsInsecureWebSocket: false,
                requestHeaders: [:],
                handshakeRequestAdapters: [],
                eventDeliveryPolicy: .default,
                eventMetricsReporter: nil,
                sendQueueLimit: 256,
                sendQueueOverflowPolicy: .fail,
                closeHandshakeTimeout: .seconds(3),
                maximumMessageSize: 1 * 1024 * 1024,
                permessageDeflateEnabled: false
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
                reconnectMaxTotalDuration: 0,
                allowsCellularAccess: true,
                allowsInsecureWebSocket: false,
                requestHeaders: [:],
                handshakeRequestAdapters: [],
                eventDeliveryPolicy: EventDeliveryPolicy(
                    maxBufferedEventsPerPartition: 512,
                    maxBufferedEventsPerConsumer: 512,
                    overflowPolicy: .dropOldest
                ),
                eventMetricsReporter: nil,
                sendQueueLimit: 512,
                sendQueueOverflowPolicy: .fail,
                closeHandshakeTimeout: .seconds(3),
                maximumMessageSize: 1 * 1024 * 1024,
                permessageDeflateEnabled: false
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
    /// Optional cumulative wall-clock budget in seconds covering all reconnect
    /// attempts within a single disconnect window. The reconnect coordinator
    /// stamps the first attempt and refuses further retries once `now` exceeds
    /// the budget, classifying the result as `.exceeded`.
    /// Successful reconnects clear the window, so flapping over many days does
    /// not consume the budget linearly.
    ///
    /// - `> 0`: budget enforced.
    /// - `<= 0`: unlimited (default — preserves legacy behaviour).
    ///
    /// Negative values are clamped to `0` (disabled).
    public let reconnectMaxTotalDuration: TimeInterval
    /// Whether cellular data is allowed for socket connections.
    public let allowsCellularAccess: Bool
    /// Allows plain `ws` connections. Defaults to `false`; production
    /// sockets should use WSS.
    public let allowsInsecureWebSocket: Bool
    /// Additional HTTP headers sent when establishing the WebSocket handshake.
    public let requestHeaders: [String: String]
    /// Async, throwing request adapters applied after static headers and
    /// subprotocol negotiation headers, before creating each
    /// `URLSessionWebSocketTask`. A thrown error is surfaced through the task's
    /// normal connection-failure lifecycle and may participate in automatic
    /// reconnect according to the configured retry budget.
    public let handshakeRequestAdapters: [WebSocketHandshakeRequestAdapter]
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

    /// Maximum time the manager waits for the WebSocket close handshake to
    /// complete after `cancel(with:reason:)` is issued. When the timer fires
    /// without an upstream `didClose` delegate callback, the manager
    /// finalizes the disconnect with the requested close code so the task
    /// does not stay wedged in `.disconnecting`.
    ///
    /// Default is `.seconds(3)`. Negative values are clamped to `.zero`,
    /// which effectively short-circuits the handshake wait.
    public let closeHandshakeTimeout: Duration

    /// Maximum payload size in bytes that the underlying
    /// `URLSessionWebSocketTask` will buffer for a single inbound message
    /// before failing the receive. Applied after the task is created. The
    /// platform default is 1 MiB; values lower than `1` are clamped to `1`.
    public let maximumMessageSize: Int

    /// Configuration intent for `permessage-deflate`.
    ///
    /// `URLSessionWebSocketTask` does not advertise `permessage-deflate`.
    /// When this flag is `true` on the built-in URLSession transport,
    /// ``WebSocketManager`` fails the connection with
    /// ``WebSocketError/unsupportedProtocolFeature(_:)`` instead of opening
    /// a silently uncompressed socket. Optional transports may honour the
    /// flag. See `<doc:WebSocketProtocolPolicy>` for migration notes.
    public let permessageDeflateEnabled: Bool

    /// Internal builder used by the pack-based `advanced(...)` factory.
    package struct AdvancedBuilder: Sendable {
        package var maxConnectionsPerHost: Int
        package var connectionTimeout: TimeInterval
        package var heartbeatInterval: TimeInterval
        package var pongTimeout: TimeInterval
        package var maxMissedPongs: Int
        package var reconnectDelay: TimeInterval
        package var reconnectJitterRatio: Double
        package var maxReconnectDelay: TimeInterval
        package var maxReconnectAttempts: Int
        /// Cumulative reconnect-window budget in seconds. See
        /// ``WebSocketConfiguration/reconnectMaxTotalDuration``.
        package var reconnectMaxTotalDuration: TimeInterval
        package var allowsCellularAccess: Bool
        /// Allows plain `ws` connections. Defaults to `false`.
        package var allowsInsecureWebSocket: Bool
        package var requestHeaders: [String: String]
        package var handshakeRequestAdapters: [WebSocketHandshakeRequestAdapter]
        package var eventDeliveryPolicy: EventDeliveryPolicy
        package var eventMetricsReporter: (any EventPipelineMetricsReporting)?
        package var sendQueueLimit: Int
        package var sendQueueOverflowPolicy: WebSocketSendOverflowPolicy
        /// Maximum time the manager waits for the WebSocket close handshake
        /// to complete after `cancel(with:reason:)` is issued before
        /// finalizing the disconnect locally. Negative values are clamped to
        /// `.zero` when the configuration is built. See
        /// ``WebSocketConfiguration/closeHandshakeTimeout`` for full
        /// semantics.
        package var closeHandshakeTimeout: Duration
        /// See ``WebSocketConfiguration/maximumMessageSize``.
        package var maximumMessageSize: Int
        /// See ``WebSocketConfiguration/permessageDeflateEnabled``.
        package var permessageDeflateEnabled: Bool

        package init(preset: WebSocketConfiguration) {
            self.maxConnectionsPerHost = preset.maxConnectionsPerHost
            self.connectionTimeout = preset.connectionTimeout
            self.heartbeatInterval = preset.heartbeatInterval
            self.pongTimeout = preset.pongTimeout
            self.maxMissedPongs = preset.maxMissedPongs
            self.reconnectDelay = preset.reconnectDelay
            self.reconnectJitterRatio = preset.reconnectJitterRatio
            self.maxReconnectDelay = preset.maxReconnectDelay
            self.maxReconnectAttempts = preset.maxReconnectAttempts
            self.reconnectMaxTotalDuration = preset.reconnectMaxTotalDuration
            self.allowsCellularAccess = preset.allowsCellularAccess
            self.allowsInsecureWebSocket = preset.allowsInsecureWebSocket
            self.requestHeaders = preset.requestHeaders
            self.handshakeRequestAdapters = preset.handshakeRequestAdapters
            self.eventDeliveryPolicy = preset.eventDeliveryPolicy
            self.eventMetricsReporter = preset.eventMetricsReporter
            self.sendQueueLimit = preset.sendQueueLimit
            self.sendQueueOverflowPolicy = preset.sendQueueOverflowPolicy
            self.closeHandshakeTimeout = preset.closeHandshakeTimeout
            self.maximumMessageSize = preset.maximumMessageSize
            self.permessageDeflateEnabled = preset.permessageDeflateEnabled
        }

        package func build() -> WebSocketConfiguration {
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
                reconnectMaxTotalDuration: reconnectMaxTotalDuration,
                allowsCellularAccess: allowsCellularAccess,
                allowsInsecureWebSocket: allowsInsecureWebSocket,
                requestHeaders: requestHeaders,
                handshakeRequestAdapters: handshakeRequestAdapters,
                eventDeliveryPolicy: eventDeliveryPolicy,
                eventMetricsReporter: eventMetricsReporter,
                sendQueueLimit: sendQueueLimit,
                sendQueueOverflowPolicy: sendQueueOverflowPolicy,
                closeHandshakeTimeout: closeHandshakeTimeout,
                maximumMessageSize: maximumMessageSize,
                permessageDeflateEnabled: permessageDeflateEnabled
            )
        }
    }

    public static func safeDefaults() -> WebSocketConfiguration {
        Presets.safeDefaults()
    }

    /// Composes an advanced configuration from explicit thematic packs.
    /// Omitted packs preserve the documented high-tuning preset.
    public static func advanced(
        connection: WebSocketConnectionPack = WebSocketConnectionPack(),
        liveness: WebSocketLivenessPack = WebSocketLivenessPack(),
        reconnect: WebSocketReconnectPack = WebSocketReconnectPack(),
        messaging: WebSocketMessagingPack = WebSocketMessagingPack(),
        observability: WebSocketObservabilityPack = WebSocketObservabilityPack()
    ) -> WebSocketConfiguration {
        var builder = AdvancedBuilder(preset: Presets.advancedTuning())
        connection.apply(to: &builder)
        liveness.apply(to: &builder)
        reconnect.apply(to: &builder)
        messaging.apply(to: &builder)
        observability.apply(to: &builder)
        return builder.build()
    }

    package init(
        maxConnectionsPerHost: Int = 5,
        connectionTimeout: TimeInterval = 30,
        heartbeatInterval: TimeInterval = 30,
        pongTimeout: TimeInterval = 10,
        maxMissedPongs: Int = 1,
        reconnectDelay: TimeInterval = 1.0,
        reconnectJitterRatio: Double = 0.2,
        maxReconnectDelay: TimeInterval = 0,
        maxReconnectAttempts: Int = 5,
        reconnectMaxTotalDuration: TimeInterval = 0,
        allowsCellularAccess: Bool = true,
        allowsInsecureWebSocket: Bool = false,
        requestHeaders: [String: String] = [:],
        handshakeRequestAdapters: [WebSocketHandshakeRequestAdapter] = [],
        eventDeliveryPolicy: EventDeliveryPolicy = .default,
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil,
        sendQueueLimit: Int = 256,
        sendQueueOverflowPolicy: WebSocketSendOverflowPolicy = .fail,
        closeHandshakeTimeout: Duration = .seconds(3),
        maximumMessageSize: Int = 1 * 1024 * 1024,
        permessageDeflateEnabled: Bool = false
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
        self.reconnectMaxTotalDuration = max(0, reconnectMaxTotalDuration)
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsInsecureWebSocket = allowsInsecureWebSocket
        self.requestHeaders = requestHeaders
        self.handshakeRequestAdapters = handshakeRequestAdapters
        self.eventDeliveryPolicy = eventDeliveryPolicy
        self.eventMetricsReporter = eventMetricsReporter
        self.sendQueueLimit = max(1, sendQueueLimit)
        self.sendQueueOverflowPolicy = sendQueueOverflowPolicy
        self.closeHandshakeTimeout = closeHandshakeTimeout < .zero ? .zero : closeHandshakeTimeout
        self.maximumMessageSize = max(1, maximumMessageSize)
        self.permessageDeflateEnabled = permessageDeflateEnabled
    }

    func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = connectionTimeout
        config.allowsCellularAccess = allowsCellularAccess
        config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        return config
    }
}
