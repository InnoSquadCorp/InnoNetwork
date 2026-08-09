import Foundation
import InnoNetwork

/// A parsed HLS playlist.
public struct HLSPlaylist: Equatable, Sendable {
    /// The kind of playlist represented by the parsed document.
    public enum Kind: Equatable, Sendable {
        /// A multivariant playlist containing one or more alternative streams.
        case multivariant

        /// A media playlist containing media segments.
        case media
    }

    /// The URL from which relative playlist references are resolved.
    public let sourceURL: URL

    /// Whether the document is a multivariant or media playlist.
    public let kind: Kind

    /// Variants advertised by a multivariant playlist.
    ///
    /// This array is empty for media playlists.
    public let variants: [HLSVariant]

    /// I-frame-only variants advertised for trick-play navigation.
    ///
    /// This array is empty for media playlists and when the multivariant
    /// playlist does not advertise `EXT-X-I-FRAME-STREAM-INF`.
    public let iFrameVariants: [HLSVariant]

    /// Alternate renditions advertised by a multivariant playlist.
    ///
    /// This array is empty for media playlists.
    public let renditions: [HLSRendition]

    /// The declared `EXT-X-VERSION`, or `nil` when the playlist omits it.
    public let protocolVersion: Int?

    /// Whether each media segment can be decoded without another segment.
    public let hasIndependentSegments: Bool

    /// The Content Steering declaration in a multivariant playlist.
    public let contentSteering: HLSContentSteering?

    /// Session metadata shared by every selection in a multivariant playlist.
    public let sessionData: [HLSSessionData]

    /// Session key declarations shared by multivariant media playlists.
    ///
    /// Key bytes are never fetched by playlist inspection.
    public let sessionKeys: [HLSSessionKey]

    /// The preferred playback start declared by `EXT-X-START`.
    public let preferredStartPosition: HLSPreferredStartPosition?

    /// Absolute timestamps associated with media segments.
    ///
    /// This array is empty for multivariant playlists.
    public let programDateTimes: [HLSProgramDateTime]

    /// Consolidated `EXT-X-DATERANGE` metadata in declaration order.
    ///
    /// This array is empty for multivariant playlists.
    public let dateRanges: [HLSDateRange]

    /// Low-Latency HLS delivery metadata, when declared.
    ///
    /// This describes authoring and reload behavior. It does not imply that
    /// the raw or offline-package downloaders fetch partial segments.
    public let lowLatency: HLSLowLatencyMetadata?

    /// The media container produced by concatenating this media playlist.
    ///
    /// This value is `nil` for multivariant playlists.
    public let mediaContainer: HLSMediaContainer?

    /// The media playlist's target duration in seconds.
    ///
    /// This value is `nil` for multivariant playlists and for leniently
    /// inspected media playlists that omit `EXT-X-TARGETDURATION`.
    public let targetDuration: Int?

    /// The first complete segment's media-sequence number.
    ///
    /// This value is `0` when a media playlist omits
    /// `EXT-X-MEDIA-SEQUENCE`, and `nil` for multivariant playlists.
    public let mediaSequence: Int64?

    /// The first complete segment's discontinuity-sequence number.
    ///
    /// This value is `0` when a media playlist omits
    /// `EXT-X-DISCONTINUITY-SEQUENCE`, and `nil` for multivariant playlists.
    public let discontinuitySequence: Int64?

    /// The media playlist's declared mutability contract.
    public let mediaPlaylistType: HLSMediaPlaylistType?

    /// Approximate bitrates applied to complete media segments.
    ///
    /// Segments using `EXT-X-BYTERANGE` are intentionally omitted because
    /// `EXT-X-BITRATE` does not apply to them.
    public let segmentBitrates: [HLSSegmentBitrate]

    let media: HLSMediaPlaylist?
    let separateAudioGroupIDs: Set<String>

