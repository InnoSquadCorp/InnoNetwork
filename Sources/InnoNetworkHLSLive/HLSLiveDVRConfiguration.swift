import Foundation
import InnoNetworkHLS

/// Selects the first complete segment retained by a live DVR recording.
public enum HLSLiveDVRStartPosition: Equatable, Sendable {
    /// Start with the first complete segment that appears after observation
    /// begins.
    case nextCompletedSegment

    /// Retain the complete segments already present in the initial live
    /// window.
    case currentWindow
}

/// Controls which external renditions are retained by live DVR.
public enum HLSLiveDVRRenditionSelectionPolicy: Equatable, Sendable {
    /// Omits external renditions of this kind.
    case disabled

    /// Keeps the advertised default, then an autoselect rendition, then the
    /// first rendition when the group has no preferred marker.
    case defaultOrFirst

    /// Keeps one rendition for each preferred BCP 47 language, in preference
    /// order. If no language matches, the default-or-first rendition is kept.
    case preferredLanguages([String])

    /// Keeps renditions whose names exactly match the supplied order.
    case named([String])

    /// Keeps every external rendition referenced by the selected variant.
    case all
}

/// Controls whether live DVR may stage Low-Latency HLS partial segments.
public enum HLSLiveDVRPartCapturePolicy: Equatable, Sendable {
    /// Waits for complete media segments and performs no part requests.
    case disabled

    /// Starts staging at an independent part zero and promotes a complete,
    /// matching part set when its parent segment appears.
    case independent
}

/// Groups bounded Low-Latency HLS part staging for live DVR.
///
/// Part capture is an opt-in transfer optimization. The committed package
/// still contains complete VOD segments and never exposes temporary parts.
public struct HLSLiveDVRPartPack: Sendable {
    let policy: HLSLiveDVRPartCapturePolicy
    let maximumStagedPartCount: Int
    let maximumStagedPartBytes: Int64

    /// Creates bounded temporary part staging.
    ///
    /// The staged-part count is clamped to `1...1,024` and staged bytes to
    /// `1...1,073,741,824`. Identity-format AES-128 parts are not staged
    /// because part-level IV metadata is unavailable; their complete parent
    /// segments continue through the normal DVR path.
    public init(
        policy: HLSLiveDVRPartCapturePolicy = .disabled,
        maximumStagedPartCount: Int = 64,
        maximumStagedPartBytes: Int64 = 64 * 1_024 * 1_024
    ) {
        self.policy = policy
        self.maximumStagedPartCount = min(
            1_024,
            max(1, maximumStagedPartCount)
        )
        self.maximumStagedPartBytes = min(
            1 * 1_024 * 1_024 * 1_024,
            max(1, maximumStagedPartBytes)
        )
    }
}

/// Groups bounded external-rendition selection for live DVR packaging.
///
/// Stored values are opaque immutable input.
/// The conservative default keeps one external audio rendition and omits
/// alternate video and subtitles until the application opts in.
public struct HLSLiveDVRRenditionPack: Sendable {
    let audio: HLSLiveDVRRenditionSelectionPolicy
    let video: HLSLiveDVRRenditionSelectionPolicy
    let subtitles: HLSLiveDVRRenditionSelectionPolicy
    let maximumRenditionsPerKind: Int

    /// Creates bounded live DVR rendition selection.
    ///
    /// The per-kind limit is clamped to `1...32`.
    public init(
        audio: HLSLiveDVRRenditionSelectionPolicy = .defaultOrFirst,
        video: HLSLiveDVRRenditionSelectionPolicy = .disabled,
        subtitles: HLSLiveDVRRenditionSelectionPolicy = .disabled,
        maximumRenditionsPerKind: Int = 8
    ) {
        self.audio = audio
        self.video = video
        self.subtitles = subtitles
        self.maximumRenditionsPerKind = min(
            max(1, maximumRenditionsPerKind),
            32
        )
    }

    func policy(
        for kind: HLSRenditionKind
    ) -> HLSLiveDVRRenditionSelectionPolicy {
        switch kind {
        case .audio:
            return audio
        case .video:
            return video
        case .subtitles:
            return subtitles
        case .closedCaptions:
            return .disabled
        }
    }
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

    /// Destination-volume capacity validation applied while staging media.
    public let diskCapacityPolicy: HLSDiskCapacityPolicy

    /// Creates bounded live DVR limits.
    ///
    /// Duration is clamped to `1...86,400` seconds, segment count to
    /// `1...10,000`, each resource to at most 1 GiB, total media to at most
    /// 64 GiB, and request timeout to `1...300` seconds. Non-finite duration
    /// and timeout values use their defaults. The default disk policy keeps
    /// 512 MiB available beyond the current operation's staged bytes.
    public init(
        maximumDuration: TimeInterval = 30 * 60,
        maximumSegmentCount: Int = 900,
        maximumMediaResourceBytes: Int = 128 * 1_024 * 1_024,
        maximumTotalMediaBytes: Int64 = 8 * 1_024 * 1_024 * 1_024,
        requestTimeout: TimeInterval = 60,
        diskCapacityPolicy: HLSDiskCapacityPolicy = .required(
            minimumAvailableCapacity: 512 * 1_024 * 1_024
        )
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
        self.diskCapacityPolicy = diskCapacityPolicy
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
    let renditions: HLSLiveDVRRenditionPack
    let parts: HLSLiveDVRPartPack

    private init(
        limits: HLSLiveDVRLimitPack,
        startPosition: HLSLiveDVRStartPosition,
        renditions: HLSLiveDVRRenditionPack,
        parts: HLSLiveDVRPartPack
    ) {
        self.limits = limits
        self.startPosition = startPosition
        self.renditions = renditions
        self.parts = parts
    }

    /// Returns conservative record-from-now defaults.
    public static func safeDefaults() -> HLSLiveDVRConfiguration {
        advanced()
    }

    /// Returns explicitly tuned live DVR behavior.
    public static func advanced(
        limits: HLSLiveDVRLimitPack = HLSLiveDVRLimitPack(),
        startPosition: HLSLiveDVRStartPosition =
            .nextCompletedSegment,
        renditions: HLSLiveDVRRenditionPack =
            HLSLiveDVRRenditionPack(),
        parts: HLSLiveDVRPartPack = HLSLiveDVRPartPack()
    ) -> HLSLiveDVRConfiguration {
        HLSLiveDVRConfiguration(
            limits: limits,
            startPosition: startPosition,
            renditions: renditions,
            parts: parts
        )
    }
}
