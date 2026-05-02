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
                // Cellular is opt-in in 4.0.x: large background downloads on
                // metered links surprise users. Apps that explicitly want
                // cellular call ``DownloadConfiguration/cellularEnabled()``.
                allowsCellularAccess: false,
                sessionIdentifier: sessionIdentifier,
                networkMonitor: NetworkMonitor.shared,
                waitsForNetworkChanges: false,
                networkChangeTimeout: 10.0,
                eventDeliveryPolicy: .default,
                eventMetricsReporter: nil,
                persistenceFsyncPolicy: .onCheckpoint,
                persistenceCompactionPolicy: .default,
                persistenceBaseDirectoryURL: nil
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
                allowsCellularAccess: false,
                sessionIdentifier: sessionIdentifier,
                networkMonitor: NetworkMonitor.shared,
                waitsForNetworkChanges: true,
                networkChangeTimeout: 20.0,
                eventDeliveryPolicy: EventDeliveryPolicy(
                    maxBufferedEventsPerPartition: 512,
                    maxBufferedEventsPerConsumer: 512,
                    overflowPolicy: .dropOldest
                ),
                eventMetricsReporter: nil,
                persistenceFsyncPolicy: .onCheckpoint,
                persistenceCompactionPolicy: .default,
                persistenceBaseDirectoryURL: nil
            )
        }
    }

    public let maxConnectionsPerHost: Int
    public let maxRetryCount: Int
    /// Maximum total retry count even if the counter is reset due to network changes.
    public let maxTotalRetries: Int
    /// Base retry delay in seconds before jitter / exponential backoff is applied.
    public let retryDelay: TimeInterval
    /// When `true`, each retry grows its base delay as
    /// `retryDelay * 2^(retryCount - 1)` and then samples the final wait from
    /// `base ± (base * retryJitterRatio)`, clamped to ``maxRetryDelay`` when
    /// the user-facing cap is enabled. Default is `false` so 4.x retains the
    /// fixed-delay behavior that earlier releases shipped.
    public let exponentialBackoff: Bool
    /// Jitter ratio applied symmetrically around the exponential-backoff base
    /// delay (`0.0...1.0`). Only consulted when ``exponentialBackoff`` is
    /// enabled. Values outside the range are clamped.
    public let retryJitterRatio: Double
    /// Upper bound in seconds on the exponential-backoff retry delay after
    /// symmetric jitter is applied.
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
    /// Controls how aggressively the append-log persistence calls `fsync(_:)`
    /// on the events log and checkpoint files. See
    /// ``PersistenceFsyncPolicy`` for the trade-offs. Defaults to
    /// ``PersistenceFsyncPolicy/onCheckpoint``.
    public let persistenceFsyncPolicy: PersistenceFsyncPolicy
    /// Controls when the append-log persistence layer rewrites a compact
    /// checkpoint and clears accumulated mutation events.
    public let persistenceCompactionPolicy: PersistenceCompactionPolicy
    /// Optional override for the persistence root directory.
    ///
    /// When `nil` (the default), the append-log persistence store writes to
    /// `applicationSupportDirectory/InnoNetworkDownload/<sessionIdentifier>`.
    /// Apps that want to keep download metadata out of iCloud backups should
    /// supply a directory under `cachesDirectory`. The supplied URL must be a
    /// directory the process can read and write.
    public let persistenceBaseDirectoryURL: URL?

    /// Durability policy for the append-log persistence layer.
    ///
    /// `fsync(_:)` forces an in-flight write through the OS page cache to
    /// stable storage. The cost is real (latency spike when the underlying
    /// volume is busy), so the library exposes the trade-off rather than
    /// burning a default into the persistence layer.
    public enum PersistenceFsyncPolicy: Sendable, Equatable {
        /// Call `fsync(_:)` after every append-log mutation batch and after
        /// every checkpoint write. Maximum durability, highest IO cost.
        /// Recommended only for high-value transfers where a crash that
        /// loses the most recent event is unacceptable.
        case always

        /// Call `fsync(_:)` only on checkpoint writes (compaction). The
        /// most recent few events between checkpoints may be lost on a
        /// hard crash, but typical writes do not pay the fsync cost. This
        /// is the safe default for most consumer apps.
        case onCheckpoint

        /// Never call `fsync(_:)`. Rely on the OS to flush dirty pages on
        /// its own cadence. A crash may lose the last few minutes of
        /// progress; recovery falls back to the most recent durable
        /// checkpoint. Use only when re-download is cheap.
        case never
    }

    /// Snapshot/compaction thresholds for the download persistence append log.
    ///
    /// The defaults keep the 4.0.0 behavior explicit: compact after 1,000 log
    /// events, after the log reaches 1 MiB, or when tombstones are at least
    /// 25% of the log. Long-running apps can lower these limits to keep the
    /// recovery scan short, or raise them when write amplification matters
    /// more than startup replay time.
    public struct PersistenceCompactionPolicy: Sendable, Equatable {
        /// Append-log mutation count that triggers a checkpoint rewrite.
        /// Clamped to `>= 1`. Default `1_000`.
        public let maxEvents: Int
        /// Append-log file-size threshold (bytes) that triggers a checkpoint
        /// rewrite. Clamped to `>= 1`. Default `1_048_576` (1 MiB).
        public let maxLogBytes: UInt64
        /// Fraction of log entries that must be tombstones (`0.0...1.0`)
        /// before a checkpoint is forced. Out-of-range values are clamped.
        /// Default `0.25`.
        public let tombstoneRatio: Double

        public init(
            maxEvents: Int = 1_000,
            maxLogBytes: UInt64 = 1_048_576,
            tombstoneRatio: Double = 0.25
        ) {
            self.maxEvents = max(1, maxEvents)
            self.maxLogBytes = max(1, maxLogBytes)
            self.tombstoneRatio = min(1.0, max(0.0, tombstoneRatio))
        }

        /// Compaction policy with the documented 4.0.0 defaults
        /// (`maxEvents: 1_000`, `maxLogBytes: 1 MiB`, `tombstoneRatio: 0.25`).
        public static let `default` = PersistenceCompactionPolicy()
    }

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
        /// Jitter ratio applied symmetrically around the exponential backoff base delay (`0.0...1.0`). Defaults to `0.2`.
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
        /// `fsync(_:)` policy for the append-log persistence layer.
        public var persistenceFsyncPolicy: PersistenceFsyncPolicy
        /// Snapshot/compaction thresholds for the append-log persistence layer.
        public var persistenceCompactionPolicy: PersistenceCompactionPolicy
        /// Optional override for the persistence root directory. Set to a
        /// `cachesDirectory`-rooted URL to keep download metadata out of
        /// iCloud backups, or to a process-private temporary directory in
        /// tests.
        public var persistenceBaseDirectoryURL: URL?

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
            self.persistenceFsyncPolicy = preset.persistenceFsyncPolicy
            self.persistenceCompactionPolicy = preset.persistenceCompactionPolicy
            self.persistenceBaseDirectoryURL = preset.persistenceBaseDirectoryURL
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
                eventMetricsReporter: eventMetricsReporter,
                persistenceFsyncPolicy: persistenceFsyncPolicy,
                persistenceCompactionPolicy: persistenceCompactionPolicy,
                persistenceBaseDirectoryURL: persistenceBaseDirectoryURL
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
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil,
        persistenceFsyncPolicy: PersistenceFsyncPolicy = .onCheckpoint,
        persistenceCompactionPolicy: PersistenceCompactionPolicy = .default,
        persistenceBaseDirectoryURL: URL? = nil
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
        self.persistenceFsyncPolicy = persistenceFsyncPolicy
        self.persistenceCompactionPolicy = persistenceCompactionPolicy
        self.persistenceBaseDirectoryURL = persistenceBaseDirectoryURL
    }

    /// Returns a copy of this configuration with cellular access enabled.
    ///
    /// Use this on top of ``safeDefaults(sessionIdentifier:)`` when you have
    /// confirmed (UI affordance, settings screen, or large-file justification)
    /// that the user expects downloads to consume cellular bandwidth.
    public func cellularEnabled() -> DownloadConfiguration {
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
            allowsCellularAccess: true,
            sessionIdentifier: sessionIdentifier,
            networkMonitor: networkMonitor,
            waitsForNetworkChanges: waitsForNetworkChanges,
            networkChangeTimeout: networkChangeTimeout,
            eventDeliveryPolicy: eventDeliveryPolicy,
            eventMetricsReporter: eventMetricsReporter,
            persistenceFsyncPolicy: persistenceFsyncPolicy,
            persistenceCompactionPolicy: persistenceCompactionPolicy,
            persistenceBaseDirectoryURL: persistenceBaseDirectoryURL
        )
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
