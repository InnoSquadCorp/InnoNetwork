import Foundation

/// One structured, value-redacted HLS playlist finding.
public struct HLSPlaylistDiagnostic: Equatable, Hashable, Sendable {
    /// The operational impact of a finding.
    public enum Severity: Equatable, Hashable, Sendable {
        /// The scoped operation cannot proceed safely.
        case error

        /// The operation can proceed, but authoring should be reviewed.
        case warning
    }

    /// The operation or document surface affected by a finding.
    public enum Scope: Equatable, Hashable, Sendable {
        /// Playlist parsing and document validity.
        case playlist

        /// Raw single-file assembly through ``HLSDownloader``.
        case singleFileDownload

        /// Application-owned packaging through
        /// ``HLSOfflinePackageDownloader``.
        case offlinePackage

        /// Opt-in Apple HLS authoring guidance.
        case appleAuthoring
    }

    /// A stable classification that does not contain source values.
    public enum Code: Equatable, Hashable, Sendable {
        /// The first nonempty line is not `#EXTM3U`.
        case missingHeader

        /// An HLS attribute list cannot be parsed safely.
        case malformedAttributeList

        /// A singleton tag appears more than once.
        case duplicateTag

        /// A required tag attribute is absent.
        case missingRequiredAttribute

        /// `EXT-X-STREAM-INF` is not followed by a media-playlist URI.
        case missingVariantURI

        /// Multivariant and media-segment declarations are mixed.
        case mixedPlaylistKinds

        /// The bounded parser rejected the document for another reason.
        case invalidPlaylist

        /// The document or its bounded variable expansion is too large.
        case playlistTooLarge

        /// The media playlist contains no downloadable segments.
        case emptyMediaPlaylist

        /// A VOD download requires a terminal `EXT-X-ENDLIST`.
        case livePlaylistUnsupported

        /// The media encryption method cannot be persisted safely.
        case encryptionUnsupported

        /// A modeled media feature is unsupported by the scoped operation.
        case mediaFeatureUnsupported

        /// A separately timed audio layout limits raw file assembly.
        case separateAudioRendition

        /// Offline Content Steering requires stable variant identity.
        case missingStableVariantID

        /// Offline Content Steering requires stable rendition identity.
        case missingStableRenditionID

        /// No trick-play variant advertises the regular variant's resolution.
        case iFrameResolutionMismatch

        /// A media playlist omits `EXT-X-TARGETDURATION`.
        case appleTargetDurationMissing

        /// A complete segment exceeds the declared target duration.
        case appleSegmentExceedsTargetDuration

        /// Independent-segment signaling is absent.
        case appleIndependentSegmentsMissing

        /// A variant omits codec declarations.
        case appleCodecsMissing

        /// A variant omits average bandwidth.
        case appleAverageBandwidthMissing

        /// Variant declarations are not ordered by increasing bandwidth.
        case appleVariantOrder

        /// A video variant omits its encoded resolution.
        case appleResolutionMissing

        /// A video variant omits its maximum frame rate.
        case appleFrameRateMissing

        /// A mixed-range multivariant playlist omits a video range.
        case appleVideoRangeMissing

        /// Only some variants declare a quality-of-experience score.
        case appleScoreIncomplete

        /// Content Steering omits an initial pathway.
        case appleContentSteeringPathwayMissing

        /// A steered variant omits stable identity.
        case appleStableVariantIDMissing

        /// A steered rendition omits stable identity.
        case appleStableRenditionIDMissing

        /// A subtitle or closed-caption rendition omits language metadata.
        case appleCaptionLanguageMissing

        /// A Low-Latency playlist omits program date-time signaling.
        case appleLowLatencyProgramDateTimeMissing

        /// Partial-segment hold-back is below Apple's recommendation.
        case applePartialSegmentHoldBackTooShort

        /// The playlist URL does not use HTTPS.
        case appleTLSRecommended

        /// A feature requires a newer declared protocol version.
        case appleProtocolVersionTooLow
    }

    /// Whether this finding blocks or advises its scoped operation.
    public let severity: Severity

    /// The operation or document surface affected by the finding.
    public let scope: Scope

    /// The stable, value-redacted finding classification.
    public let code: Code

    /// The one-based source line, or `nil` for a document-wide finding.
    public let lineNumber: Int?

