import Foundation

/// Controls which external renditions are retained in an offline HLS package.
public enum HLSOfflineRenditionSelectionPolicy: Equatable, Sendable {
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

/// Groups external rendition and trick-play selection for offline packaging.
///
/// Stored values are opaque immutable input. The conservative default keeps
/// one external audio rendition and omits video, subtitles, and I-frame
/// trick-play until the application explicitly chooses its storage policy.
public struct HLSOfflineRenditionPack: Sendable {
    private let audio: HLSOfflineRenditionSelectionPolicy
    private let video: HLSOfflineRenditionSelectionPolicy
    private let subtitles: HLSOfflineRenditionSelectionPolicy
    private let subtitleProvenance: HLSSubtitleProvenancePolicy
    private let includesIFrameTrickPlay: Bool
    private let maximumRenditionsPerKind: Int

    /// Creates an offline rendition-selection pack.
    public init(
        audio: HLSOfflineRenditionSelectionPolicy = .defaultOrFirst,
        video: HLSOfflineRenditionSelectionPolicy = .disabled,
        subtitles: HLSOfflineRenditionSelectionPolicy = .disabled,
        includesIFrameTrickPlay: Bool = false,
        maximumRenditionsPerKind: Int = 8
    ) {
        self.init(
            audio: audio,
            video: video,
            subtitles: subtitles,
            subtitleProvenance: HLSSubtitleProvenancePolicy(),
            includesIFrameTrickPlay: includesIFrameTrickPlay,
            maximumRenditionsPerKind: maximumRenditionsPerKind
        )
    }

    /// Creates an offline selection pack with explicit generated/translated
    /// subtitle behavior.
    public init(
        audio: HLSOfflineRenditionSelectionPolicy = .defaultOrFirst,
        video: HLSOfflineRenditionSelectionPolicy = .disabled,
        subtitles: HLSOfflineRenditionSelectionPolicy = .disabled,
        subtitleProvenance: HLSSubtitleProvenancePolicy,
        includesIFrameTrickPlay: Bool = false,
        maximumRenditionsPerKind: Int = 8
    ) {
        self.audio = audio
        self.video = video
        self.subtitles = subtitles
        self.subtitleProvenance = subtitleProvenance
        self.includesIFrameTrickPlay = includesIFrameTrickPlay
        self.maximumRenditionsPerKind = min(
            max(1, maximumRenditionsPerKind),
            32
        )
    }

    func policy(
        for kind: HLSRenditionKind
    ) -> HLSOfflineRenditionSelectionPolicy {
        switch kind {
        case .audio:
            return audio
        case .subtitles:
            return subtitles
        case .video:
            return video
        case .closedCaptions:
            return .disabled
        }
    }

    var renditionLimit: Int {
        maximumRenditionsPerKind
    }

    var resolvedSubtitleProvenance: HLSSubtitleProvenancePolicy {
        subtitleProvenance
    }

    var retainsIFrameTrickPlay: Bool {
        includesIFrameTrickPlay
    }
}

/// The role of one playlist retained in an offline HLS package.
public enum HLSOfflinePackageTrackKind: Equatable, Hashable, Sendable {
    /// The selected primary variant or direct media playlist.
    case primary

    /// One external audio rendition.
    case audio

    /// One external subtitle rendition.
    case subtitles

    /// One external video rendition, such as another camera angle.
    case video

    /// The selected I-frame-only trick-play playlist.
    case iFrames

    /// One external I-frame-only video rendition used during trick play.
    case iFrameVideo
}

/// Metadata for one local playlist in an offline HLS package.
public struct HLSOfflinePackageTrack: Equatable, Sendable {
    /// The role of the local track.
    public let kind: HLSOfflinePackageTrackKind

    /// The rendition name, or `nil` for the primary track.
    public let name: String?

    /// The advertised BCP 47 language tag.
    public let language: String?

    /// The associated BCP 47 language tag.
    public let associatedLanguage: String?

    /// The source's stable rendition identifier.
    public let stableID: String?

    /// An in-band media identifier retained from the source rendition.
    public let instreamID: String?

    /// Media characteristic tags in playlist order.
    public let characteristics: [String]

    /// The raw HLS audio channel configuration.
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

    /// Whether the source playlist marked this rendition as the default.
    public let isDefault: Bool

    /// Whether the source playlist allowed automatic selection.
    public let isAutoselect: Bool

    /// Whether this is a forced subtitle rendition.
    public let isForced: Bool

    /// The playlist path relative to the package directory.
    public let relativePlaylistPath: String

    init(
        kind: HLSOfflinePackageTrackKind,
        name: String?,
        language: String?,
        associatedLanguage: String? = nil,
        stableID: String? = nil,
        instreamID: String? = nil,
        characteristics: [String] = [],
        channels: String? = nil,
        audioBitDepth: Int? = nil,
        audioSampleRate: Int? = nil,
        isDefault: Bool,
        isAutoselect: Bool,
        isForced: Bool,
        relativePlaylistPath: String
    ) {
        self.kind = kind
        self.name = name
        self.language = language
        self.associatedLanguage = associatedLanguage
        self.stableID = stableID
        self.instreamID = instreamID
        self.characteristics = characteristics
        self.channels = channels
        self.audioBitDepth = audioBitDepth
        self.audioSampleRate = audioSampleRate
        self.isDefault = isDefault
        self.isAutoselect = isAutoselect
        self.isForced = isForced
        self.relativePlaylistPath = relativePlaylistPath
    }
}

/// An advisory offline-package plan produced without downloading media bytes.
public struct HLSOfflinePackagePreparation: Equatable, Sendable {
    /// The source URL supplied by the application.
    public let sourceURL: URL

