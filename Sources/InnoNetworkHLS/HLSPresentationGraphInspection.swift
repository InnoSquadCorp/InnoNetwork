import Foundation

/// The authoring contract applied to presentation-graph diagnostics.
public enum HLSPresentationConformanceRevision: Equatable, Hashable, Sendable {
    /// HLS 2nd Edition Internet-Draft revision 22.
    case hlsSecondEditionDraft22
}

/// The relationship between a media playlist and its multivariant root.
public enum HLSPresentationPlaylistRole: Equatable, Hashable, Sendable {
    /// A directly supplied media playlist.
    case entry

    /// A regular variant stream.
    case variant

    /// An I-frame-only variant stream.
    case iFrameVariant

    /// An alternate audio rendition.
    case audioRendition

    /// An alternate video rendition.
    case videoRendition

    /// A subtitle rendition.
    case subtitleRendition
}

/// Bounded network and graph limits for presentation inspection.
public struct HLSPresentationInspectionLimitPack: Sendable {
    let maximumPlaylistCount: Int
    let maximumConcurrentRequests: Int
    let maximumPlaylistBytes: Int
    let maximumTotalPlaylistBytes: Int
    let requestTimeout: TimeInterval

    /// Creates normalized graph-inspection limits.
    public init(
        maximumPlaylistCount: Int = 32,
        maximumConcurrentRequests: Int = 4,
        maximumPlaylistBytes: Int = 2 * 1_024 * 1_024,
        maximumTotalPlaylistBytes: Int = 16 * 1_024 * 1_024,
        requestTimeout: TimeInterval = 15
    ) {
        let playlistCount = min(128, max(1, maximumPlaylistCount))
        let playlistBytes = min(
            8 * 1_024 * 1_024,
            max(1, maximumPlaylistBytes)
        )
        self.maximumPlaylistCount = playlistCount
        self.maximumConcurrentRequests = min(
            8,
            max(1, min(maximumConcurrentRequests, playlistCount))
        )
        self.maximumPlaylistBytes = playlistBytes
        self.maximumTotalPlaylistBytes = max(
            playlistBytes,
            maximumTotalPlaylistBytes
        )
        self.requestTimeout =
            requestTimeout.isFinite && requestTimeout > 0
            ? requestTimeout
            : 15
    }
}

/// Groups presentation-graph inspection behavior.
public struct HLSPresentationInspectionPack: Sendable {
    let limits: HLSPresentationInspectionLimitPack
    let revision: HLSPresentationConformanceRevision

    /// Returns conservative bounded defaults for CI and authoring tools.
    public static func safeDefaults() -> HLSPresentationInspectionPack {
        HLSPresentationInspectionPack(
            limits: HLSPresentationInspectionLimitPack(),
            revision: .hlsSecondEditionDraft22
        )
    }

    /// Returns explicitly tuned graph inspection behavior.
    public static func advanced(
        limits: HLSPresentationInspectionLimitPack =
            HLSPresentationInspectionLimitPack(),
        revision: HLSPresentationConformanceRevision =
            .hlsSecondEditionDraft22
    ) -> HLSPresentationInspectionPack {
        HLSPresentationInspectionPack(
            limits: limits,
            revision: revision
        )
    }
}

/// One fetched media playlist in deterministic discovery order.
public struct HLSPresentationPlaylistInspection: Equatable, Sendable {
    /// The zero-based index used by graph diagnostics.
    public let index: Int

    /// Every root relationship that resolves to this playlist URL.
    public let roles: Set<HLSPresentationPlaylistRole>

    /// The parsed media playlist. This model can contain resolved URLs.
    public let playlist: HLSPlaylist

    init(
        index: Int,
        roles: Set<HLSPresentationPlaylistRole>,
        playlist: HLSPlaylist
    ) {
        self.index = index
        self.roles = roles
        self.playlist = playlist
    }
}

/// One value-redacted finding across a presentation's media playlists.
public struct HLSPresentationDiagnostic: Equatable, Hashable, Sendable {
    /// The conformance impact of a graph finding.
    public enum Severity: Equatable, Hashable, Sendable {
        /// The fetched graph violates the selected conformance revision.
        case error

