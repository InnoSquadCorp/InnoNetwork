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

    let programDateTime: Date?
    let encryption: HLSLiveAES128Encryption?
    let initializationSegment: HLSLiveInitializationSegment?

    init(record: HLSLiveSegmentRecord) {
        self.sequenceNumber = record.sequenceNumber
        self.duration = record.duration
        self.url = record.url
        self.byteRange = record.byteRange
        self.beginsDiscontinuity = record.beginsDiscontinuity
        self.isGap = record.isGap
        self.programDateTime = record.programDateTime
        self.encryption = record.encryption.map(
            HLSLiveAES128Encryption.init(record:)
        )
        self.initializationSegment = record.initializationSegment.map(
            HLSLiveInitializationSegment.init(record:)
        )
    }

    init(
        sequenceNumber: Int64,
        duration: TimeInterval,
        url: URL,
        byteRange: HLSByteRange?,
        beginsDiscontinuity: Bool,
        isGap: Bool,
        programDateTime: Date? = nil,
        encryption: HLSLiveAES128Encryption? = nil,
        initializationSegment: HLSLiveInitializationSegment? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.duration = duration
        self.url = url
        self.byteRange = byteRange
        self.beginsDiscontinuity = beginsDiscontinuity
        self.isGap = isGap
        self.programDateTime = programDateTime
        self.encryption = encryption
        self.initializationSegment = initializationSegment
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

    init(resource: HLSLowLatencyResourceIdentity) {
        self.url = resource.url
        self.byteRange = resource.byteRange
        self.encryption = nil
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

    let resourceContext: HLSLowLatencyResourceContext?

    var initializationSegment: HLSLiveInitializationSegment? {
        resourceContext?.initializationMap.map(
            HLSLiveInitializationSegment.init(resource:)
        )
    }

    public static func == (
        lhs: HLSLivePartialSegment,
        rhs: HLSLivePartialSegment
    ) -> Bool {
        lhs.mediaSequenceNumber == rhs.mediaSequenceNumber
            && lhs.partIndex == rhs.partIndex
            && lhs.duration == rhs.duration
            && lhs.url == rhs.url
            && lhs.byteRange == rhs.byteRange
            && lhs.isIndependent == rhs.isIndependent
            && lhs.isGap == rhs.isGap
    }

    init(record: HLSLivePartialSegmentRecord) {
        self.mediaSequenceNumber = record.mediaSequenceNumber
        self.partIndex = record.partIndex
        self.duration = record.duration
        self.url = record.url
        self.byteRange = record.byteRange
        self.isIndependent = record.isIndependent
        self.isGap = record.isGap
        self.resourceContext = record.resourceContext
    }

    init(
        mediaSequenceNumber: Int64,
        partIndex: Int,
        duration: TimeInterval,
        url: URL,
        byteRange: HLSByteRange?,
        isIndependent: Bool,
        isGap: Bool,
        resourceContext: HLSLowLatencyResourceContext? = nil
    ) {
        self.mediaSequenceNumber = mediaSequenceNumber
        self.partIndex = partIndex
        self.duration = duration
        self.url = url
        self.byteRange = byteRange
        self.isIndependent = isIndependent
        self.isGap = isGap
        self.resourceContext = resourceContext
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

    /// The request strategy that produced this response.
    public let reloadMode: HLSLiveReloadMode

    /// Whether this response used `EXT-X-SKIP` history reconstruction.
    public let isDeltaUpdate: Bool

    /// Whether the media playlist declared `EXT-X-ENDLIST`.
    public let isEnded: Bool

    /// Parsed and estimated HTTP freshness, without raw header values.
    public let httpFreshness: HLSLiveHTTPFreshness?

    let initializationSegments: [HLSLiveInitializationSegment]
    let encryptionMethod: String?
    let unsupportedEncryptionMethod: String?
    let multivariantVariables: [String: String]

    var unsupportedEncryptionMethodForRecording: String? {
        unsupportedEncryptionMethod
            ?? encryptionMethod.flatMap {
                $0 == "AES-128" ? nil : $0
            }
    }

    init(
        playlist: HLSPlaylist,
        segments: [HLSLiveSegment],
        partialSegments: [HLSLivePartialSegment],
        dateRanges: [HLSDateRange],
        selectedVariant: HLSVariant? = nil,
        availableRenditions: [HLSRendition] = [],
        pathwayID: String? = nil,
        generation: Int,
        reloadMode: HLSLiveReloadMode = .initial,
        isDeltaUpdate: Bool,
        isEnded: Bool,
        httpFreshness: HLSLiveHTTPFreshness? = nil,
        initializationSegments: [HLSLiveInitializationSegment] = [],
        encryptionMethod: String? = nil,
        unsupportedEncryptionMethod: String? = nil,
        multivariantVariables: [String: String] = [:]
    ) {
        self.playlist = playlist
        self.segments = segments
        self.partialSegments = partialSegments
        self.dateRanges = dateRanges
        self.selectedVariant = selectedVariant
        self.availableRenditions = availableRenditions
        self.pathwayID = pathwayID
        self.generation = generation
        self.reloadMode = reloadMode
        self.isDeltaUpdate = isDeltaUpdate
        self.isEnded = isEnded
        self.httpFreshness = httpFreshness
        self.initializationSegments = initializationSegments
        self.encryptionMethod = encryptionMethod
        self.unsupportedEncryptionMethod = unsupportedEncryptionMethod
        self.multivariantVariables = multivariantVariables
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
