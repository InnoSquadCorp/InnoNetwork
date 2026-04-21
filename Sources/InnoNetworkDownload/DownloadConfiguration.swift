import Foundation
import InnoNetwork


/// Configures download transport behavior, retry policy, and event delivery.
public struct DownloadConfiguration: Sendable {
    private static let defaultSessionIdentifier = "com.innonetwork.download"

    package enum Presets {
        static func safeDefaults(sessionIdentifier: String) -> DownloadConfiguration {
            DownloadConfiguration(
                maxConnectionsPerHost: 3,
                maxRetryCount: 3,
                maxTotalRetries: 3,
                retryDelay: 1.0,
                exponentialBackoff: false,
                retryJitterRatio: 0.2,
                maxRetryDelay: 60,
                timeoutForRequest: 30,
                timeoutForResource: 60 * 60 * 24,
                allowsCellularAccess: true,
                sessionIdentifier: sessionIdentifier,
                networkMonitor: NetworkMonitor.shared,
                waitsForNetworkChanges: false,
                networkChangeTimeout: 10.0,
                eventDeliveryPolicy: .default,
                eventMetricsReporter: nil
            )
        }

        static func advancedTuning(sessionIdentifier: String) -> DownloadConfiguration {
            DownloadConfiguration(
                maxConnectionsPerHost: 6,
                maxRetryCount: 5,
                maxTotalRetries: 8,
                retryDelay: 0.5,
                exponentialBackoff: false,
                retryJitterRatio: 0.2,
                maxRetryDelay: 30,
                timeoutForRequest: 60,
                timeoutForResource: 60 * 60 * 24,
                allowsCellularAccess: true,
                sessionIdentifier: sessionIdentifier,
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
    /// Base retry delay in seconds before jitter / exponential backoff is applied.
    public let retryDelay: TimeInterval
    /// When `true`, each retry waits `retryDelay * 2^(retryCount - 1) + jitter`
    /// capped at ``maxRetryDelay``. Default is `false` so 4.x retains the
    /// fixed-delay behavior that earlier releases shipped.
    public let exponentialBackoff: Bool
    /// Jitter ratio applied to the exponential backoff (`0.0...1.0`). Only
    /// consulted when ``exponentialBackoff`` is enabled. Values outside the
    /// range are clamped.
    public let retryJitterRatio: Double
    /// Upper bound in seconds on the exponential-backoff retry delay after
    /// jitter is applied.
    ///
    /// - `> 0`: cap enabled (default `60s`).
    /// - `<= 0`: cap **disabled** — the backoff grows until it reaches the
    ///   runtime's maximum representable sleep duration.
    ///
    /// Only consulted when ``exponentialBackoff`` is enabled. Negative values
    /// clamp to `0` (cap disabled).
    public let maxRetryDelay: TimeInterval
    public let timeoutForRequest: TimeInterval
    public let timeoutForResource: TimeInterval
    public let allowsCellularAccess: Bool
    /// Background `URLSession` identifier and persistence scope.
    ///
    /// The preset factories use a shared identifier intended for a single download manager per process.
    /// Override this value when you need multiple independent managers or persistence domains.
    public let sessionIdentifier: String
    public let networkMonitor: (any NetworkMonitoring)?
    /// When true, waits for network changes before retrying on download failure.
    public let waitsForNetworkChanges: Bool
    public let networkChangeTimeout: TimeInterval?
    /// Event buffering policy used for task listeners and async streams.
    public let eventDeliveryPolicy: EventDeliveryPolicy
    /// Optional reporter that receives raw and aggregate event pipeline metrics.
    public let eventMetricsReporter: (any EventPipelineMetricsReporting)?

    /// Mutable builder seeded from the advanced tuning preset.
    ///
    /// Use this to override the high-tuning defaults returned by `advanced(_:)`.
    public struct AdvancedBuilder: Sendable {
        /// Maximum simultaneous connections per host. Defaults to `6` in the advanced preset.
        public var maxConnectionsPerHost: Int
        /// Maximum retry attempts for a single failure chain. Defaults to `5` in the advanced preset.
        public var maxRetryCount: Int
        /// Maximum cumulative retries even after network change resets. Defaults to `8` in the advanced preset.
        public var maxTotalRetries: Int
        /// Base retry delay in seconds. Defaults to `0.5` in the advanced preset.
        public var retryDelay: TimeInterval
        /// Enables exponential backoff for retries. Defaults to `false`.
        public var exponentialBackoff: Bool
        /// Jitter ratio applied to the exponential backoff (`0.0...1.0`). Defaults to `0.2`.
        public var retryJitterRatio: Double
        /// Upper bound on the exponential-backoff retry delay. `<= 0` disables the user-facing cap and falls back to the runtime-safe maximum delay. Defaults to `30` in the advanced preset.
        public var maxRetryDelay: TimeInterval
        /// Request timeout in seconds. Defaults to `60` in the advanced preset.
        public var timeoutForRequest: TimeInterval
        /// Resource timeout in seconds. Defaults to `24h` in both presets.
        public var timeoutForResource: TimeInterval
        /// Whether downloads may use cellular connectivity. Defaults to `true`.
        public var allowsCellularAccess: Bool
        /// Background session identifier and persistence scope.
        ///
        /// Override this when you need more than one download manager in the same process.
        public var sessionIdentifier: String
        /// Optional network monitor used for retry and restore coordination.
        public var networkMonitor: (any NetworkMonitoring)?
        /// Whether retry logic waits for a network change before retrying. Defaults to `true`.
        public var waitsForNetworkChanges: Bool
        /// Maximum time to wait for a network change before failing the retry. Defaults to `20` seconds.
        public var networkChangeTimeout: TimeInterval?
        /// Event buffering and overflow policy for listeners and async streams.
        public var eventDeliveryPolicy: EventDeliveryPolicy
        /// Optional reporter that receives raw and aggregate event pipeline metrics.
        public var eventMetricsReporter: (any EventPipelineMetricsReporting)?

        fileprivate init(preset: DownloadConfiguration) {
            self.maxConnectionsPerHost = preset.maxConnectionsPerHost
            self.maxRetryCount = preset.maxRetryCount
            self.maxTotalRetries = preset.maxTotalRetries
            self.retryDelay = preset.retryDelay
            self.exponentialBackoff = preset.exponentialBackoff
            self.retryJitterRatio = preset.retryJitterRatio
            self.maxRetryDelay = preset.maxRetryDelay
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
                exponentialBackoff: exponentialBackoff,
                retryJitterRatio: retryJitterRatio,
                maxRetryDelay: maxRetryDelay,
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

    /// Returns conservative defaults suitable for most production download flows.
    ///
    /// The returned configuration uses the shared `com.innonetwork.download` session identifier,
    /// which is intended for a single download manager per process.
    public static func safeDefaults() -> DownloadConfiguration {
        safeDefaults(sessionIdentifier: defaultSessionIdentifier)
    }

    /// Returns conservative defaults suitable for most production download flows.
    ///
    /// - Parameter sessionIdentifier: Background session identifier and persistence scope used by `DownloadManager`.
    ///   Supply a unique value when multiple download managers must coexist in the same process.
    public static func safeDefaults(sessionIdentifier: String) -> DownloadConfiguration {
        Presets.safeDefaults(sessionIdentifier: sessionIdentifier)
    }

    /// Returns an advanced configuration seeded from the high-tuning preset.
    ///
    /// Use this when you need explicit control over connection limits, retry behavior,
    /// or event delivery settings. The builder starts from `Presets.advancedTuning()`.
    public static func advanced(_ configure: (inout AdvancedBuilder) -> Void) -> DownloadConfiguration {
        advanced(sessionIdentifier: defaultSessionIdentifier, configure)
    }

    /// Returns an advanced configuration seeded from the high-tuning preset.
    ///
    /// - Parameters:
    ///   - sessionIdentifier: Background session identifier and persistence scope used by `DownloadManager`.
    ///     Supply a unique value when multiple download managers must coexist in the same process.
    ///   - configure: Closure that mutates an `AdvancedBuilder` seeded from `Presets.advancedTuning()`.
    public static func advanced(
        sessionIdentifier: String,
        _ configure: (inout AdvancedBuilder) -> Void
    ) -> DownloadConfiguration {
        var builder = AdvancedBuilder(preset: Presets.advancedTuning(sessionIdentifier: sessionIdentifier))
        configure(&builder)
        return builder.build()
    }

    public init(
        maxConnectionsPerHost: Int = 3,
        maxRetryCount: Int = 3,
        maxTotalRetries: Int = 3,
        retryDelay: TimeInterval = 1.0,
        exponentialBackoff: Bool = false,
        retryJitterRatio: Double = 0.2,
        maxRetryDelay: TimeInterval = 60,
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
        self.exponentialBackoff = exponentialBackoff
        self.retryJitterRatio = min(1.0, max(0.0, retryJitterRatio))
        self.maxRetryDelay = max(0, maxRetryDelay)
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
