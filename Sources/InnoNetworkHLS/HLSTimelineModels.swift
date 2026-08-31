import Foundation

/// A preferred playback start declared by `EXT-X-START`.
public struct HLSPreferredStartPosition: Equatable, Sendable {
    /// Seconds from the beginning, or a negative offset from the end.
    public let timeOffset: TimeInterval

    /// Whether samples before the offset should be skipped precisely.
    public let isPrecise: Bool

    /// Creates preferred HLS playback-start metadata.
    public init(
        timeOffset: TimeInterval,
        isPrecise: Bool = false
    ) {
        self.timeOffset = timeOffset
        self.isPrecise = isPrecise
    }
}

/// Absolute program time associated with one media segment.
public struct HLSProgramDateTime: Equatable, Sendable {
    /// Zero-based index of the segment to which the timestamp applies.
    public let segmentIndex: Int

    /// The absolute date of the segment's first media sample.
    public let date: Date

    /// Creates an absolute segment timestamp.
    public init(segmentIndex: Int, date: Date) {
        self.segmentIndex = segmentIndex
        self.date = date
    }
}

/// A trigger declared by an `EXT-X-DATERANGE` `CUE` attribute.
public enum HLSDateRangeCue: Equatable, Hashable, Sendable {
    /// Trigger before primary playback begins.
    case pre

    /// Trigger after primary playback completes.
    case post

    /// Trigger only once.
    case once
}

/// The external source of an Apple HLS interstitial.
public enum HLSInterstitialSource: Equatable, Sendable {
    /// One interstitial HLS asset.
    case asset(URL)

    /// A JSON asset list that describes one or more interstitial assets.
    case assetList(URL)
}

/// Typed Apple HLS interstitial metadata.
public struct HLSInterstitial: Equatable, Sendable {
    /// The asset or asset-list source.
    public let source: HLSInterstitialSource

    /// Primary-timeline offset at which playback resumes.
    public let resumeOffset: TimeInterval?

    /// Maximum interstitial playout duration.
    public let playoutLimit: TimeInterval?

    /// Whether coordinated players may receive different content.
    public let contentVariability: HLSInterstitialContentVariability

    /// Effective timeline occupancy, defaulting to a single point.
    public let timelineOccupancy: HLSInterstitialTimelineOccupancy

    /// Effective timeline style, defaulting to a highlighted presentation.
    public let timelineStyle: HLSInterstitialTimelineStyle

    /// Navigation restrictions that application or system UI should enforce.
    public let navigationRestrictions: Set<HLSInterstitialNavigationRestriction>

    /// Optional server-authored skip-control presentation metadata.
    ///
    /// Asset-list JSON may override individual values after resolution.
    public let skipControl: HLSInterstitialSkipControl?

    /// Creates typed interstitial metadata.
    public init(
        source: HLSInterstitialSource,
        resumeOffset: TimeInterval? = nil,
        playoutLimit: TimeInterval? = nil,
        contentVariability: HLSInterstitialContentVariability = .mayVary,
        timelineOccupancy: HLSInterstitialTimelineOccupancy = .point,
        timelineStyle: HLSInterstitialTimelineStyle = .highlight,
        navigationRestrictions:
            Set<HLSInterstitialNavigationRestriction> = [],
        skipControl: HLSInterstitialSkipControl? = nil
    ) {
        self.source = source
        self.resumeOffset = resumeOffset
        self.playoutLimit = playoutLimit
        self.contentVariability = contentVariability
        self.timelineOccupancy = timelineOccupancy
        self.timelineStyle = timelineStyle
        self.navigationRestrictions = navigationRestrictions
        self.skipControl = skipControl
    }
}

/// An external Date Range resource declared through `X-URI`.
public struct HLSDateRangeResource: Equatable, Sendable {
    /// The resolved resource URL.
    public let url: URL

    /// Optional target Date Range identifier for preload metadata.
    public let targetID: String?

    /// Optional target Date Range class for preload metadata.
    public let targetClass: String?

    /// Creates an external Date Range resource description.
    public init(
        url: URL,
        targetID: String? = nil,
        targetClass: String? = nil
    ) {
        self.url = url
        self.targetID = targetID
        self.targetClass = targetClass
    }
}

/// A bounded resource announced before its target Date Range.
public struct HLSDateRangePreload: Equatable, Sendable {
    /// The resource to request before the target Date Range appears.
    public let resource: HLSDateRangeResource

    /// The target Date Range identifier.
    public let targetID: String

    /// The target Date Range class.
    public let targetClass: String

    /// Optional duration adjustment for a client joining mid-schedule.
    public let durationAtJoin: TimeInterval?