    /// Creates a parsed HLS playlist value.
    public init(
        sourceURL: URL,
        kind: Kind,
        variants: [HLSVariant],
        iFrameVariants: [HLSVariant] = [],
        renditions: [HLSRendition] = [],
        protocolVersion: Int? = nil,
        hasIndependentSegments: Bool = false,
        contentSteering: HLSContentSteering? = nil,
        sessionData: [HLSSessionData] = [],
        sessionKeys: [HLSSessionKey] = [],
        preferredStartPosition: HLSPreferredStartPosition? = nil,
        programDateTimes: [HLSProgramDateTime] = [],
        dateRanges: [HLSDateRange] = [],
        lowLatency: HLSLowLatencyMetadata? = nil,
        mediaContainer: HLSMediaContainer? = nil
    ) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.variants = variants
        self.iFrameVariants = iFrameVariants
        self.renditions = renditions
        self.protocolVersion = protocolVersion
        self.hasIndependentSegments = hasIndependentSegments
        self.contentSteering = contentSteering
        self.sessionData = sessionData
        self.sessionKeys = sessionKeys
        self.preferredStartPosition = preferredStartPosition
        self.programDateTimes = programDateTimes
        self.dateRanges = dateRanges
        self.lowLatency = lowLatency
        self.mediaContainer = mediaContainer
        self.targetDuration = nil
        self.mediaSequence = nil
        self.discontinuitySequence = nil
        self.mediaPlaylistType = nil
        self.segmentBitrates = []
        self.media = nil
        self.separateAudioGroupIDs = []
    }

    init(
        sourceURL: URL,
        kind: Kind,
        variants: [HLSVariant],
        iFrameVariants: [HLSVariant],
        renditions: [HLSRendition],
        protocolVersion: Int?,
        hasIndependentSegments: Bool,
        contentSteering: HLSContentSteering?,
        sessionData: [HLSSessionData],
        sessionKeys: [HLSSessionKey],
        preferredStartPosition: HLSPreferredStartPosition?,
        programDateTimes: [HLSProgramDateTime],
        dateRanges: [HLSDateRange],
        lowLatency: HLSLowLatencyMetadata?,
        mediaContainer: HLSMediaContainer?,
        targetDuration: Int?,
        mediaSequence: Int64?,
        discontinuitySequence: Int64?,
        mediaPlaylistType: HLSMediaPlaylistType?,
        segmentBitrates: [HLSSegmentBitrate],
        media: HLSMediaPlaylist?,
        separateAudioGroupIDs: Set<String>
    ) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.variants = variants
        self.iFrameVariants = iFrameVariants
        self.renditions = renditions
        self.protocolVersion = protocolVersion
        self.hasIndependentSegments = hasIndependentSegments
        self.contentSteering = contentSteering
        self.sessionData = sessionData
        self.sessionKeys = sessionKeys
        self.preferredStartPosition = preferredStartPosition
        self.programDateTimes = programDateTimes
        self.dateRanges = dateRanges
        self.lowLatency = lowLatency
        self.mediaContainer = mediaContainer
        self.targetDuration = targetDuration
        self.mediaSequence = mediaSequence
        self.discontinuitySequence = discontinuitySequence
        self.mediaPlaylistType = mediaPlaylistType
        self.segmentBitrates = segmentBitrates
        self.media = media
        self.separateAudioGroupIDs = separateAudioGroupIDs
    }
}

/// The media role of an alternate HLS rendition.
public enum HLSRenditionKind: Equatable, Hashable, Sendable {
    /// An alternate or supplemental audio track.
    case audio

    /// A subtitle track, usually delivered as WebVTT or fragmented MP4.
    case subtitles

    /// An alternate video track, such as another camera angle.
    case video

    /// In-band CEA-608 or CEA-708 closed captions.
    case closedCaptions
}

/// One alternate rendition advertised by `EXT-X-MEDIA`.
public struct HLSRendition: Equatable, Sendable {
    /// Whether this is audio, video, subtitles, or closed-caption metadata.
    public let kind: HLSRenditionKind

