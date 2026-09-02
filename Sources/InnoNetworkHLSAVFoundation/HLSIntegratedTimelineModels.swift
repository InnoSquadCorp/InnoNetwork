import Foundation

/// The content represented by one integrated-timeline segment.
public enum HLSIntegratedTimelineSegmentKind: Equatable, Sendable {
    /// Content from the primary player item.
    case primary

    /// Content from a scheduled interstitial event.
    case interstitial

    /// A future AVFoundation segment kind not modeled by this bridge.
    case other
}

/// A value-only segment on AVFoundation's integrated playback timeline.
public struct HLSIntegratedTimelineSegmentSnapshot: Equatable, Sendable {
    /// Whether this segment contains primary or interstitial content.
    public let kind: HLSIntegratedTimelineSegmentKind

    /// The range in the primary item or interstitial event's source timeline.
    ///
    /// The value is `nil` when AVFoundation reports an invalid, indefinite,
    /// negative-duration, or non-finite range.
    public let sourceTimeRange: Range<TimeInterval>?

    /// The range occupied in the integrated timeline.
    ///
    /// A point interstitial is represented by an empty range whose lower and
    /// upper bounds are equal.
    public let timelineTimeRange: Range<TimeInterval>?

    /// Readily available media ranges in the integrated timeline.
    ///
    /// At most 256 native ranges are retained in AVFoundation order.
    public let loadedTimelineTimeRanges: [Range<TimeInterval>]

    /// Whether later loaded ranges were omitted from this snapshot.
    public let didTruncateLoadedTimeRanges: Bool

    /// The wall-clock start date, when the primary item provides date mapping.
    public let startDate: Date?

    /// The associated interstitial event identifier, when this is an
    /// interstitial segment.
    ///
    /// Asset URLs, template items, custom attributes, and asset-list responses
    /// are intentionally excluded. The value is limited to 1,024 UTF-8 bytes.
    public let interstitialIdentifier: String?

    /// Whether the associated interstitial identifier was UTF-8 truncated.
    public let didTruncateInterstitialIdentifier: Bool
}

/// A bounded, immutable view of AVFoundation's integrated playback timeline.
public struct HLSIntegratedTimelineSnapshot: Equatable, Sendable {
    /// Total integrated duration in seconds, when finite and nonnegative.
    public let duration: TimeInterval?

    /// The playhead position in the integrated timeline, when finite.
    public let currentTime: TimeInterval?

    /// The playhead's wall-clock date, when date mapping is available.
    public let currentDate: Date?

    /// The current segment's index in ``segments``, when retained.
    public let currentSegmentIndex: Int?

    /// Chronological, contiguous primary and interstitial segments.
    ///
    /// At most 1,024 segments are retained.
    public let segments: [HLSIntegratedTimelineSegmentSnapshot]

    /// Whether later native segments were omitted from this snapshot.
    public let didTruncateSegments: Bool
}

/// Why an integrated-timeline snapshot was emitted.
public enum HLSIntegratedTimelineUpdateReason: Equatable, Sendable {
    /// The initial state emitted when observation starts.
    case initial

    /// The sampled integrated playhead or date changed.
    case playheadChanged

    /// Primary or interstitial segments changed.
    case segmentsChanged

    /// Playback entered a different segment.
    case currentSegmentChanged

    /// Readily available media ranges changed.
    case loadedTimeRangesChanged

    /// A future AVFoundation reason not modeled by this bridge.
    case other
}

/// One immutable integrated-timeline observation update.
public struct HLSIntegratedTimelineUpdate: Equatable, Sendable {
    /// The native condition that caused this update.
    public let reason: HLSIntegratedTimelineUpdateReason

    /// The complete bounded snapshot captured for this update.
    public let snapshot: HLSIntegratedTimelineSnapshot
}
