import Foundation
import InnoNetwork

/// Configures download transport behavior, retry policy, and event delivery.
public struct DownloadConfiguration: Sendable {
    private static let defaultSessionIdentifier = "com.innonetwork.download"

    /// Selects whether Foundation performs transfers in-process or in its
    /// out-of-process background daemon.
    package enum SessionMode: Sendable, Equatable {
        /// Uses an ephemeral session, allowing InnoNetwork to inspect and
        /// reject every redirect before it is followed. This is the secure
        /// default.
        case foreground
        /// Uses a background session. Apple background sessions always follow
        /// redirects without calling the redirect delegate, so redirect URL
        /// admission cannot be enforced before each hop. Initial and final
        /// URLs are still validated where Foundation exposes them, but final
        /// validation cannot undo contact with an intermediate redirect
        /// target. Select this only when process-independent continuation is
        /// worth that trade-off.
        case background
    }

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
                taskInactivityTimeout: nil,
                // Cellular is opt-in in 4.0.x: large background downloads on
                // metered links surprise users. Apps that explicitly want
                // cellular call ``DownloadConfiguration/cellularEnabled()``.
                allowsCellularAccess: false,
                allowsInsecureHTTP: false,
                sessionIdentifier: sessionIdentifier,
                sharedContainerIdentifier: nil,
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
                taskInactivityTimeout: nil,
                allowsCellularAccess: false,
                allowsInsecureHTTP: false,
                sessionIdentifier: sessionIdentifier,
                sharedContainerIdentifier: nil,
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
    /// Optional per-task inactivity watchdog. When set, the manager cancels a
    /// downloading task if no progress callback or first-observed download
    /// activity has been seen for at least this duration. `nil` disables the
    /// watchdog (default), falling back to the URLSession-level
    /// ``timeoutForRequest`` and ``timeoutForResource``.
    ///
    /// Use this when you want to fail faster than `timeoutForResource` on
    /// mid-transfer stalls — for example when a server stops feeding bytes
    /// without closing the TCP connection.
    ///
    /// The init clamps non-`nil` values up to a 100-millisecond floor so
    /// `Duration.zero` (or pathologically small values) cannot turn the
    /// watchdog into a "cancel every task after one poll" generator. Pass
    /// `nil` if you want the watchdog disabled.
    public let taskInactivityTimeout: Duration?
    public let allowsCellularAccess: Bool
    /// Allows plain `http` download sources and same-scheme redirect targets.
    /// Defaults to `false`; production downloads should use HTTPS. This does
    /// not permit HTTPS-to-HTTP downgrade redirects in foreground mode, where
    /// the download delegate enforces the default redirect policy. Background
    /// sessions do not expose per-hop redirect decisions to the delegate.
    public let allowsInsecureHTTP: Bool
    /// Foundation session mode. Foreground mode is the secure default and
    /// enforces admission before every redirect. Background mode preserves
    /// out-of-process continuation, but Foundation follows redirects without
    /// consulting the delegate, so only initial and exposed final URLs can be
    /// validated by the library.
    package let sessionMode: SessionMode
    /// Manager identifier and persistence scope. In background mode this is
    /// also the `URLSessionConfiguration` background-session identifier.
    ///
    /// The preset factories use a shared identifier intended for a single download manager per process.
    /// Override this value when you need multiple independent managers or persistence domains.
    public let sessionIdentifier: String
    /// Optional App Group container identifier used by the background
    /// `URLSession` to store in-flight transfer state in a shared container.
    ///
    /// Mirrors `URLSessionConfiguration.sharedContainerIdentifier`. Leave `nil`
    /// for app-private background sessions; set this when an app extension must
    /// observe or continue the same background download session. Exactly one
    /// process may own that session identifier at a time. Cross-process
    /// restoration also requires ``persistenceBaseDirectoryURL`` to point to a
    /// shared writable App Group directory; this setting alone shares only
    /// Foundation's session state. This value is ignored in foreground mode.
    public let sharedContainerIdentifier: String?
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
    /// `applicationSupportDirectory/InnoNetworkDownload/<storage-component>`.
    /// Conventional lowercase reverse-DNS identifiers are retained as the
    /// component. Other values use a deterministic SHA-256 component so path
    /// syntax, excessive length, Unicode, or case-insensitive aliases cannot
    /// escape or share a session's storage directory.
    /// Download-owned directories and metadata files are excluded from backup
    /// regardless of this override. On iOS-family platforms they also use
    /// complete-until-first-user-authentication file protection. The supplied
    /// root itself and caller-owned final destinations are left unchanged.
    /// The supplied URL must be a directory the process can read and write.
    /// When a host app and extension may be relaunched as alternate owners of
    /// one background session, both targets must use the same App Group-backed
    /// root so the library can correlate restored Foundation tasks with its
    /// logical persistence records. Proactive live handoff is not supported.
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