    /// The group identifier referenced by a stream variant.
    public let groupID: String

    /// The human-readable rendition name.
    public let name: String

    /// The BCP 47 language tag advertised by the playlist.
    public let language: String?

    /// A BCP 47 language tag associated with this rendition.
    public let associatedLanguage: String?

    /// The stable rendition identifier used across playlist reloads.
    public let stableID: String?

    /// An in-band media identifier, when advertised.
    public let instreamID: String?

    /// Media characteristic tags in playlist order.
    public let characteristics: [String]

    /// The raw HLS audio channel configuration, such as `2` or `6/JOC`.
    public let channels: String?

    /// The maximum simultaneous audio-channel count.
    public var audioChannelCount: Int? {
        channels?
            .split(separator: "/", maxSplits: 1)
            .first
            .flatMap { Int($0) }
    }

    /// Audio sample bit depth, when advertised.
    public let audioBitDepth: Int?

    /// Audio sample rate in hertz, when advertised.
    public let audioSampleRate: Int?

    /// The resolved rendition-playlist URL, or `nil` for in-band media.
    public let url: URL?

    /// Whether the playlist marks this rendition as the group default.
    public let isDefault: Bool

    /// Whether clients may automatically choose this rendition.
    public let isAutoselect: Bool

    /// Whether this subtitle rendition contains forced narrative content.
    public let isForced: Bool

    /// Creates alternate-rendition metadata.
    public init(
        kind: HLSRenditionKind,
        groupID: String,
        name: String,
        language: String? = nil,
        associatedLanguage: String? = nil,
        stableID: String? = nil,
        instreamID: String? = nil,
        characteristics: [String] = [],
        channels: String? = nil,
        audioBitDepth: Int? = nil,
        audioSampleRate: Int? = nil,
        url: URL? = nil,
        isDefault: Bool = false,
        isAutoselect: Bool = false,
        isForced: Bool = false
    ) {
        self.kind = kind
        self.groupID = groupID
        self.name = name
        self.language = language
        self.associatedLanguage = associatedLanguage
        self.stableID = stableID
        self.instreamID = instreamID
        self.characteristics = characteristics
        self.channels = channels
        self.audioBitDepth = audioBitDepth
        self.audioSampleRate = audioSampleRate
        self.url = url
        self.isDefault = isDefault
        self.isAutoselect = isAutoselect
        self.isForced = isForced
    }
}

/// The closed-caption declaration attached to an HLS variant.
public enum HLSClosedCaptionReference: Equatable, Sendable {
    /// The variant explicitly carries no closed captions.
    case explicitlyNone

    /// The variant references an `EXT-X-MEDIA` closed-caption group.
    case group(String)
}

/// A media container that InnoNetworkHLS can assemble without transcoding.
public enum HLSMediaContainer: Equatable, Sendable {
    /// MPEG-2 transport-stream segments, conventionally saved as `.ts`.
    case mpegTransportStream

    /// An initialization segment followed by fragmented MP4 media fragments.
    case fragmentedMP4

    /// The conventional file extension for the assembled media.
    public var fileExtension: String {
        switch self {
        case .mpegTransportStream:
            return "ts"
        case .fragmentedMP4:
            return "mp4"
        }
    }
}

/// An HLS media feature that the single-file assembler cannot preserve safely.
public enum HLSUnsupportedMediaFeature: Equatable, Hashable, Sendable {
    /// A segment boundary changes timestamps, tracks, or encoding parameters.
    case discontinuity

    /// A segment is intentionally unavailable and represents a timeline gap.
    case gap

    /// The playlist contains only independently decodable I-frames.
    case iFramesOnly

    /// The playlist changes or repeats its media initialization section.
    case multipleInitializationSections

    /// An interstitial references media outside the primary playlist.
    case interstitialResource

    /// A Date Range references an external schedule or preload resource.
    case dateRangeExternalResource

    /// Partial media segments require a low-latency-aware persistence path.
    case partialSegments

