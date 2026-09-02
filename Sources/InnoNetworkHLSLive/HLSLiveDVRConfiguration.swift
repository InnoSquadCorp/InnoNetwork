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

/// Controls speculative loading of Low-Latency HLS media hints.
public enum HLSLiveDVRPreloadPolicy: Equatable, Sendable {
    /// Performs no speculative media transfers.
    case disabled

    /// Preloads clear `PART` and `MAP` hints and reuses only exact matches.
    case unencryptedMedia
}

/// Controls whether a recording may persist URL-free recovery checkpoints.
public enum HLSLiveDVRRecoveryPolicy: Equatable, Sendable {
    /// Removes staging after ordinary interruption and does not allow resume.
    case disabled

    /// Persists an owned checkpoint at each coherent complete-segment
    /// boundary. Rolling multi-track recordings publish after the current
    /// snapshot's retained tracks have been aligned.
    case resumable
}

/// Controls what happens when a live DVR recording reaches its limits.
public enum HLSLiveDVRRetentionPolicy: Equatable, Sendable {
    /// Commits the retained prefix when any configured limit is reached.
    case stopAtLimit

    /// Evicts the oldest complete presentation data and keeps recording.
    case rollingWindow
}

/// Groups live DVR interruption-recovery behavior.
///
/// Recovery remains opt-in because checkpoints intentionally retain media
/// files between process lifetimes.
public struct HLSLiveDVRRecoveryPack: Sendable {
    let policy: HLSLiveDVRRecoveryPolicy

    /// Creates a recovery pack. The default preserves legacy cleanup behavior.
    public init(
        policy: HLSLiveDVRRecoveryPolicy = .disabled
    ) {
        self.policy = policy
    }
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

/// Groups bounded speculative `PART` and `MAP` loading for live DVR.
///
/// Preloading is an opt-in latency optimization. Hinted bytes remain in
/// temporary storage and are reused only after a later playlist confirms the
/// resource identity and clear-media presentation context.
public struct HLSLiveDVRPreloadPack: Sendable {
    let policy: HLSLiveDVRPreloadPolicy
    let maximumResourceBytes: Int
    let maximumTotalBytes: Int64

