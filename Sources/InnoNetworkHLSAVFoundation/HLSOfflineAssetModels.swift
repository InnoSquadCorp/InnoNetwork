#if canImport(AVFoundation) && !os(tvOS) && !os(watchOS)
import Foundation

/// Why a stored HLS package is or is not ready for offline playback.
public enum HLSOfflineAssetReadinessState: Equatable, Sendable {
    /// The system-managed package is no longer present.
    case missing

    /// A file exists at the location but is not a regular package directory.
    case invalidPackage

    /// AVFoundation does not recognize the directory as a cached asset.
    case unrecognizedPackage

    /// AVFoundation recognizes the cache but has no complete offline rendition.
    case incomplete

    /// AVFoundation reports a complete rendition for offline playback.
    case ready
}

/// How much of an authored Custom Media Selection scheme is cached.
public enum HLSOfflineCustomMediaSelectionCoverage: Equatable, Sendable {
    /// The media-selection group has no authored custom scheme.
    case notAuthored

    /// The operating system cannot inspect custom-scheme cache coverage.
    case unavailable

    /// None of the authored languages or selector settings are cached.
    case none

    /// Some, but not all, authored languages or selector settings are cached.
    case partial

    /// Inspection bounds prevented a complete coverage determination.
    case indeterminate

    /// Every authored language and selector setting is cached.
    case complete
}

/// One media choice that AVFoundation reports as available offline.
public struct HLSOfflineMediaSelectionOptionSnapshot: Equatable, Sendable {
    /// Whether the cached choice is audio, video, subtitles, or captions.
    public let kind: HLSPlaybackMediaKind

    /// The authored IETF BCP 47 language tag, when safe and available.
    ///
    /// Values containing control characters or exceeding 128 UTF-8 bytes are
    /// omitted.
    public let languageTag: String?

    /// Whether the asset marks this choice as the group's default.
    public let isDefault: Bool
}

/// Cached choices for one AVFoundation media-selection group.
public struct HLSOfflineMediaSelectionGroupSnapshot: Equatable, Sendable {
    /// The group represented by this snapshot.
    public let kind: HLSPlaybackMediaKind

    /// Media choices available for offline operations in native order.
    ///
    /// At most 256 choices are retained.
    public let options: [HLSOfflineMediaSelectionOptionSnapshot]

    /// Whether later native media choices were omitted.
    public let didTruncateOptions: Bool

    /// Custom-scheme languages that AVFoundation reports as cached.
    ///
    /// At most 256 safe, unique language tags are retained in native order.
    public let cachedCustomLanguageTags: [String]

    /// Whether native values were omitted because of safety or count bounds.
    public let didTruncateCustomLanguageTags: Bool

    /// Authored Custom Media Selection coverage for this group.
    public let customMediaSelectionCoverage: HLSOfflineCustomMediaSelectionCoverage
}

/// A bounded, value-only readiness report for one stored HLS package.
public struct HLSOfflineAssetReadinessSnapshot: Equatable, Sendable {
    /// The package's current offline-playback readiness.
    public let state: HLSOfflineAssetReadinessState

    /// Cached audio, video, and legible groups that could be inspected.
    public let mediaSelectionGroups: [HLSOfflineMediaSelectionGroupSnapshot]

    /// Whether every supported media-selection group finished inspection.
    ///
    /// This is `false` when package readiness prevented inspection or when
    /// AVFoundation failed to load at least one group.
    public let didCompleteMediaSelectionInspection: Bool

    /// Whether AVFoundation reports a complete offline rendition.
    public var isPlayableOffline: Bool {
        state == .ready
    }
}
#endif