    /// Internal builder used by the pack-based `advanced(...)` factory.
    package struct AdvancedBuilder: Sendable {
        /// Maximum simultaneous connections per host. Defaults to `6` in the advanced preset.
        package var maxConnectionsPerHost: Int
        /// Maximum retry attempts for a single failure chain. Defaults to `5` in the advanced preset.
        package var maxRetryCount: Int
        /// Maximum cumulative retries even after network change resets. Defaults to `8` in the advanced preset.
        package var maxTotalRetries: Int
        /// Base retry delay in seconds. Defaults to `0.5` in the advanced preset.
        package var retryDelay: TimeInterval
        /// Enables exponential backoff for retries. Defaults to `false`.
        package var exponentialBackoff: Bool
        /// Jitter ratio applied symmetrically around the exponential backoff base delay (`0.0...1.0`). Defaults to `0.2`.
        package var retryJitterRatio: Double
        /// Upper bound on the exponential-backoff retry delay. `<= 0` disables the user-facing cap and falls back to the runtime-safe maximum delay. Defaults to `30` in the advanced preset.
        package var maxRetryDelay: TimeInterval
        /// Request timeout in seconds. Defaults to `60` in the advanced preset.
        package var timeoutForRequest: TimeInterval
        /// Resource timeout in seconds. Defaults to `24h` in both presets.
        package var timeoutForResource: TimeInterval
        /// Optional per-task inactivity watchdog. `nil` disables it (default).
        package var taskInactivityTimeout: Duration?
        /// Whether downloads may use cellular connectivity. Defaults to `false`
        /// in safe and advanced presets; opt in when the product explicitly
        /// accepts cellular transfer cost.
        package var allowsCellularAccess: Bool
        /// Allows plain `http` download sources. Defaults to `false`.
        package var allowsInsecureHTTP: Bool
        /// Manager identifier and persistence scope. In background mode this
        /// is also the Foundation background-session identifier.
        ///
        /// Override this when you need more than one download manager in the same process.
        package var sessionIdentifier: String
        /// Optional App Group container identifier threaded to
        /// `URLSessionConfiguration.sharedContainerIdentifier`.
        package var sharedContainerIdentifier: String?
        /// Optional network monitor used for retry and restore coordination.
        package var networkMonitor: (any NetworkMonitoring)?
        /// Whether retry logic waits for a network change before retrying. Defaults to `true`.
        package var waitsForNetworkChanges: Bool
        /// Maximum time to wait for a network change before failing the retry. Defaults to `20` seconds.
        package var networkChangeTimeout: TimeInterval?
        /// Event buffering and overflow policy for listeners and async streams.
        package var eventDeliveryPolicy: EventDeliveryPolicy
        /// Optional reporter that receives raw and aggregate event pipeline metrics.
        package var eventMetricsReporter: (any EventPipelineMetricsReporting)?
        /// `fsync(_:)` policy for the append-log persistence layer.
        package var persistenceFsyncPolicy: PersistenceFsyncPolicy
        /// Snapshot/compaction thresholds for the append-log persistence layer.
        package var persistenceCompactionPolicy: PersistenceCompactionPolicy
        /// Optional override for the persistence root directory. Download-owned
        /// paths are excluded from backup automatically; use this override to
        /// select another process-private location or a temporary directory in
        /// tests. The supplied root and caller-owned destinations are unchanged.
        package var persistenceBaseDirectoryURL: URL?

        package init(preset: DownloadConfiguration) {
            self.maxConnectionsPerHost = preset.maxConnectionsPerHost
            self.maxRetryCount = preset.maxRetryCount
            self.maxTotalRetries = preset.maxTotalRetries
            self.retryDelay = preset.retryDelay
            self.exponentialBackoff = preset.exponentialBackoff
            self.retryJitterRatio = preset.retryJitterRatio
            self.maxRetryDelay = preset.maxRetryDelay
            self.timeoutForRequest = preset.timeoutForRequest
            self.timeoutForResource = preset.timeoutForResource
            self.taskInactivityTimeout = preset.taskInactivityTimeout
            self.allowsCellularAccess = preset.allowsCellularAccess
            self.allowsInsecureHTTP = preset.allowsInsecureHTTP
            self.sessionIdentifier = preset.sessionIdentifier
            self.sharedContainerIdentifier = preset.sharedContainerIdentifier
            self.networkMonitor = preset.networkMonitor
            self.waitsForNetworkChanges = preset.waitsForNetworkChanges
            self.networkChangeTimeout = preset.networkChangeTimeout
            self.eventDeliveryPolicy = preset.eventDeliveryPolicy
            self.eventMetricsReporter = preset.eventMetricsReporter
            self.persistenceFsyncPolicy = preset.persistenceFsyncPolicy
            self.persistenceCompactionPolicy = preset.persistenceCompactionPolicy
            self.persistenceBaseDirectoryURL = preset.persistenceBaseDirectoryURL
        }

        package func build() -> DownloadConfiguration {
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
                taskInactivityTimeout: taskInactivityTimeout,
                allowsCellularAccess: allowsCellularAccess,
                allowsInsecureHTTP: allowsInsecureHTTP,
                sessionIdentifier: sessionIdentifier,
                sharedContainerIdentifier: sharedContainerIdentifier,
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
    /// The returned configuration uses secure foreground mode and the shared
    /// `com.innonetwork.download` identifier, which is intended for a single
    /// download manager per process.
    public static func safeDefaults() -> DownloadConfiguration {
        safeDefaults(sessionIdentifier: defaultSessionIdentifier)
    }

    /// Returns conservative defaults suitable for most production download flows.
    ///
    /// - Parameter sessionIdentifier: Manager identifier and persistence scope
    ///   used by `DownloadManager`. In background mode this is also the
    ///   Foundation background-session identifier.
    ///   Supply a unique value when multiple download managers must coexist in the same process.
    public static func safeDefaults(sessionIdentifier: String) -> DownloadConfiguration {
        Presets.safeDefaults(sessionIdentifier: sessionIdentifier)
    }

    /// Composes an advanced configuration from explicit thematic packs.
    /// Omitted packs preserve the documented high-tuning preset.
    public static func advanced(
        sessionIdentifier: String = "com.innonetwork.download",
        transfer: DownloadTransferPack = DownloadTransferPack(),
        retry: DownloadRetryPack = DownloadRetryPack(),
        observability: DownloadObservabilityPack = DownloadObservabilityPack(),
        persistence: DownloadPersistencePack = DownloadPersistencePack()
    ) -> DownloadConfiguration {
        var builder = AdvancedBuilder(preset: Presets.advancedTuning(sessionIdentifier: sessionIdentifier))
        transfer.apply(to: &builder)
        retry.apply(to: &builder)
        observability.apply(to: &builder)
        persistence.apply(to: &builder)
        return builder.build()
    }

    package init(
        maxConnectionsPerHost: Int = 3,
        maxRetryCount: Int = 3,
        maxTotalRetries: Int = 3,
        retryDelay: TimeInterval = 1.0,
        exponentialBackoff: Bool = false,
        retryJitterRatio: Double = 0.2,
        maxRetryDelay: TimeInterval = 60,
        timeoutForRequest: TimeInterval = 30,
        timeoutForResource: TimeInterval = 60 * 60 * 24,
        taskInactivityTimeout: Duration? = nil,
        allowsCellularAccess: Bool = true,
        allowsInsecureHTTP: Bool = false,
        sessionIdentifier: String = "com.innonetwork.download",
        sharedContainerIdentifier: String? = nil,
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
        // Clamp to a 100ms floor so `.zero` (or pathologically small values
        // that round to one watchdog tick) cannot turn into a "cancel every
        // task after one poll" generator. Pass `nil` to disable the watchdog.
        self.taskInactivityTimeout = taskInactivityTimeout.map { max($0, .milliseconds(100)) }
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.sessionMode = .foreground
        self.sessionIdentifier = sessionIdentifier
        self.sharedContainerIdentifier = sharedContainerIdentifier
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
        DownloadConfiguration(copying: self, allowsCellularAccess: true)
    }

    /// Returns a copy configured for Foundation-managed background transfers.
    ///
    /// Background sessions can continue while the app is suspended or
    /// terminated by the system, but Foundation follows their redirects without
    /// consulting the redirect delegate. InnoNetwork can still validate the initial and
    /// exposed final URLs, but it cannot enforce per-hop URL admission. Keep
    /// the foreground default unless process-independent continuation is worth
    /// that security trade-off.
    public func backgroundTransfersEnabled() -> DownloadConfiguration {
        DownloadConfiguration(copying: self, sessionMode: .background)
    }

    private init(
        copying configuration: DownloadConfiguration,
        sessionMode: SessionMode? = nil,
        allowsCellularAccess: Bool? = nil
    ) {
        self.maxConnectionsPerHost = configuration.maxConnectionsPerHost
        self.maxRetryCount = configuration.maxRetryCount
        self.maxTotalRetries = configuration.maxTotalRetries
        self.retryDelay = configuration.retryDelay
        self.exponentialBackoff = configuration.exponentialBackoff
        self.retryJitterRatio = configuration.retryJitterRatio
        self.maxRetryDelay = configuration.maxRetryDelay
        self.timeoutForRequest = configuration.timeoutForRequest
        self.timeoutForResource = configuration.timeoutForResource
        self.taskInactivityTimeout = configuration.taskInactivityTimeout
        self.allowsCellularAccess = allowsCellularAccess ?? configuration.allowsCellularAccess
        self.allowsInsecureHTTP = configuration.allowsInsecureHTTP
        self.sessionMode = sessionMode ?? configuration.sessionMode
        self.sessionIdentifier = configuration.sessionIdentifier
        self.sharedContainerIdentifier = configuration.sharedContainerIdentifier
        self.networkMonitor = configuration.networkMonitor
        self.waitsForNetworkChanges = configuration.waitsForNetworkChanges
        self.networkChangeTimeout = configuration.networkChangeTimeout
        self.eventDeliveryPolicy = configuration.eventDeliveryPolicy
        self.eventMetricsReporter = configuration.eventMetricsReporter
        self.persistenceFsyncPolicy = configuration.persistenceFsyncPolicy
        self.persistenceCompactionPolicy = configuration.persistenceCompactionPolicy
        self.persistenceBaseDirectoryURL = configuration.persistenceBaseDirectoryURL
    }

    func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let config: URLSessionConfiguration
        switch sessionMode {
        case .foreground:
            config = .ephemeral
        case .background:
            config = .background(withIdentifier: sessionIdentifier)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
            config.sharedContainerIdentifier = sharedContainerIdentifier
        }
        config.allowsCellularAccess = allowsCellularAccess
        config.timeoutIntervalForRequest = timeoutForRequest
        config.timeoutIntervalForResource = timeoutForResource
        config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        return config
    }
}
