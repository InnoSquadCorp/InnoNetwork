import Foundation

/// Reload and hold-back behavior declared by `EXT-X-SERVER-CONTROL`.
public struct HLSServerControl: Equatable, Sendable {
    /// Whether a client may use blocking playlist reloads.
    public let canBlockReload: Bool

    /// The duration a client may request to skip, in seconds.
    public let canSkipUntil: Double?

    /// Whether skipped reloads may include recently removed Date Ranges.
    public let canSkipDateRanges: Bool

    /// The recommended distance from the live edge, in seconds.
    public let holdBack: Double?

    /// The recommended partial-segment distance from the live edge.
    public let partialSegmentHoldBack: Double?
}

/// One partial media segment declared by `EXT-X-PART`.
public struct HLSPartialSegment: Equatable, Sendable {
    /// The resolved partial-segment URL.
    public let url: URL

    /// The partial-segment duration in seconds.
    public let duration: Double

    /// The zero-based complete-segment index this part precedes.
    public let segmentIndex: Int

    /// Whether the part can be decoded without an earlier part.
    public let isIndependent: Bool

    /// Whether the part is intentionally unavailable.
    public let isGap: Bool

    /// The resolved byte range, when declared.
    public let byteRange: HLSByteRange?

    package let resourceContext: HLSLowLatencyResourceContext?

    public static func == (
        lhs: HLSPartialSegment,
        rhs: HLSPartialSegment
    ) -> Bool {
        lhs.url == rhs.url
            && lhs.duration == rhs.duration
            && lhs.segmentIndex == rhs.segmentIndex
            && lhs.isIndependent == rhs.isIndependent
            && lhs.isGap == rhs.isGap
            && lhs.byteRange == rhs.byteRange
    }
}

/// The resource kind advertised by `EXT-X-PRELOAD-HINT`.
public enum HLSPreloadHintType: Equatable, Hashable, Sendable {
    /// The next partial media segment.
    case partialSegment

    /// The next media initialization section.
    case initializationMap

    /// A key used by upcoming encrypted media.
    case encryptionKey
}

/// Key-delivery metadata advertised by a `TYPE=KEY` preload hint.
///
/// This model never fetches or stores key bytes.
public struct HLSEncryptionKeyPreload: Equatable, Sendable {
    /// The HLS encryption method that will appear in `EXT-X-KEY`.
    public let method: String

    /// The key format, defaulting to `identity`.
    public let keyFormat: String

    /// Supported key-format versions in declaration order.
    public let keyFormatVersions: [Int]

    /// Whether the declaration uses the identity key format.
    public var isIdentityFormat: Bool {
        keyFormat.lowercased() == "identity"
    }
}

/// One anticipated Low-Latency HLS resource.
public struct HLSPreloadHint: Equatable, Sendable {
    /// Whether this anticipates a part, initialization map, or key.
    public let type: HLSPreloadHintType

    /// The resolved anticipated-resource URL.
    public let url: URL

    /// The byte-range start, or `nil` when the implied start is zero.
    public let byteRangeStart: Int64?

    /// The byte-range length, when advertised.
    public let byteRangeLength: Int64?

    /// The estimated first media date that requires the resource.
    public let estimatedFirstUseDate: Date?

    /// Key metadata when ``type`` is ``HLSPreloadHintType/encryptionKey``.
    public let encryptionKey: HLSEncryptionKeyPreload?

    package let resourceContext: HLSLowLatencyResourceContext?

    public static func == (
        lhs: HLSPreloadHint,
        rhs: HLSPreloadHint
    ) -> Bool {
        lhs.type == rhs.type
            && lhs.url == rhs.url
            && lhs.byteRangeStart == rhs.byteRangeStart
            && lhs.byteRangeLength == rhs.byteRangeLength
            && lhs.estimatedFirstUseDate == rhs.estimatedFirstUseDate
            && lhs.encryptionKey == rhs.encryptionKey
    }
}

/// The latest position advertised for another rendition playlist.
public struct HLSRenditionReport: Equatable, Sendable {
    /// The resolved rendition-playlist URL.
    public let url: URL

    /// The last media-sequence number available in that rendition.
    public let lastMediaSequenceNumber: Int64?

    /// The last partial-segment index available in that rendition.
    public let lastPartialSegmentIndex: Int?
}

/// The history omitted by one `EXT-X-SKIP` delta update.
public struct HLSDeltaUpdate: Equatable, Sendable {
    /// The number of complete media segments omitted from the response.
    public let skippedSegmentCount: Int

    /// Recently removed Date Range identifiers, without source values.
    public let recentlyRemovedDateRangeIDs: [String]
}

/// Typed Low-Latency HLS metadata for a media playlist.
public struct HLSLowLatencyMetadata: Equatable, Sendable {
    /// Server reload and hold-back behavior.
    public let serverControl: HLSServerControl?

    /// The maximum partial-segment duration, in seconds.
    public let partialSegmentTargetDuration: Double?

    /// Partial media segments in playlist order.
    public let partialSegments: [HLSPartialSegment]

    /// Anticipated resources in declaration order.
    public let preloadHints: [HLSPreloadHint]

    /// Other-rendition live-edge reports in declaration order.
    public let renditionReports: [HLSRenditionReport]

    /// Delta-update history omission, when declared.
    public let deltaUpdate: HLSDeltaUpdate?

    package let initializationMaps: [HLSLowLatencyInitializationMap]

    public static func == (
        lhs: HLSLowLatencyMetadata,
        rhs: HLSLowLatencyMetadata
    ) -> Bool {
        lhs.serverControl == rhs.serverControl
            && lhs.partialSegmentTargetDuration
                == rhs.partialSegmentTargetDuration
            && lhs.partialSegments == rhs.partialSegments
            && lhs.preloadHints == rhs.preloadHints
            && lhs.renditionReports == rhs.renditionReports
            && lhs.deltaUpdate == rhs.deltaUpdate
    }
}

package struct HLSLowLatencyResourceIdentity: Equatable, Sendable {
    package let url: URL
    package let byteRange: HLSByteRange?
    package let openEndedByteRangeStart: Int64?
}

package struct HLSLowLatencyEncryptionIdentity: Equatable, Sendable {
    package let method: String
    package let keyURL: URL?
    package let keyFormat: String
    package let keyFormatVersions: [Int]
    package let initializationVector: Data?
}

package struct HLSLowLatencyResourceContext: Equatable, Sendable {
    package let discontinuitySequence: Int64
    package let initializationMap: HLSLowLatencyResourceIdentity?
    package let encryption: HLSLowLatencyEncryptionIdentity?
}

package struct HLSLowLatencyInitializationMap: Equatable, Sendable {
    package let resource: HLSLowLatencyResourceIdentity
    package let context: HLSLowLatencyResourceContext
}