    /// The selected multivariant stream, or `nil` for a direct media playlist.
    public let selectedVariant: HLSVariant?

    /// The selected I-frame-only trick-play variant, when retained.
    public let selectedIFrameVariant: HLSVariant?

    /// The local playlists that will be created for every selected track.
    public let tracks: [HLSOfflinePackageTrack]

    /// The number of bounded media-resource requests in the package.
    public let resourceTransferCount: Int

    init(
        sourceURL: URL,
        selectedVariant: HLSVariant?,
        selectedIFrameVariant: HLSVariant? = nil,
        tracks: [HLSOfflinePackageTrack],
        resourceTransferCount: Int
    ) {
        self.sourceURL = sourceURL
        self.selectedVariant = selectedVariant
        self.selectedIFrameVariant = selectedIFrameVariant
        self.tracks = tracks
        self.resourceTransferCount = resourceTransferCount
    }
}

/// The committed result of an offline HLS package download.
public struct HLSOfflinePackageReceipt: Equatable, Sendable {
    /// The atomically committed package directory.
    public let directoryURL: URL

    /// The local multivariant playlist used as the package entry point.
    ///
    /// AVFoundation does not directly play arbitrary local `file://` HLS
    /// playlists. Use ``playbackSource`` with `HLSLocalPlaybackAsset` from
    /// `InnoNetworkHLSAVFoundation`, or choose the companion's system-managed
    /// download session when native background persistence is required.
    public let entryPlaylistURL: URL

    /// A structurally validated source for application-owned local playback.
    public var playbackSource: HLSLocalPlaybackSource {
        HLSLocalPlaybackSource(
            validatedPackageDirectoryURL: directoryURL,
            entryPlaylistURL: entryPlaylistURL
        )
    }

    /// The local playlists retained in the package.
    public let tracks: [HLSOfflinePackageTrack]

    /// The complete committed package size, including playlists and manifest.
    public let byteCount: Int64

    /// The selected multivariant stream, or `nil` for a direct media playlist.
    public let selectedVariant: HLSVariant?

    /// The selected I-frame-only trick-play variant, when retained.
    public let selectedIFrameVariant: HLSVariant?

    /// Resource transfers reused from a durable package checkpoint.
    ///
    /// Reopened legacy packages report zero because older manifests did not
    /// retain creation-time resume metadata.
    public let resumedResourceTransferCount: Int

    init(
        directoryURL: URL,
        entryPlaylistURL: URL,
        tracks: [HLSOfflinePackageTrack],
        byteCount: Int64,
        selectedVariant: HLSVariant?,
        selectedIFrameVariant: HLSVariant? = nil,
        resumedResourceTransferCount: Int = 0
    ) {
        self.directoryURL = directoryURL
        self.entryPlaylistURL = entryPlaylistURL
        self.tracks = tracks
        self.byteCount = byteCount
        self.selectedVariant = selectedVariant
        self.selectedIFrameVariant = selectedIFrameVariant
        self.resumedResourceTransferCount = resumedResourceTransferCount
    }
}

extension HLSOfflinePackageReceipt {
    package func primaryPlaybackDuration() throws -> TimeInterval {
        guard let primary = tracks.first(where: { $0.kind == .primary })
        else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        let playlistURL = directoryURL.appendingPathComponent(
            primary.relativePlaylistPath
        )
        let contents: String
        do {
            contents = try String(
                contentsOf: playlistURL,
                encoding: .utf8
            )
        } catch {
            throw HLSDownloadError.invalidOfflinePackage
        }
        let playlist = try PlaylistResolver().resolve(
            contents,
            relativeTo: playlistURL
        )
        guard let media = playlist.media else {
            throw HLSDownloadError.invalidOfflinePackage
        }
        var duration: TimeInterval = 0
        for resource in media.resources where resource.kind == .segment {
            guard let segmentDuration = resource.duration,
                segmentDuration.isFinite,
                segmentDuration >= 0
            else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            duration += segmentDuration
            guard duration.isFinite else {
                throw HLSDownloadError.invalidOfflinePackage
            }
        }
        return duration
    }
}

/// Events emitted while an offline HLS package is created.
public enum HLSOfflinePackageEvent: Sendable {
    /// Byte-level progress across all selected media resources.
    case progress(HLSDownloadProgress)

    /// The complete package directory was committed atomically.
    case completed(HLSOfflinePackageReceipt)

    /// Package creation failed with a typed HLS error.
    case failed(HLSDownloadError)

    /// The consuming task or event stream cancelled package creation.
    case cancelled
}