    /// Whether the containing playlist permits preloading.
    ///
    /// Preload Date Ranges in playlists with `EXT-X-ENDLIST` are retained as
    /// metadata but are not eligible for a network request.
    public let isEligible: Bool

    init(
        resource: HLSDateRangeResource,
        targetID: String,
        targetClass: String,
        durationAtJoin: TimeInterval?,
        isEligible: Bool
    ) {
        self.resource = resource
        self.targetID = targetID
        self.targetClass = targetClass
        self.durationAtJoin = durationAtJoin
        self.isEligible = isEligible
    }

    /// Returns whether this preload describes the supplied target.
    public func matches(_ dateRange: HLSDateRange) -> Bool {
        dateRange.id == targetID
            && dateRange.className == targetClass
    }
}

/// Consolidated metadata from one or more `EXT-X-DATERANGE` tags.
public struct HLSDateRange: Equatable, Sendable {
    /// Playlist-unique Date Range identifier.
    public let id: String

    /// Optional class that defines the Date Range semantics.
    public let className: String?

    /// Absolute beginning of the Date Range.
    public let startDate: Date

    /// Explicit absolute end, when declared.
    public let endDate: Date?

    /// Actual duration in seconds, when declared.
    public let duration: TimeInterval?

    /// Expected duration in seconds, when declared.
    public let plannedDuration: TimeInterval?

    /// Ordered trigger identifiers.
    public let cues: [HLSDateRangeCue]

    /// Whether the next range of the same class ends this range.
    public let endsOnNext: Bool

    /// Typed interstitial metadata for the Apple interstitial class.
    public let interstitial: HLSInterstitial?

    /// An external schedule or preload resource declared through `X-URI`.
    public let externalResource: HLSDateRangeResource?

    /// Typed preload metadata for `com.apple.hls.preload`.
    public let preload: HLSDateRangePreload?

    /// Extension and SCTE-35 attribute names, without their potentially
    /// sensitive values.
    public let extensionAttributeNames: [String]

    /// Creates consolidated Date Range metadata.
    public init(
        id: String,
        className: String? = nil,
        startDate: Date,
        endDate: Date? = nil,
        duration: TimeInterval? = nil,
        plannedDuration: TimeInterval? = nil,
        cues: [HLSDateRangeCue] = [],
        endsOnNext: Bool = false,
        interstitial: HLSInterstitial? = nil,
        externalResource: HLSDateRangeResource? = nil,
        preload: HLSDateRangePreload? = nil,
        extensionAttributeNames: [String] = []
    ) {
        self.id = id
        self.className = className
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.plannedDuration = plannedDuration
        self.cues = cues
        self.endsOnNext = endsOnNext
        self.interstitial = interstitial
        self.externalResource = externalResource
        self.preload = preload
        self.extensionAttributeNames = extensionAttributeNames
    }
}

/// A bounded Date Range resource retained for a later target.
public struct HLSPreloadedDateRangeResource: Equatable, Sendable {
    /// The URL from which the resource was loaded.
    public let sourceURL: URL

    /// The target Date Range identifier.
    public let targetID: String

    /// The target Date Range class.
    public let targetClass: String

    /// The bounded resource bytes.
    public let data: Data

    init(
        sourceURL: URL,
        targetID: String,
        targetClass: String,
        data: Data
    ) {
        self.sourceURL = sourceURL
        self.targetID = targetID
        self.targetClass = targetClass
        self.data = data
    }

    func matches(_ dateRange: HLSDateRange) -> Bool {
        dateRange.id == targetID
            && dateRange.className == targetClass
            && dateRange.externalResource?.url == sourceURL
    }
}

/// One ordered member of a resolved Date Range Schedule.
public struct HLSDateRangeScheduleEntry: Equatable, Sendable {
    /// The scheduled Date Range.
    public let dateRange: HLSDateRange

    /// Recursively resolved content when the member is another schedule.
    public let nestedSchedule: HLSDateRangeSchedule?

    init(
        dateRange: HLSDateRange,
        nestedSchedule: HLSDateRangeSchedule?
    ) {
        self.dateRange = dateRange
        self.nestedSchedule = nestedSchedule
    }
}

/// A bounded, recursively resolved Apple HLS Date Range Schedule.
public struct HLSDateRangeSchedule: Equatable, Sendable {
    /// The Date Range that declared this schedule.
    public let source: HLSDateRange

    /// In-range members in server-defined order.
    public let entries: [HLSDateRangeScheduleEntry]

    init(
        source: HLSDateRange,
        entries: [HLSDateRangeScheduleEntry]
    ) {
        self.source = source
        self.entries = entries
    }
}
