import Foundation
import InnoNetworkHLS

struct HLSLiveAES128Encryption: Equatable, Sendable {
    let keyURL: URL
    let initializationVector: Data

    init(record: HLSLiveAES128EncryptionRecord) {
        self.keyURL = record.keyURL
        self.initializationVector = record.initializationVector
    }
}

/// One complete media segment in a reconstructed live window.
public struct HLSLiveSegment: Equatable, Sendable {
    /// The absolute media-sequence number.
    public let sequenceNumber: Int64

    /// Segment duration in seconds.
    public let duration: TimeInterval

    /// The resolved media URL.
    public let url: URL

    /// The byte range when the segment shares a resource.
    public let byteRange: HLSByteRange?

    /// Whether this segment begins after a discontinuity boundary.
    public let beginsDiscontinuity: Bool

    /// Whether the segment is intentionally unavailable.
    public let isGap: Bool

    let encryption: HLSLiveAES128Encryption?

    init(record: HLSLiveSegmentRecord) {
        self.sequenceNumber = record.sequenceNumber
        self.duration = record.duration
        self.url = record.url
        self.byteRange = record.byteRange
        self.beginsDiscontinuity = record.beginsDiscontinuity
        self.isGap = record.isGap
        self.encryption = record.encryption.map(
            HLSLiveAES128Encryption.init(record:)
        )
    }

    init(
        sequenceNumber: Int64,
        duration: TimeInterval,
        url: URL,
        byteRange: HLSByteRange?,
        beginsDiscontinuity: Bool,
        isGap: Bool,
        encryption: HLSLiveAES128Encryption? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.duration = duration
        self.url = url
        self.byteRange = byteRange
        self.beginsDiscontinuity = beginsDiscontinuity
        self.isGap = isGap
        self.encryption = encryption
    }
}

struct HLSLiveInitializationSegment: Equatable, Sendable {
    let url: URL
    let byteRange: HLSByteRange?
    let encryption: HLSLiveAES128Encryption?

    init(record: HLSLiveInitializationSegmentRecord) {
        self.url = record.url
        self.byteRange = record.byteRange
        self.encryption = record.encryption.map(
            HLSLiveAES128Encryption.init(record:)
        )
    }
}

/// One partial media segment at the live edge.
public struct HLSLivePartialSegment: Equatable, Sendable {
    /// The parent media-sequence number.
    public let mediaSequenceNumber: Int64

    /// The zero-based part index within the parent segment.
    public let partIndex: Int

    /// Partial-segment duration in seconds.
    public let duration: TimeInterval

    /// The resolved partial media URL.
    public let url: URL

    /// The byte range when the part shares a resource.
    public let byteRange: HLSByteRange?

    /// Whether decoding can begin from this part.
    public let isIndependent: Bool

    /// Whether the part is intentionally unavailable.
    public let isGap: Bool

    init(record: HLSLivePartialSegmentRecord) {
        self.mediaSequenceNumber = record.mediaSequenceNumber
        self.partIndex = record.partIndex
        self.duration = record.duration
        self.url = record.url
        self.byteRange = record.byteRange
        self.isIndependent = record.isIndependent
        self.isGap = record.isGap
    }

    init(
        mediaSequenceNumber: Int64,
        partIndex: Int,
        duration: TimeInterval,
        url: URL,
        byteRange: HLSByteRange?,
        isIndependent: Bool,
        isGap: Bool
    ) {
        self.mediaSequenceNumber = mediaSequenceNumber
        self.partIndex = partIndex
        self.duration = duration
        self.url = url
        self.byteRange = byteRange
        self.isIndependent = isIndependent
        self.isGap = isGap
    }
}

/// One successfully parsed and, when necessary, delta-reconstructed live
/// playlist response.
public struct HLSLivePlaylistSnapshot: Equatable, Sendable {
    /// The parsed response playlist.
    public let playlist: HLSPlaylist

    /// The complete segments visible after delta reconstruction.
    public let segments: [HLSLiveSegment]

    /// The partial segments currently advertised at the live edge.
    public let partialSegments: [HLSLivePartialSegment]

    /// Active Date Ranges after applying recently removed identifiers.
    public let dateRanges: [HLSDateRange]

    /// The selected stream variant, or `nil` for a direct media playlist.
    public let selectedVariant: HLSVariant?

    /// Renditions advertised for the selected Content Steering pathway.
    public let availableRenditions: [HLSRendition]

    /// The selected Content Steering pathway identifier.
    public let pathwayID: String?

    /// Zero-based successful reload generation.
    public let generation: Int

    /// Whether this response used `EXT-X-SKIP` history reconstruction.
    public let isDeltaUpdate: Bool

    /// Whether the media playlist declared `EXT-X-ENDLIST`.
    public let isEnded: Bool

    let initializationSegments: [HLSLiveInitializationSegment]
    let encryptionMethod: String?

    init(
        playlist: HLSPlaylist,
        segments: [HLSLiveSegment],
        partialSegments: [HLSLivePartialSegment],
        dateRanges: [HLSDateRange],
        selectedVariant: HLSVariant? = nil,
        availableRenditions: [HLSRendition] = [],
        pathwayID: String? = nil,
        generation: Int,
        isDeltaUpdate: Bool,
        isEnded: Bool,
        initializationSegments: [HLSLiveInitializationSegment] = [],
        encryptionMethod: String? = nil
    ) {
        self.playlist = playlist
        self.segments = segments
        self.partialSegments = partialSegments
        self.dateRanges = dateRanges
        self.selectedVariant = selectedVariant
        self.availableRenditions = availableRenditions
        self.pathwayID = pathwayID
        self.generation = generation
        self.isDeltaUpdate = isDeltaUpdate
        self.isEnded = isEnded
        self.initializationSegments = initializationSegments
        self.encryptionMethod = encryptionMethod
    }
}

/// Live reload failures that are distinct from transport or playlist parsing
/// errors.
public enum HLSLiveError: Error, Equatable, Sendable {
    /// The resolved live target was not a media playlist.
    case mediaPlaylistRequired

    /// A delta response referenced history absent from the previous snapshot.
    case deltaBaseUnavailable

    /// The playlist URL could not be represented as a reload URL.
    case invalidReloadURL

    /// A playlist sequence, part index, or generation exceeded its range.
    case sequenceOverflow
}

extension HLSLiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .mediaPlaylistRequired:
            return "The selected live target is not a media playlist."
        case .deltaBaseUnavailable:
            return "The delta playlist could not be reconstructed from the previous live window."
        case .invalidReloadURL:
            return "The live playlist URL could not be represented as a reload URL."
        case .sequenceOverflow:
            return "The live playlist sequence exceeded its supported range."
        }
    }
}