    /// Creates bounded media-hint preloading.
    ///
    /// Each resource is clamped to `1...134,217,728` bytes and all pending
    /// preloads to `1...268,435,456` bytes. Transfer failures fall back to the
    /// ordinary DVR request path. Encrypted media is never preloaded here.
    public init(
        policy: HLSLiveDVRPreloadPolicy = .disabled,
        maximumResourceBytes: Int = 8 * 1_024 * 1_024,
        maximumTotalBytes: Int64 = 16 * 1_024 * 1_024
    ) {
        self.policy = policy
        self.maximumResourceBytes = min(
            128 * 1_024 * 1_024,
            max(1, maximumResourceBytes)
        )
        self.maximumTotalBytes = min(
            256 * 1_024 * 1_024,
            max(1, maximumTotalBytes)
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
    private let subtitleProvenance: HLSSubtitleProvenancePolicy
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
        self.init(
            audio: audio,
            video: video,
            subtitles: subtitles,
            subtitleProvenance: HLSSubtitleProvenancePolicy(),
            maximumRenditionsPerKind: maximumRenditionsPerKind
        )
    }

    /// Creates live DVR selection with explicit generated/translated
    /// subtitle behavior.
    public init(
        audio: HLSLiveDVRRenditionSelectionPolicy = .defaultOrFirst,
        video: HLSLiveDVRRenditionSelectionPolicy = .disabled,
        subtitles: HLSLiveDVRRenditionSelectionPolicy = .disabled,
        subtitleProvenance: HLSSubtitleProvenancePolicy,
        maximumRenditionsPerKind: Int = 8
    ) {
        self.audio = audio
        self.video = video
        self.subtitles = subtitles
        self.subtitleProvenance = subtitleProvenance
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

    var resolvedSubtitleProvenance: HLSSubtitleProvenancePolicy {
        subtitleProvenance
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

    /// The maximum bytes retained across initialization, media segments, and
    /// packaged interstitials.
    public let maximumTotalMediaBytes: Int64

    /// The timeout applied to each media request.
    public let requestTimeout: TimeInterval

    /// Destination-volume capacity validation applied while staging media.
    public let diskCapacityPolicy: HLSDiskCapacityPolicy

    /// The behavior applied when retained media reaches a configured limit.
    public let retentionPolicy: HLSLiveDVRRetentionPolicy

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
        self.init(
            maximumDuration: maximumDuration,
            maximumSegmentCount: maximumSegmentCount,
            maximumMediaResourceBytes: maximumMediaResourceBytes,
            maximumTotalMediaBytes: maximumTotalMediaBytes,
            requestTimeout: requestTimeout,
            diskCapacityPolicy: diskCapacityPolicy,
            retentionPolicy: .stopAtLimit
        )
    }

    /// Creates bounded live DVR limits with explicit retention behavior.
    ///
    /// Rolling retention keeps at least the newest complete segment. A single
    /// media resource must still fit both the per-resource and total byte
    /// limits.
    public init(
        maximumDuration: TimeInterval = 30 * 60,
        maximumSegmentCount: Int = 900,
        maximumMediaResourceBytes: Int = 128 * 1_024 * 1_024,
        maximumTotalMediaBytes: Int64 = 8 * 1_024 * 1_024 * 1_024,
        requestTimeout: TimeInterval = 60,
        diskCapacityPolicy: HLSDiskCapacityPolicy = .required(
            minimumAvailableCapacity: 512 * 1_024 * 1_024
        ),
        retentionPolicy: HLSLiveDVRRetentionPolicy
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
        self.retentionPolicy = retentionPolicy
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
    let preloading: HLSLiveDVRPreloadPack
    let recovery: HLSLiveDVRRecoveryPack
    let interstitials: HLSLiveDVRInterstitialPack

    private init(
        limits: HLSLiveDVRLimitPack,
        startPosition: HLSLiveDVRStartPosition,
        renditions: HLSLiveDVRRenditionPack,
        parts: HLSLiveDVRPartPack,
        preloading: HLSLiveDVRPreloadPack,
        recovery: HLSLiveDVRRecoveryPack,
        interstitials: HLSLiveDVRInterstitialPack
    ) {
        self.limits = limits
        self.startPosition = startPosition
        self.renditions = renditions
        self.parts = parts
        self.preloading = preloading
        self.recovery = recovery
        self.interstitials = interstitials
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
        advanced(
            limits: limits,
            startPosition: startPosition,
            renditions: renditions,
            parts: parts,
            interstitials: HLSLiveDVRInterstitialPack()
        )
    }

    /// Returns explicitly tuned live DVR behavior with interstitials.
    public static func advanced(
        limits: HLSLiveDVRLimitPack = HLSLiveDVRLimitPack(),
        startPosition: HLSLiveDVRStartPosition =
            .nextCompletedSegment,
        renditions: HLSLiveDVRRenditionPack =
            HLSLiveDVRRenditionPack(),
        parts: HLSLiveDVRPartPack = HLSLiveDVRPartPack(),
        interstitials: HLSLiveDVRInterstitialPack
    ) -> HLSLiveDVRConfiguration {
        advanced(
            limits: limits,
            startPosition: startPosition,
            renditions: renditions,
            parts: parts,
            preloading: HLSLiveDVRPreloadPack(),
            recovery: HLSLiveDVRRecoveryPack(),
            interstitials: interstitials
        )
    }

    /// Returns explicitly tuned live DVR behavior with media preloading.
    public static func advanced(
        limits: HLSLiveDVRLimitPack = HLSLiveDVRLimitPack(),
        startPosition: HLSLiveDVRStartPosition =
            .nextCompletedSegment,
        renditions: HLSLiveDVRRenditionPack =
            HLSLiveDVRRenditionPack(),
        parts: HLSLiveDVRPartPack = HLSLiveDVRPartPack(),
        preloading: HLSLiveDVRPreloadPack
    ) -> HLSLiveDVRConfiguration {
        advanced(
            limits: limits,
            startPosition: startPosition,
            renditions: renditions,
            parts: parts,
            preloading: preloading,
            interstitials: HLSLiveDVRInterstitialPack()
        )
    }

    /// Returns explicitly tuned live DVR behavior with media preloading and
    /// interstitials.
    public static func advanced(
        limits: HLSLiveDVRLimitPack = HLSLiveDVRLimitPack(),
        startPosition: HLSLiveDVRStartPosition =
            .nextCompletedSegment,
        renditions: HLSLiveDVRRenditionPack =
            HLSLiveDVRRenditionPack(),
        parts: HLSLiveDVRPartPack = HLSLiveDVRPartPack(),
        preloading: HLSLiveDVRPreloadPack,
        interstitials: HLSLiveDVRInterstitialPack
    ) -> HLSLiveDVRConfiguration {
        advanced(
            limits: limits,
            startPosition: startPosition,
            renditions: renditions,
            parts: parts,
            preloading: preloading,
            recovery: HLSLiveDVRRecoveryPack(),
            interstitials: interstitials
        )
    }

    /// Returns explicitly tuned live DVR behavior with interruption recovery.
    public static func advanced(
        limits: HLSLiveDVRLimitPack = HLSLiveDVRLimitPack(),
        startPosition: HLSLiveDVRStartPosition =
            .nextCompletedSegment,
        renditions: HLSLiveDVRRenditionPack =
            HLSLiveDVRRenditionPack(),
        parts: HLSLiveDVRPartPack = HLSLiveDVRPartPack(),
        recovery: HLSLiveDVRRecoveryPack
    ) -> HLSLiveDVRConfiguration {
        advanced(
            limits: limits,
            startPosition: startPosition,
            renditions: renditions,
            parts: parts,
            recovery: recovery,
            interstitials: HLSLiveDVRInterstitialPack()
        )
    }

    /// Returns explicitly tuned live DVR behavior with recovery and
    /// interstitials.
    public static func advanced(
        limits: HLSLiveDVRLimitPack = HLSLiveDVRLimitPack(),
        startPosition: HLSLiveDVRStartPosition =
            .nextCompletedSegment,
        renditions: HLSLiveDVRRenditionPack =
            HLSLiveDVRRenditionPack(),
        parts: HLSLiveDVRPartPack = HLSLiveDVRPartPack(),
        recovery: HLSLiveDVRRecoveryPack,
        interstitials: HLSLiveDVRInterstitialPack
    ) -> HLSLiveDVRConfiguration {
        advanced(
            limits: limits,
            startPosition: startPosition,
            renditions: renditions,
            parts: parts,
            preloading: HLSLiveDVRPreloadPack(),
            recovery: recovery,
            interstitials: interstitials
        )
    }

    /// Returns explicitly tuned live DVR behavior with preloading and
    /// interruption recovery.
    public static func advanced(
        limits: HLSLiveDVRLimitPack = HLSLiveDVRLimitPack(),
        startPosition: HLSLiveDVRStartPosition =
            .nextCompletedSegment,
        renditions: HLSLiveDVRRenditionPack =
            HLSLiveDVRRenditionPack(),
        parts: HLSLiveDVRPartPack = HLSLiveDVRPartPack(),
        preloading: HLSLiveDVRPreloadPack,
        recovery: HLSLiveDVRRecoveryPack
    ) -> HLSLiveDVRConfiguration {
        advanced(
            limits: limits,
            startPosition: startPosition,
            renditions: renditions,
            parts: parts,
            preloading: preloading,
            recovery: recovery,
            interstitials: HLSLiveDVRInterstitialPack()
        )
    }

    /// Returns explicitly tuned live DVR behavior with preloading, recovery,
    /// and interstitials.
    public static func advanced(
        limits: HLSLiveDVRLimitPack = HLSLiveDVRLimitPack(),
        startPosition: HLSLiveDVRStartPosition =
            .nextCompletedSegment,
        renditions: HLSLiveDVRRenditionPack =
            HLSLiveDVRRenditionPack(),
        parts: HLSLiveDVRPartPack = HLSLiveDVRPartPack(),
        preloading: HLSLiveDVRPreloadPack,
        recovery: HLSLiveDVRRecoveryPack,
        interstitials: HLSLiveDVRInterstitialPack
    ) -> HLSLiveDVRConfiguration {
        HLSLiveDVRConfiguration(
            limits: limits,
            startPosition: startPosition,
            renditions: renditions,
            parts: parts,
            preloading: preloading,
            recovery: recovery,
            interstitials: interstitials
        )
    }
}