    /// A preload hint references a resource outside the complete segment plan.
    case preloadHintResource

    /// A rendition report references another live media playlist.
    case renditionReportResource

    /// A delta update omits media history required for durable packaging.
    case deltaUpdate
}

/// One stream variant advertised by an HLS multivariant playlist.
public struct HLSVariant: Equatable, Sendable {
    /// The resolved URL of the variant playlist.
    public let url: URL

    /// Peak bandwidth in bits per second, when advertised.
    public let bandwidth: Int?

    /// Average bandwidth in bits per second, when advertised.
    public let averageBandwidth: Int?

    /// The playlist author's relative quality-of-experience score.
    public let score: Double?

    /// Encoded video width, when advertised.
    public let width: Int?

    /// Encoded video height, when advertised.
    public let height: Int?

    /// The audio rendition group referenced by the variant, when advertised.
    ///
    /// The referenced group can describe either in-band audio or separate
    /// rendition playlists.
    public let audioGroupID: String?

    /// The subtitle rendition group referenced by the variant, when advertised.
    public let subtitleGroupID: String?

    /// The video rendition group referenced by the variant, when advertised.
    public let videoGroupID: String?

    /// The variant's closed-caption declaration, when advertised.
    public let closedCaptions: HLSClosedCaptionReference?

    /// Codec identifiers advertised by `CODECS`, in playlist order.
    public let codecs: [String]

    /// Enhancement-layer codecs advertised by `SUPPLEMENTAL-CODECS`.
    public let supplementalCodecs: [String]

    /// Encoded frame rate, when advertised.
    public let frameRate: Double?

    /// The advertised video dynamic range, such as `SDR`, `PQ`, or `HLG`.
    public let videoRange: String?

    /// The output copy-protection requirement advertised by `HDCP-LEVEL`.
    public let hdcpLevel: HLSHDCPLevel?

    /// Accepted content-protection robustness configurations.
    public let allowedContentProtectionConfigurations: [HLSAllowedContentProtectionConfiguration]

    /// Specialized video layouts required by portions of the variant.
    public let requiredVideoLayouts: [HLSRequiredVideoLayout]

    /// The stable variant identifier used across playlist reloads.
    public let stableID: String?

    /// The content-steering pathway identifier.
    public let pathwayID: String?

    /// Creates an HLS variant description.
    public init(
        url: URL,
        bandwidth: Int? = nil,
        averageBandwidth: Int? = nil,
        score: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        audioGroupID: String? = nil,
        subtitleGroupID: String? = nil,
        videoGroupID: String? = nil,
        closedCaptions: HLSClosedCaptionReference? = nil,
        codecs: [String] = [],
        supplementalCodecs: [String] = [],
        frameRate: Double? = nil,
        videoRange: String? = nil,
        stableID: String? = nil,
        pathwayID: String? = nil
    ) {
        self.url = url
        self.bandwidth = bandwidth
        self.averageBandwidth = averageBandwidth
        self.score = score
        self.width = width
        self.height = height
        self.audioGroupID = audioGroupID
        self.subtitleGroupID = subtitleGroupID
        self.videoGroupID = videoGroupID
        self.closedCaptions = closedCaptions
        self.codecs = codecs
        self.supplementalCodecs = supplementalCodecs
        self.frameRate = frameRate
        self.videoRange = videoRange
        self.hdcpLevel = nil
        self.allowedContentProtectionConfigurations = []
        self.requiredVideoLayouts = []
        self.stableID = stableID
        self.pathwayID = pathwayID
    }

