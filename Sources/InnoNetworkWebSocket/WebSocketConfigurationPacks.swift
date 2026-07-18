import Foundation
import InnoNetwork

/// Groups handshake transport, headers, adapters, and network access policy.
public struct WebSocketConnectionPack: Sendable {
    private let maxConnectionsPerHost: Int
    private let connectionTimeout: TimeInterval
    private let allowsCellularAccess: Bool
    private let allowsInsecureWebSocket: Bool
    private let requestHeaders: [String: String]
    private let handshakeRequestAdapters: [WebSocketHandshakeRequestAdapter]

    public init(
        maxConnectionsPerHost: Int = 8,
        connectionTimeout: TimeInterval = 45,
        allowsCellularAccess: Bool = true,
        allowsInsecureWebSocket: Bool = false,
        requestHeaders: [String: String] = [:],
        handshakeRequestAdapters: [WebSocketHandshakeRequestAdapter] = []
    ) {
        self.maxConnectionsPerHost = maxConnectionsPerHost
        self.connectionTimeout = connectionTimeout
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsInsecureWebSocket = allowsInsecureWebSocket
        self.requestHeaders = requestHeaders
        self.handshakeRequestAdapters = handshakeRequestAdapters
    }

    package func apply(to builder: inout WebSocketConfiguration.AdvancedBuilder) {
        builder.maxConnectionsPerHost = maxConnectionsPerHost
        builder.connectionTimeout = connectionTimeout
        builder.allowsCellularAccess = allowsCellularAccess
        builder.allowsInsecureWebSocket = allowsInsecureWebSocket
        builder.requestHeaders = requestHeaders
        builder.handshakeRequestAdapters = handshakeRequestAdapters
    }
}

/// Groups heartbeat and close-handshake liveness policy.
public struct WebSocketLivenessPack: Sendable {
    private let heartbeatInterval: TimeInterval
    private let pongTimeout: TimeInterval
    private let maxMissedPongs: Int
    private let closeHandshakeTimeout: Duration

    public init(
        heartbeatInterval: TimeInterval = 15,
        pongTimeout: TimeInterval = 5,
        maxMissedPongs: Int = 2,
        closeHandshakeTimeout: Duration = .seconds(3)
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.pongTimeout = pongTimeout
        self.maxMissedPongs = maxMissedPongs
        self.closeHandshakeTimeout = closeHandshakeTimeout
    }

    package func apply(to builder: inout WebSocketConfiguration.AdvancedBuilder) {
        builder.heartbeatInterval = heartbeatInterval
        builder.pongTimeout = pongTimeout
        builder.maxMissedPongs = maxMissedPongs
        builder.closeHandshakeTimeout = closeHandshakeTimeout
    }
}

/// Groups reconnect attempts, backoff, jitter, and total-window budgeting.
public struct WebSocketReconnectPack: Sendable {
    private let delay: TimeInterval
    private let jitterRatio: Double
    private let maxDelay: TimeInterval
    private let maxAttempts: Int
    private let maxTotalDuration: TimeInterval

    public init(
        delay: TimeInterval = 0.5,
        jitterRatio: Double = 0.1,
        maxDelay: TimeInterval = 0,
        maxAttempts: Int = 8,
        maxTotalDuration: TimeInterval = 0
    ) {
        self.delay = delay
        self.jitterRatio = jitterRatio
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
        self.maxTotalDuration = maxTotalDuration
    }

    package func apply(to builder: inout WebSocketConfiguration.AdvancedBuilder) {
        builder.reconnectDelay = delay
        builder.reconnectJitterRatio = jitterRatio
        builder.maxReconnectDelay = maxDelay
        builder.maxReconnectAttempts = maxAttempts
        builder.reconnectMaxTotalDuration = maxTotalDuration
    }
}

/// Groups outbound back-pressure and inbound protocol limits.
public struct WebSocketMessagingPack: Sendable {
    private let sendQueueLimit: Int
    private let sendQueueOverflowPolicy: WebSocketSendOverflowPolicy
    private let maximumMessageSize: Int
    private let permessageDeflateEnabled: Bool

    public init(
        sendQueueLimit: Int = 512,
        sendQueueOverflowPolicy: WebSocketSendOverflowPolicy = .fail,
        maximumMessageSize: Int = 1 * 1024 * 1024,
        permessageDeflateEnabled: Bool = false
    ) {
        self.sendQueueLimit = sendQueueLimit
        self.sendQueueOverflowPolicy = sendQueueOverflowPolicy
        self.maximumMessageSize = maximumMessageSize
        self.permessageDeflateEnabled = permessageDeflateEnabled
    }

    package func apply(to builder: inout WebSocketConfiguration.AdvancedBuilder) {
        builder.sendQueueLimit = sendQueueLimit
        builder.sendQueueOverflowPolicy = sendQueueOverflowPolicy
        builder.maximumMessageSize = maximumMessageSize
        builder.permessageDeflateEnabled = permessageDeflateEnabled
    }
}

/// Groups event buffering and event-pipeline metrics.
public struct WebSocketObservabilityPack: Sendable {
    private let eventDeliveryPolicy: EventDeliveryPolicy
    private let eventMetricsReporter: (any EventPipelineMetricsReporting)?

    public init(
        eventDeliveryPolicy: EventDeliveryPolicy = EventDeliveryPolicy(
            maxBufferedEventsPerPartition: 512,
            maxBufferedEventsPerConsumer: 512,
            overflowPolicy: .dropOldest
        ),
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil
    ) {
        self.eventDeliveryPolicy = eventDeliveryPolicy
        self.eventMetricsReporter = eventMetricsReporter
    }

    package func apply(to builder: inout WebSocketConfiguration.AdvancedBuilder) {
        builder.eventDeliveryPolicy = eventDeliveryPolicy
        builder.eventMetricsReporter = eventMetricsReporter
    }
}
