import Foundation
import InnoNetwork


public struct DownloadConfiguration: Sendable {
    package enum Presets {
        static func safeDefaults() -> DownloadConfiguration {
            DownloadConfiguration(
                maxConnectionsPerHost: 3,
                maxRetryCount: 3,
                maxTotalRetries: 3,
                retryDelay: 1.0,
                timeoutForRequest: 30,
                timeoutForResource: 60 * 60 * 24,
                allowsCellularAccess: true,
                sessionIdentifier: "com.innonetwork.download",
                networkMonitor: NetworkMonitor.shared,
                waitsForNetworkChanges: false,
                networkChangeTimeout: 10.0,
                eventDeliveryPolicy: .default,
                eventMetricsReporter: nil
            )
        }

        static func advancedTuning() -> DownloadConfiguration {
            DownloadConfiguration(
                maxConnectionsPerHost: 6,
                maxRetryCount: 5,
                maxTotalRetries: 8,
                retryDelay: 0.5,
                timeoutForRequest: 60,
                timeoutForResource: 60 * 60 * 24,
                allowsCellularAccess: true,
                sessionIdentifier: "com.innonetwork.download",
                networkMonitor: NetworkMonitor.shared,
                waitsForNetworkChanges: true,
                networkChangeTimeout: 20.0,
                eventDeliveryPolicy: EventDeliveryPolicy(
                    maxBufferedEventsPerPartition: 512,
                    maxBufferedEventsPerConsumer: 512,
                    overflowPolicy: .dropOldest
                ),
                eventMetricsReporter: nil
            )
        }
    }

    public let maxConnectionsPerHost: Int
    public let maxRetryCount: Int
    /// Maximum total retry count even if the counter is reset due to network changes.
    public let maxTotalRetries: Int
    public let retryDelay: TimeInterval
    public let timeoutForRequest: TimeInterval
    public let timeoutForResource: TimeInterval
    public let allowsCellularAccess: Bool
    public let sessionIdentifier: String
    public let networkMonitor: (any NetworkMonitoring)?
    /// When true, waits for network changes before retrying on download failure.
    public let waitsForNetworkChanges: Bool
    public let networkChangeTimeout: TimeInterval?
    public let eventDeliveryPolicy: EventDeliveryPolicy
    public let eventMetricsReporter: (any EventPipelineMetricsReporting)?

    public struct AdvancedBuilder: Sendable {
        public var maxConnectionsPerHost: Int
        public var maxRetryCount: Int
        public var maxTotalRetries: Int
        public var retryDelay: TimeInterval
        public var timeoutForRequest: TimeInterval
        public var timeoutForResource: TimeInterval
        public var allowsCellularAccess: Bool
        public var sessionIdentifier: String
        public var networkMonitor: (any NetworkMonitoring)?
        public var waitsForNetworkChanges: Bool
        public var networkChangeTimeout: TimeInterval?
        public var eventDeliveryPolicy: EventDeliveryPolicy
        public var eventMetricsReporter: (any EventPipelineMetricsReporting)?

        fileprivate init(preset: DownloadConfiguration) {
            self.maxConnectionsPerHost = preset.maxConnectionsPerHost
            self.maxRetryCount = preset.maxRetryCount
            self.maxTotalRetries = preset.maxTotalRetries
            self.retryDelay = preset.retryDelay
            self.timeoutForRequest = preset.timeoutForRequest
            self.timeoutForResource = preset.timeoutForResource
            self.allowsCellularAccess = preset.allowsCellularAccess
            self.sessionIdentifier = preset.sessionIdentifier
            self.networkMonitor = preset.networkMonitor
            self.waitsForNetworkChanges = preset.waitsForNetworkChanges
            self.networkChangeTimeout = preset.networkChangeTimeout
            self.eventDeliveryPolicy = preset.eventDeliveryPolicy
            self.eventMetricsReporter = preset.eventMetricsReporter
        }

        fileprivate func build() -> DownloadConfiguration {
            DownloadConfiguration(
                maxConnectionsPerHost: maxConnectionsPerHost,
                maxRetryCount: maxRetryCount,
                maxTotalRetries: maxTotalRetries,
                retryDelay: retryDelay,
                timeoutForRequest: timeoutForRequest,
                timeoutForResource: timeoutForResource,
                allowsCellularAccess: allowsCellularAccess,
                sessionIdentifier: sessionIdentifier,
                networkMonitor: networkMonitor,
                waitsForNetworkChanges: waitsForNetworkChanges,
                networkChangeTimeout: networkChangeTimeout,
                eventDeliveryPolicy: eventDeliveryPolicy,
                eventMetricsReporter: eventMetricsReporter
            )
        }
    }

    public static func safeDefaults() -> DownloadConfiguration {
        Presets.safeDefaults()
    }

    public static func advanced(_ configure: (inout AdvancedBuilder) -> Void) -> DownloadConfiguration {
        var builder = AdvancedBuilder(preset: Presets.advancedTuning())
        configure(&builder)
        return builder.build()
    }

    public init(
        maxConnectionsPerHost: Int = 3,
        maxRetryCount: Int = 3,
        maxTotalRetries: Int = 3,
        retryDelay: TimeInterval = 1.0,
        timeoutForRequest: TimeInterval = 30,
        timeoutForResource: TimeInterval = 60 * 60 * 24,
        allowsCellularAccess: Bool = true,
        sessionIdentifier: String = "com.innonetwork.download",
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared,
        waitsForNetworkChanges: Bool = false,
        networkChangeTimeout: TimeInterval? = 10.0,
        eventDeliveryPolicy: EventDeliveryPolicy = .default,
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil
    ) {
        self.maxConnectionsPerHost = max(1, maxConnectionsPerHost)
        self.maxRetryCount = max(0, maxRetryCount)
        self.maxTotalRetries = max(0, maxTotalRetries)
        self.retryDelay = max(0, retryDelay)
        self.timeoutForRequest = max(0, timeoutForRequest)
        self.timeoutForResource = max(0, timeoutForResource)
        self.allowsCellularAccess = allowsCellularAccess
        self.sessionIdentifier = sessionIdentifier
        self.networkMonitor = networkMonitor
        self.waitsForNetworkChanges = waitsForNetworkChanges
        self.networkChangeTimeout = networkChangeTimeout.map { max(0, $0) }
        self.eventDeliveryPolicy = eventDeliveryPolicy
        self.eventMetricsReporter = eventMetricsReporter
    }
    
    public static let `default` = safeDefaults()
    
    func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = allowsCellularAccess
        config.timeoutIntervalForRequest = timeoutForRequest
        config.timeoutIntervalForResource = timeoutForResource
        config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        return config
    }
}
