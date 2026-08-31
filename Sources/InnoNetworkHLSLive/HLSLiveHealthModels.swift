import Foundation

/// The request strategy that produced one live playlist snapshot.
public enum HLSLiveReloadMode: Equatable, Sendable {
    /// The first media-playlist response.
    case initial

    /// A timed non-blocking playlist reload.
    case polling

    /// A blocking reload positioned at the next complete segment.
    case blocking

    /// A blocking reload positioned at the next partial segment.
    case blockingPartial

    /// A query-clean full reload after delta history could not be merged.
    case fullReloadRecovery

    /// A reload recovered through another Content Steering pathway.
    case contentSteeringRecovery
}

/// The newest complete or partial media position in a live snapshot.
public struct HLSLiveEdgePosition: Equatable, Sendable {
    /// The parent media-sequence number.
    public let mediaSequenceNumber: Int64

    /// The zero-based partial-segment index, or `nil` for a complete segment.
    public let partIndex: Int?

    /// Whether this position identifies a partial segment.
    public var isPartial: Bool {
        partIndex != nil
    }

    init(
        mediaSequenceNumber: Int64,
        partIndex: Int?
    ) {
        self.mediaSequenceNumber = mediaSequenceNumber
        self.partIndex = partIndex
    }
}

/// The overall quality inferred from delivered live playlist snapshots.
public enum HLSLiveHealthStatus: Equatable, Sendable {
    /// No live snapshot has been ingested yet.
    case unknown

    /// No configured health threshold is currently exceeded.
    case healthy

    /// The live session has a recoverable or accumulating risk signal.
    case degraded

    /// The live edge regressed or exceeded a critical threshold.
    case critical
}

/// A value-redacted reason contributing to live playlist health.
public enum HLSLiveHealthIssue: Equatable, Sendable {
    /// The newest advertised media position moved backwards.
    case liveEdgeRegression

    /// Successful reloads repeatedly advertised the same live edge.
    case stagnantLiveEdge

    /// Program time exceeds the declared hold-back by too much.
    case elevatedLiveLatency

    /// HTTP freshness evidence is old relative to target duration.
    case stalePlaylistResponse

    /// Missing delta history repeatedly required query-clean recovery.
    case repeatedDeltaRecovery

    /// Content Steering pathways changed repeatedly.
    case pathwayInstability

    /// Edge stagnation approaches the duration retained by the live window.
    case liveWindowAtRisk
}

/// Groups bounded thresholds used by live playlist health analysis.
public struct HLSLiveHealthThresholdPack: Sendable {
    private static let maximumCount = 10_000
    private static let maximumLatencyDrift: TimeInterval = 60 * 60
    private static let maximumPlaylistAgeMultiplier = 1_000.0

    /// Equal-edge snapshots that make the session degraded.
    public let degradedStagnantSnapshotCount: Int

    /// Equal-edge snapshots that make the session critical.
    public let criticalStagnantSnapshotCount: Int

    /// Full delta recoveries that make the session degraded.
    public let degradedDeltaRecoveryCount: Int

    /// Pathway changes that make the session degraded.
    public let degradedPathwayChangeCount: Int

    /// Seconds beyond declared hold-back that make latency degraded.
    public let degradedLatencyDrift: TimeInterval

    /// Seconds beyond declared hold-back that make latency critical.
    public let criticalLatencyDrift: TimeInterval

    /// Target-duration multiples that make response age degraded.
    public let degradedPlaylistAgeMultiplier: Double

    /// Target-duration multiples that make response age critical.
    public let criticalPlaylistAgeMultiplier: Double

    /// Creates bounded live-health thresholds.
    ///
    /// Counts are clamped to `1...10,000`. Latency drift is clamped to
    /// `0...3,600` seconds. Playlist-age multipliers are clamped to
    /// `1...1,000`. Critical thresholds are never lower than their degraded
    /// counterparts, and non-finite values use their defaults.
    public init(
        degradedStagnantSnapshotCount: Int = 3,
        criticalStagnantSnapshotCount: Int = 6,
        degradedDeltaRecoveryCount: Int = 2,
        degradedPathwayChangeCount: Int = 2,
        degradedLatencyDrift: TimeInterval = 3,
        criticalLatencyDrift: TimeInterval = 15,
        degradedPlaylistAgeMultiplier: Double = 3,
        criticalPlaylistAgeMultiplier: Double = 6
    ) {
        self.degradedStagnantSnapshotCount = Self.normalized(
            degradedStagnantSnapshotCount
        )
        self.criticalStagnantSnapshotCount = max(
            self.degradedStagnantSnapshotCount,
            Self.normalized(criticalStagnantSnapshotCount)
        )
        self.degradedDeltaRecoveryCount = Self.normalized(
            degradedDeltaRecoveryCount
        )
        self.degradedPathwayChangeCount = Self.normalized(
            degradedPathwayChangeCount
        )
        self.degradedLatencyDrift = Self.normalized(
            degradedLatencyDrift,
            fallback: 3
        )
        self.criticalLatencyDrift = max(
            self.degradedLatencyDrift,
            Self.normalized(
                criticalLatencyDrift,
                fallback: 15
            )
        )
        self.degradedPlaylistAgeMultiplier =
            Self.normalizedMultiplier(
                degradedPlaylistAgeMultiplier,
                fallback: 3
            )
        self.criticalPlaylistAgeMultiplier = max(
            self.degradedPlaylistAgeMultiplier,
            Self.normalizedMultiplier(
                criticalPlaylistAgeMultiplier,
                fallback: 6
            )
        )
    }

