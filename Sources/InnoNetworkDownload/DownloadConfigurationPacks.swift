import Foundation
import InnoNetwork

/// Groups connection limits, transfer timeouts, and network access policy for
/// ``DownloadConfiguration/advanced(sessionIdentifier:transfer:retry:observability:persistence:)``.
public struct DownloadTransferPack: Sendable {
    private let maxConnectionsPerHost: Int
    private let timeoutForRequest: TimeInterval
    private let timeoutForResource: TimeInterval
    private let taskInactivityTimeout: Duration?
    private let allowsCellularAccess: Bool
    private let allowsInsecureHTTP: Bool

    public init(
        maxConnectionsPerHost: Int = 6,
        timeoutForRequest: TimeInterval = 60,
        timeoutForResource: TimeInterval = 60 * 60 * 24,
        taskInactivityTimeout: Duration? = nil,
        allowsCellularAccess: Bool = false,
        allowsInsecureHTTP: Bool = false
    ) {
        self.maxConnectionsPerHost = maxConnectionsPerHost
        self.timeoutForRequest = timeoutForRequest
        self.timeoutForResource = timeoutForResource
        self.taskInactivityTimeout = taskInactivityTimeout
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }

    package func apply(to builder: inout DownloadConfiguration.AdvancedBuilder) {
        builder.maxConnectionsPerHost = maxConnectionsPerHost
        builder.timeoutForRequest = timeoutForRequest
        builder.timeoutForResource = timeoutForResource
        builder.taskInactivityTimeout = taskInactivityTimeout
        builder.allowsCellularAccess = allowsCellularAccess
        builder.allowsInsecureHTTP = allowsInsecureHTTP
    }
}

/// Groups retry limits, backoff, and reachability coordination.
public struct DownloadRetryPack: Sendable {
    private let maxRetryCount: Int
    private let maxTotalRetries: Int
    private let retryDelay: TimeInterval
    private let exponentialBackoff: Bool
    private let retryJitterRatio: Double
    private let maxRetryDelay: TimeInterval
    private let networkMonitor: (any NetworkMonitoring)?
    private let waitsForNetworkChanges: Bool
    private let networkChangeTimeout: TimeInterval?

    public init(
        maxRetryCount: Int = 5,
        maxTotalRetries: Int = 8,
        retryDelay: TimeInterval = 0.5,
        exponentialBackoff: Bool = false,
        retryJitterRatio: Double = 0.2,
        maxRetryDelay: TimeInterval = 30,
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared,
        waitsForNetworkChanges: Bool = true,
        networkChangeTimeout: TimeInterval? = 20
    ) {
        self.maxRetryCount = maxRetryCount
        self.maxTotalRetries = maxTotalRetries
        self.retryDelay = retryDelay
        self.exponentialBackoff = exponentialBackoff
        self.retryJitterRatio = retryJitterRatio
        self.maxRetryDelay = maxRetryDelay
        self.networkMonitor = networkMonitor
        self.waitsForNetworkChanges = waitsForNetworkChanges
        self.networkChangeTimeout = networkChangeTimeout
    }

    package func apply(to builder: inout DownloadConfiguration.AdvancedBuilder) {
        builder.maxRetryCount = maxRetryCount
        builder.maxTotalRetries = maxTotalRetries
        builder.retryDelay = retryDelay
        builder.exponentialBackoff = exponentialBackoff
        builder.retryJitterRatio = retryJitterRatio
        builder.maxRetryDelay = maxRetryDelay
        builder.networkMonitor = networkMonitor
        builder.waitsForNetworkChanges = waitsForNetworkChanges
        builder.networkChangeTimeout = networkChangeTimeout
    }
}

/// Groups listener buffering and event-pipeline metrics.
public struct DownloadObservabilityPack: Sendable {
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

    package func apply(to builder: inout DownloadConfiguration.AdvancedBuilder) {
        builder.eventDeliveryPolicy = eventDeliveryPolicy
        builder.eventMetricsReporter = eventMetricsReporter
    }
}

/// Groups App Group session storage and append-log durability policy.
public struct DownloadPersistencePack: Sendable {
    private let sharedContainerIdentifier: String?
    private let fsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy
    private let compactionPolicy: DownloadConfiguration.PersistenceCompactionPolicy
    private let baseDirectoryURL: URL?

    public init(
        sharedContainerIdentifier: String? = nil,
        fsyncPolicy: DownloadConfiguration.PersistenceFsyncPolicy = .onCheckpoint,
        compactionPolicy: DownloadConfiguration.PersistenceCompactionPolicy = .default,
        baseDirectoryURL: URL? = nil
    ) {
        self.sharedContainerIdentifier = sharedContainerIdentifier
        self.fsyncPolicy = fsyncPolicy
        self.compactionPolicy = compactionPolicy
        self.baseDirectoryURL = baseDirectoryURL
    }

    package func apply(to builder: inout DownloadConfiguration.AdvancedBuilder) {
        builder.sharedContainerIdentifier = sharedContainerIdentifier
        builder.persistenceFsyncPolicy = fsyncPolicy
        builder.persistenceCompactionPolicy = compactionPolicy
        builder.persistenceBaseDirectoryURL = baseDirectoryURL
    }
}