    init(
        url: URL,
        bandwidth: Int?,
        averageBandwidth: Int?,
        score: Double?,
        width: Int?,
        height: Int?,
        audioGroupID: String?,
        subtitleGroupID: String?,
        videoGroupID: String?,
        closedCaptions: HLSClosedCaptionReference?,
        codecs: [String],
        supplementalCodecs: [String],
        frameRate: Double?,
        videoRange: String?,
        hdcpLevel: HLSHDCPLevel?,
        allowedContentProtectionConfigurations:
            [HLSAllowedContentProtectionConfiguration],
        requiredVideoLayouts: [HLSRequiredVideoLayout],
        stableID: String?,
        pathwayID: String?
    ) {
        self.url = url
        self.bandwidth = bandwidth
        self.averageBandwidth = averageBandwidth
        self.score = score
        self.width = width
        self.height = height
        self.audioGroupID = audioGroupID
        self.subtitleGroupID = subtitleGroupID
        self.videoGroupID = videoGroupID
        self.closedCaptions = closedCaptions
        self.codecs = codecs
        self.supplementalCodecs = supplementalCodecs
        self.frameRate = frameRate
        self.videoRange = videoRange
        self.hdcpLevel = hdcpLevel
        self.allowedContentProtectionConfigurations =
            allowedContentProtectionConfigurations
        self.requiredVideoLayouts = requiredVideoLayouts
        self.stableID = stableID
        self.pathwayID = pathwayID
    }
}

/// An advisory snapshot of the media selected for an HLS download.
///
/// Preparation performs playlist resolution and validation without creating
/// files or reserving a destination. A later download resolves the playlists
/// again so it cannot silently execute a stale network plan.
public struct HLSDownloadPreparation: Equatable, Sendable {
    /// The source URL supplied to ``HLSDownloader/prepare(sourceURL:)``.
    public let sourceURL: URL

    /// The final media-playlist URL after variant selection and redirects.
    public let mediaPlaylistURL: URL

    /// The selected multivariant stream, or `nil` for a direct media playlist.
    public let selectedVariant: HLSVariant?

    /// Renditions advertised by the source multivariant playlist.
    public let availableRenditions: [HLSRendition]

    /// The container that the single-file assembler will produce.
    public let mediaContainer: HLSMediaContainer

    /// The number of media segments described by the selected playlist.
    public let segmentCount: Int

    /// The bounded HTTP transfers planned after contiguous range coalescing.
    public let resourceTransferCount: Int

    init(
        sourceURL: URL,
        mediaPlaylistURL: URL,
        selectedVariant: HLSVariant?,
        availableRenditions: [HLSRendition],
        mediaContainer: HLSMediaContainer,
        segmentCount: Int,
        resourceTransferCount: Int
    ) {
        self.sourceURL = sourceURL
        self.mediaPlaylistURL = mediaPlaylistURL
        self.selectedVariant = selectedVariant
        self.availableRenditions = availableRenditions
        self.mediaContainer = mediaContainer
        self.segmentCount = segmentCount
        self.resourceTransferCount = resourceTransferCount
    }
}

/// The committed result of a completed HLS file download.
public struct HLSDownloadReceipt: Equatable, Sendable {
    /// The final file URL committed by the downloader.
    public let destinationURL: URL

    /// The committed file size in bytes.
    public let byteCount: Int64

    /// The assembled media container.
    public let mediaContainer: HLSMediaContainer

    /// The selected multivariant stream, or `nil` for a direct media playlist.
    public let selectedVariant: HLSVariant?

    /// Transfers reused from a validated durable resume checkpoint.
    public let resumedResourceTransferCount: Int

    init(
        destinationURL: URL,
        byteCount: Int64,
        mediaContainer: HLSMediaContainer,
        selectedVariant: HLSVariant?,
        resumedResourceTransferCount: Int
    ) {
        self.destinationURL = destinationURL
        self.byteCount = byteCount
        self.mediaContainer = mediaContainer
        self.selectedVariant = selectedVariant
        self.resumedResourceTransferCount = resumedResourceTransferCount
    }
}

/// Byte-level progress emitted while an HLS VOD stream is downloaded.
public struct HLSDownloadProgress: Equatable, Sendable {
    /// Bytes received in the event's latest media chunk.
    public let bytesWritten: Int64

