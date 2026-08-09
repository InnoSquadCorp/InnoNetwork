import Foundation

/// Selects the first complete segment retained by a live DVR recording.
public enum HLSLiveDVRStartPosition: Equatable, Sendable {
    /// Start with the first complete segment that appears after observation
    /// begins.
    case nextCompletedSegment

    /// Retain the complete segments already present in the initial live
    /// window.
    case currentWindow
}

/// Groups the hard duration, count, and byte limits for a live DVR recording.
public struct HLSLiveDVRLimitPack: Sendable {
    private static let maximumDurationLimit: TimeInterval = 24 * 60 * 60
    private static let maximumSegmentCountLimit = 10_000
    private static let maximumMediaResourceByteLimit =
        1 * 1_024 * 1_024 * 1_024
    private static let maximumTotalMediaByteLimit: Int64 =
        64 * 1_024 * 1_024 * 1_024
    private static let maximumRequestTimeout: TimeInterval = 300

    /// The maximum retained playback duration.
    public let maximumDuration: TimeInterval

    /// The maximum number of retained complete segments.
    public let maximumSegmentCount: Int

    /// The maximum bytes accepted from one media request.
    public let maximumMediaResourceBytes: Int

    /// The maximum bytes retained across initialization and media segments.
    public let maximumTotalMediaBytes: Int64

    /// The timeout applied to each media request.
    public let requestTimeout: TimeInterval

    /// Creates bounded live DVR limits.
    ///
    /// Duration is clamped to `1...86,400` seconds, segment count to
    /// `1...10,000`, each resource to at most 1 GiB, total media to at most
    /// 64 GiB, and request timeout to `1...300` seconds. Non-finite duration
    /// and timeout values use their defaults.
    public init(
        maximumDuration: TimeInterval = 30 * 60,
        maximumSegmentCount: Int = 900,
        maximumMediaResourceBytes: Int = 128 * 1_024 * 1_024,
        maximumTotalMediaBytes: Int64 = 8 * 1_024 * 1_024 * 1_024,
        requestTimeout: TimeInterval = 60
    ) {
        self.maximumDuration = Self.normalized(
            maximumDuration,
            fallback: 30 * 60,
            maximum: Self.maximumDurationLimit
        )
        self.maximumSegmentCount = min(
            Self.maximumSegmentCountLimit,
            max(1, maximumSegmentCount)
        )
        self.maximumMediaResourceBytes = min(
            Self.maximumMediaResourceByteLimit,
            max(1, maximumMediaResourceBytes)
        )
        self.maximumTotalMediaBytes = min(
            Self.maximumTotalMediaByteLimit,
            max(1, maximumTotalMediaBytes)
        )
        self.requestTimeout = Self.normalized(
            requestTimeout,
            fallback: 60,
            maximum: Self.maximumRequestTimeout
        )
    }

    private static func normalized(
        _ value: TimeInterval,
        fallback: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else {
            return fallback
        }
        return min(maximum, max(1, value))
    }
}

/// Configures a bounded, atomically committed live DVR recording.
public struct HLSLiveDVRConfiguration: Sendable {
    let limits: HLSLiveDVRLimitPack
    let startPosition: HLSLiveDVRStartPosition

    private init(
        limits: HLSLiveDVRLimitPack,
        startPosition: HLSLiveDVRStartPosition
    ) {
        self.limits = limits
        self.startPosition = startPosition
    }

    /// Returns conservative record-from-now defaults.
    public static func safeDefaults() -> HLSLiveDVRConfiguration {
        advanced()
    }

    /// Returns explicitly tuned live DVR behavior.
    public static func advanced(
        limits: HLSLiveDVRLimitPack = HLSLiveDVRLimitPack(),
        startPosition: HLSLiveDVRStartPosition =
            .nextCompletedSegment
    ) -> HLSLiveDVRConfiguration {
        HLSLiveDVRConfiguration(
            limits: limits,
            startPosition: startPosition
        )
    }
}