    /// The modeled media feature associated with this finding.
    ///
    /// This is non-`nil` only when ``code`` is
    /// ``Code/mediaFeatureUnsupported``.
    public let mediaFeature: HLSUnsupportedMediaFeature?

    init(
        severity: Severity,
        scope: Scope,
        code: Code,
        lineNumber: Int?,
        mediaFeature: HLSUnsupportedMediaFeature? = nil
    ) {
        self.severity = severity
        self.scope = scope
        self.code = code
        self.lineNumber = lineNumber
        self.mediaFeature = mediaFeature
    }
}

/// Selects optional guidance added to playlist inspection.
///
/// The default inspection remains limited to document and operation
/// capability findings. Use ``appleAuthoring`` in authoring tools and CI.
public struct HLSPlaylistInspectionPack: Sendable {
    let includesAppleAuthoringGuidance: Bool

    private init(
        includesAppleAuthoringGuidance: Bool
    ) {
        self.includesAppleAuthoringGuidance =
            includesAppleAuthoringGuidance
    }

    /// Adds Apple-oriented HLS authoring recommendations.
    public static var appleAuthoring: HLSPlaylistInspectionPack {
        HLSPlaylistInspectionPack(
            includesAppleAuthoringGuidance: true
        )
    }

    static var operationCapabilities: HLSPlaylistInspectionPack {
        HLSPlaylistInspectionPack(
            includesAppleAuthoringGuidance: false
        )
    }
}

/// A parsed playlist, plus deterministic authoring and capability findings.
public struct HLSPlaylistInspection: Equatable, Sendable {
    /// The parsed playlist, or `nil` when document validation failed.
    public let playlist: HLSPlaylist?

    /// Ordered, value-redacted findings for the inspected document.
    public let diagnostics: [HLSPlaylistDiagnostic]

    /// Whether the document passed bounded playlist parsing.
    public var isValid: Bool {
        playlist != nil
    }

    /// Whether the inspected document can enter raw single-file planning.
    ///
    /// Referenced child playlists are validated only when they are resolved.
    public var canDownloadAsSingleFile: Bool {
        canProceed(in: .singleFileDownload)
    }

    /// Whether the inspected document can enter offline-package planning.
    ///
    /// Referenced child playlists are validated only when they are resolved.
    public var canCreateOfflinePackage: Bool {
        canProceed(in: .offlinePackage)
    }

    /// Apple authoring recommendations included by an opt-in inspection pack.
    public var appleAuthoringDiagnostics: [HLSPlaylistDiagnostic] {
        diagnostics.filter { $0.scope == .appleAuthoring }
    }

    init(
        playlist: HLSPlaylist?,
        diagnostics: [HLSPlaylistDiagnostic]
    ) {
        self.playlist = playlist
        self.diagnostics = diagnostics
    }

    private func canProceed(
        in scope: HLSPlaylistDiagnostic.Scope
    ) -> Bool {
        guard isValid else {
            return false
        }
        return !diagnostics.contains {
            $0.severity == .error
                && ($0.scope == .playlist || $0.scope == scope)
        }
    }
}

extension PlaylistResolver {
    /// Inspects a playlist without throwing.
    ///
    /// Diagnostic values expose stable codes and optional line numbers, never
    /// the source line, URL, attribute value, or signed query parameter. The
    /// returned ``HLSPlaylistInspection/playlist`` is the ordinary parsed model
    /// and can contain resolved URLs.
    public func inspect(
        _ playlist: String,
        relativeTo sourceURL: URL
    ) -> HLSPlaylistInspection {
        HLSPlaylistDiagnosticAnalyzer.inspect(
            playlist,
            relativeTo: sourceURL,
            resolver: self,
            pack: .operationCapabilities
        )
    }

    /// Inspects a playlist with an explicit diagnostic pack.
    ///
    /// Apple authoring findings are advisory and never change the raw or
    /// offline capability booleans.
    public func inspect(
        _ playlist: String,
        relativeTo sourceURL: URL,
        using pack: HLSPlaylistInspectionPack
    ) -> HLSPlaylistInspection {
        HLSPlaylistDiagnosticAnalyzer.inspect(
            playlist,
            relativeTo: sourceURL,
            resolver: self,
            pack: pack
        )
    }
}
