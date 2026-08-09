import Foundation

/// The overall quality inferred from delivered playback metric events.
public enum HLSPlaybackHealthStatus: Equatable, Sendable {
    /// No playback metric has been ingested yet.
    case unknown

    /// No configured health threshold is currently exceeded.
    case healthy

    /// Playback is impaired but has no critical signal.
    case degraded

    /// Playback has a terminal error or exceeds a critical threshold.
    case critical
}

/// A value-redacted reason contributing to playback health.
public enum HLSPlaybackHealthIssue: Equatable, Sendable {
    /// Initial playback startup exceeded its configured duration.
    case slowStartup

    /// One or more stalls occurred in the observation window.
    case playbackStalls

    /// Recoverable playback errors exceeded their configured count.
    case repeatedRecoverableErrors

    /// One or more media requests failed without recovery.
    case mediaRequestFailures

    /// Media transfers exceeded their configured duration.
    case slowMediaTransfers

    /// Variant switches exceeded their configured count.
    case variantInstability

    /// One or more variant-switch attempts failed.
    case variantSwitchFailures

    /// AVFoundation reported a non-recoverable playback error.
    case terminalPlaybackError
}

/// Groups the thresholds used by playback-health analysis.
public struct HLSPlaybackHealthThresholdPack: Sendable {
    private static let maximumObservationWindow: TimeInterval =
        60 * 60
    private static let maximumDurationThreshold: TimeInterval =
        5 * 60
    private static let maximumEventThreshold = 10_000

    /// The rolling interval used for transient health signals.
    public let observationWindow: TimeInterval

    /// The initial-startup duration that becomes degraded.
    public let slowStartupDuration: TimeInterval

    /// The uncached transfer duration that becomes degraded.
    public let slowMediaTransferDuration: TimeInterval

    /// The rolling stall count that becomes critical.
    public let criticalStallCount: Int

    /// The rolling recoverable-error count that becomes degraded.
    public let degradedRecoverableErrorCount: Int

    /// The rolling failed-request count that becomes critical.
    public let criticalMediaRequestFailureCount: Int

    /// The rolling completed variant-switch count that becomes degraded.
    public let degradedVariantSwitchCount: Int

    /// Creates bounded playback-health thresholds.
    ///
    /// Duration values are clamped to `1...3,600` seconds for the observation
    /// window and `0.1...300` seconds for startup and transfer thresholds.
    /// Count values are clamped to `1...10,000`. Non-finite values use their
    /// defaults.
    public init(
        observationWindow: TimeInterval = 60,
        slowStartupDuration: TimeInterval = 5,
        slowMediaTransferDuration: TimeInterval = 2,
        criticalStallCount: Int = 3,
        degradedRecoverableErrorCount: Int = 3,
        criticalMediaRequestFailureCount: Int = 2,
        degradedVariantSwitchCount: Int = 6
    ) {
        self.observationWindow = Self.normalized(
            observationWindow,
            fallback: 60,
            minimum: 1,
            maximum: Self.maximumObservationWindow
        )
        self.slowStartupDuration = Self.normalized(
            slowStartupDuration,
            fallback: 5,
            minimum: 0.1,
            maximum: Self.maximumDurationThreshold
        )
        self.slowMediaTransferDuration = Self.normalized(
            slowMediaTransferDuration,
            fallback: 2,
            minimum: 0.1,
            maximum: Self.maximumDurationThreshold
        )
        self.criticalStallCount = Self.normalized(
            criticalStallCount
        )
        self.degradedRecoverableErrorCount = Self.normalized(
            degradedRecoverableErrorCount
        )
        self.criticalMediaRequestFailureCount = Self.normalized(
            criticalMediaRequestFailureCount
        )
        self.degradedVariantSwitchCount = Self.normalized(
            degradedVariantSwitchCount
        )
    }

    private static func normalized(
        _ value: TimeInterval,
        fallback: TimeInterval,
        minimum: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else {
            return fallback
        }
        return min(maximum, max(minimum, value))
    }

    private static func normalized(_ value: Int) -> Int {
        min(maximumEventThreshold, max(1, value))
    }
}

/// Configures one deterministic playback-health analysis session.
public struct HLSPlaybackHealthConfiguration: Sendable {
    let thresholds: HLSPlaybackHealthThresholdPack
    let maximumRetainedEventCount: Int

    private init(
        thresholds: HLSPlaybackHealthThresholdPack,
        maximumRetainedEventCount: Int
    ) {
        self.thresholds = thresholds
        self.maximumRetainedEventCount = min(
            4_096,
            max(1, maximumRetainedEventCount)
        )
    }

    /// Returns conservative playback-health defaults.
    public static func safeDefaults()
        -> HLSPlaybackHealthConfiguration
    {
        advanced()
    }

    /// Returns explicitly tuned playback-health behavior.
    ///
    /// The retained-event limit is clamped to `1...4,096`.
    public static func advanced(
        thresholds: HLSPlaybackHealthThresholdPack =
            HLSPlaybackHealthThresholdPack(),
        maximumRetainedEventCount: Int = 512
    ) -> HLSPlaybackHealthConfiguration {
        HLSPlaybackHealthConfiguration(
            thresholds: thresholds,
            maximumRetainedEventCount: maximumRetainedEventCount
        )
    }
}

/// A deterministic, value-redacted playback-health snapshot.
public struct HLSPlaybackHealthSnapshot: Equatable, Sendable {
    /// The inferred overall playback quality.
    public let status: HLSPlaybackHealthStatus

    /// Reasons contributing to `status`, in stable diagnostic order.
    public let issues: [HLSPlaybackHealthIssue]

    /// The newest finite metric timestamp observed, if any.
    public let observedAt: Date?

    /// Events retained inside the rolling observation window.
    public let retainedEventCount: Int

    /// Stalls observed or reported inside the rolling window.
    public let stallCount: Int

    /// Recoverable errors observed or reported inside the rolling window.
    public let recoverableErrorCount: Int

    /// Media-request failures observed inside the rolling window.
    public let mediaRequestFailureCount: Int

    /// Slow uncached media transfers observed inside the rolling window.
    public let slowMediaTransferCount: Int

    /// Completed variant switches observed or reported in the rolling window.
    public let variantSwitchCount: Int

    /// Failed variant switches observed inside the rolling window.
    public let variantSwitchFailureCount: Int

    /// The session's initial startup duration, when reported.
    public let initialStartupDuration: TimeInterval?

    init(
        status: HLSPlaybackHealthStatus,
        issues: [HLSPlaybackHealthIssue],
        observedAt: Date?,
        retainedEventCount: Int,
        stallCount: Int,
        recoverableErrorCount: Int,
        mediaRequestFailureCount: Int,
        slowMediaTransferCount: Int,
        variantSwitchCount: Int,
        variantSwitchFailureCount: Int,
        initialStartupDuration: TimeInterval?
    ) {
        self.status = status
        self.issues = issues
        self.observedAt = observedAt
        self.retainedEventCount = retainedEventCount
        self.stallCount = stallCount
        self.recoverableErrorCount = recoverableErrorCount
        self.mediaRequestFailureCount = mediaRequestFailureCount
        self.slowMediaTransferCount = slowMediaTransferCount
        self.variantSwitchCount = variantSwitchCount
        self.variantSwitchFailureCount = variantSwitchFailureCount
        self.initialStartupDuration = initialStartupDuration
    }
}