    private static func normalized(_ value: Int) -> Int {
        min(maximumCount, max(1, value))
    }

    private static func normalized(
        _ value: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else {
            return fallback
        }
        return min(maximumLatencyDrift, max(0, value))
    }

    private static func normalizedMultiplier(
        _ value: Double,
        fallback: Double
    ) -> Double {
        guard value.isFinite else {
            return fallback
        }
        return min(
            maximumPlaylistAgeMultiplier,
            max(1, value)
        )
    }
}

/// Configures one deterministic live playlist health analysis session.
public struct HLSLiveHealthConfiguration: Sendable {
    let thresholds: HLSLiveHealthThresholdPack

    private init(thresholds: HLSLiveHealthThresholdPack) {
        self.thresholds = thresholds
    }

    /// Returns conservative live-health defaults.
    public static func safeDefaults() -> HLSLiveHealthConfiguration {
        advanced()
    }

    /// Returns explicitly tuned live-health behavior.
    public static func advanced(
        thresholds: HLSLiveHealthThresholdPack =
            HLSLiveHealthThresholdPack()
    ) -> HLSLiveHealthConfiguration {
        HLSLiveHealthConfiguration(thresholds: thresholds)
    }
}

/// A deterministic, value-redacted live playlist health snapshot.
public struct HLSLiveHealthSnapshot: Equatable, Sendable {
    /// The inferred overall live playlist quality.
    public let status: HLSLiveHealthStatus

    /// Reasons contributing to `status`, in stable diagnostic order.
    public let issues: [HLSLiveHealthIssue]

    /// The newest finite observation time ingested, if any.
    public let observedAt: Date?

    /// The newest complete or partial position in the current response.
    public let liveEdgePosition: HLSLiveEdgePosition?

    /// The request strategy that produced the current response.
    public let reloadMode: HLSLiveReloadMode?

    /// Program time estimated for the current live edge.
    public let estimatedLiveEdgeDate: Date?

    /// Wall-clock distance from the estimated live edge.
    public let estimatedLiveLatency: TimeInterval?

    /// The server's hold-back recommendation for the current edge kind.
    public let recommendedLiveLatency: TimeInterval?

    /// Age estimated from typed HTTP response freshness evidence.
    public let estimatedPlaylistAge: TimeInterval?

    /// Complete and incomplete media duration visible in the current window.
    public let availableWindowDuration: TimeInterval

    /// Consecutive delivered snapshots that did not advance the edge.
    public let stagnantSnapshotCount: Int

    /// Finite observation time elapsed since the edge last advanced.
    public let stagnantDuration: TimeInterval

    /// Query-clean full reloads used after delta merge failure.
    public let deltaRecoveryCount: Int

    /// Changes in the selected Content Steering pathway.
    public let pathwayChangeCount: Int

    init(
        status: HLSLiveHealthStatus,
        issues: [HLSLiveHealthIssue],
        observedAt: Date?,
        liveEdgePosition: HLSLiveEdgePosition?,
        reloadMode: HLSLiveReloadMode?,
        estimatedLiveEdgeDate: Date?,
        estimatedLiveLatency: TimeInterval?,
        recommendedLiveLatency: TimeInterval?,
        estimatedPlaylistAge: TimeInterval?,
        availableWindowDuration: TimeInterval,
        stagnantSnapshotCount: Int,
        stagnantDuration: TimeInterval,
        deltaRecoveryCount: Int,
        pathwayChangeCount: Int
    ) {
        self.status = status
        self.issues = issues
        self.observedAt = observedAt
        self.liveEdgePosition = liveEdgePosition
        self.reloadMode = reloadMode
        self.estimatedLiveEdgeDate = estimatedLiveEdgeDate
        self.estimatedLiveLatency = estimatedLiveLatency
        self.recommendedLiveLatency = recommendedLiveLatency
        self.estimatedPlaylistAge = estimatedPlaylistAge
        self.availableWindowDuration = availableWindowDuration
        self.stagnantSnapshotCount = stagnantSnapshotCount
        self.stagnantDuration = stagnantDuration
        self.deltaRecoveryCount = deltaRecoveryCount
        self.pathwayChangeCount = pathwayChangeCount
    }
}