    /// Media bytes currently retained for the logical download.
    ///
    /// This value can decrease when a failed resource attempt is discarded
    /// before retry or when AES-128 PKCS#7 padding is removed.
    public let totalBytesWritten: Int64

    /// Expected total media bytes, or `nil` while one or more resource
    /// responses have not advertised a content length.
    public let totalBytesExpectedToWrite: Int64?

    /// Whether the complete byte total is still unknown.
    public var isIndeterminate: Bool {
        totalBytesExpectedToWrite == nil
    }

    /// Byte-based completion fraction, or `nil` while the total is unknown.
    public var fractionCompleted: Double? {
        guard let totalBytesExpectedToWrite else {
            return nil
        }
        guard totalBytesExpectedToWrite > 0 else {
            return totalBytesWritten == 0 ? 0 : nil
        }
        return min(
            1,
            Double(totalBytesWritten)
                / Double(totalBytesExpectedToWrite)
        )
    }

    /// Byte-based completion percentage, or `nil` while the total is unknown.
    public var percentCompleted: Int? {
        fractionCompleted.map { Int($0 * 100) }
    }

    /// Progress before any media bytes have been received.
    public static let zero = HLSDownloadProgress(
        bytesWritten: 0,
        totalBytesWritten: 0,
        totalBytesExpectedToWrite: nil
    )
}

/// Events emitted while an HLS VOD stream is downloaded.
public enum HLSDownloadEvent: Sendable {
    /// Byte-level download progress.
    case progress(HLSDownloadProgress)

    /// The final media file was committed to the requested destination.
    case completed(URL)

    /// The download failed with a typed HLS error.
    case failed(HLSDownloadError)

    /// The consuming task or event stream cancelled the download.
    case cancelled
}

public struct HLSByteRange: Equatable, Sendable {
    /// The zero-based byte offset.
    public let offset: Int64

    /// The positive byte length.
    public let length: Int64

    init?(offset: Int64, length: Int64) {
        guard offset >= 0, length > 0 else {
            return nil
        }
        let (_, overflow) = offset.addingReportingOverflow(length)
        guard !overflow else {
            return nil
        }
        self.offset = offset
        self.length = length
    }

    var endOffset: Int64 {
        offset + length
    }
}

struct HLSMediaResource: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case initialization
        case segment
    }

    let kind: Kind
    let url: URL
    let byteRange: HLSByteRange?
    let encryption: HLSAES128Encryption?
    let duration: TimeInterval?
    let beginsDiscontinuity: Bool
    let isGap: Bool

    static func initialization(
        _ url: URL,
        byteRange: HLSByteRange? = nil,
        encryption: HLSAES128Encryption? = nil
    ) -> Self {
        Self(
            kind: .initialization,
            url: url,
            byteRange: byteRange,
            encryption: encryption,
            duration: nil,
            beginsDiscontinuity: false,
            isGap: false
        )
    }

    static func segment(
        _ url: URL,
        byteRange: HLSByteRange? = nil,
        encryption: HLSAES128Encryption? = nil,
        duration: TimeInterval? = nil,
        beginsDiscontinuity: Bool = false,
        isGap: Bool = false
    ) -> Self {
        Self(
            kind: .segment,
            url: url,
            byteRange: byteRange,
            encryption: encryption,
            duration: duration,
            beginsDiscontinuity: beginsDiscontinuity,
            isGap: isGap
        )
    }
}

struct HLSAES128Encryption: Equatable, Sendable {
    let keyURL: URL
    let initializationVector: Data
}

struct HLSMediaPlaylist: Equatable, Sendable {
    let resources: [HLSMediaResource]
    let hasEndList: Bool
    let targetDuration: Int?
    let mediaSequence: Int64
    let discontinuitySequence: Int64
    let playlistType: HLSMediaPlaylistType?
    let segmentBitrates: [HLSSegmentBitrate]
    let encryptionMethod: String?
    let unsupportedFeatures: [HLSUnsupportedMediaFeature]

    var segmentCount: Int {
        resources.count { $0.kind == .segment }
    }
}