        /// Playlist-only evidence cannot prove the expected alignment.
        case warning
    }

    /// A stable graph finding classification.
    public enum Code: Equatable, Hashable, Sendable {
        /// A media playlist omits its required target duration.
        case targetDurationMissing

        /// Comparable media playlists declare different target durations.
        case targetDurationMismatch

        /// Playlist mutability declarations are not graph-consistent.
        case playlistTypeMismatch

        /// Program date-time signaling is present in only part of the graph.
        case programDateTimeMissing

        /// Program date-time values do not map segment boundaries consistently.
        case programDateTimeMappingMismatch

        /// Matching segment boundaries use different discontinuity sequences.
        case discontinuitySequenceMismatch

        /// Matching VOD or dated timelines have different segment boundaries.
        case timelineAlignmentMismatch

        /// Date Range identifier sets differ between declaring playlists.
        case dateRangeSetMismatch

        /// Corresponding Date Ranges have different attribute/value pairs.
        case dateRangeAttributeMismatch

        /// Server-control declarations are missing or differ across the graph.
        case serverControlMismatch
    }

    /// Whether this finding blocks conformance or reports limited evidence.
    public let severity: Severity

    /// The stable, value-redacted classification.
    public let code: Code

    /// The primary media-playlist index.
    public let playlistIndex: Int

    /// The comparison media-playlist index, when applicable.
    public let relatedPlaylistIndex: Int?

    init(
        severity: Severity,
        code: Code,
        playlistIndex: Int,
        relatedPlaylistIndex: Int? = nil
    ) {
        self.severity = severity
        self.code = code
        self.playlistIndex = playlistIndex
        self.relatedPlaylistIndex = relatedPlaylistIndex
    }
}

/// A bounded presentation graph plus cross-playlist conformance findings.
public struct HLSPresentationGraphInspection: Equatable, Sendable {
    /// The revision used to classify graph findings.
    public let revision: HLSPresentationConformanceRevision

    /// The parsed entry playlist. This can be media or multivariant.
    public let entryPlaylist: HLSPlaylist

    /// Referenced media playlists in deterministic discovery order.
    public let mediaPlaylists: [HLSPresentationPlaylistInspection]

    /// Ordered, value-redacted cross-playlist findings.
    public let diagnostics: [HLSPresentationDiagnostic]

    /// Whether the fetched graph has no conformance errors.
    public var isConformant: Bool {
        !diagnostics.contains { $0.severity == .error }
    }

    init(
        revision: HLSPresentationConformanceRevision,
        entryPlaylist: HLSPlaylist,
        mediaPlaylists: [HLSPresentationPlaylistInspection],
        diagnostics: [HLSPresentationDiagnostic]
    ) {
        self.revision = revision
        self.entryPlaylist = entryPlaylist
        self.mediaPlaylists = mediaPlaylists
        self.diagnostics = diagnostics
    }
}

/// Failures that prevent bounded presentation-graph construction.
public enum HLSPresentationInspectionError: Error, Equatable, Sendable {
    /// The root references more unique media playlists than allowed.
    case playlistLimitExceeded(limit: Int)

    /// Fetched playlist documents exceeded the aggregate byte limit.
    case totalPlaylistBytesExceeded(limit: Int)
}

extension HLSPresentationInspectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .playlistLimitExceeded(let limit):
            return hlsLocalizedFormat(
                "HLSPresentationInspectionError.playlistLimitExceeded",
                String(limit)
            )
        case .totalPlaylistBytesExceeded(let limit):
            return hlsLocalizedFormat(
                "HLSPresentationInspectionError.totalPlaylistBytesExceeded",
                String(limit)
            )
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .playlistLimitExceeded:
            return hlsLocalized(
                "HLSPresentationInspectionError.recovery.limitPlaylists"
            )
        case .totalPlaylistBytesExceeded:
            return hlsLocalized(
                "HLSPresentationInspectionError.recovery.limitBytes"
            )
        }
    }
}
