import Foundation

struct HLSResolvedDownloadPlan: Sendable {
    let mediaPlaylistURL: URL
    let mediaPlaylistIdentity: HLSContentIdentity
    let selectedVariant: HLSVariant?
    let availableRenditions: [HLSRendition]
    let mediaContainer: HLSMediaContainer
    let media: HLSMediaPlaylist
    let resourcePlan: HLSResourcePlan
    let pathwayID: String?
    let fallbackCandidates: [HLSMediaPlaylistCandidate]

    func preparation(
        sourceURL: URL
    ) -> HLSDownloadPreparation {
        HLSDownloadPreparation(
            sourceURL: sourceURL,
            mediaPlaylistURL: mediaPlaylistURL,
            selectedVariant: selectedVariant,
            availableRenditions: availableRenditions,
            mediaContainer: mediaContainer,
            segmentCount: media.segmentCount,
            resourceTransferCount: resourcePlan.transfers.count
        )
    }
}

struct HLSDownloadPlanner: Sendable {
    private let mediaPlaylistResolver: HLSMediaPlaylistResolver
    private let maximumTransferBytes: Int

    init(
        client: HLSHTTPClient,
        selectionPolicy: HLSVariantSelectionPolicy,
        contentSteering: HLSContentSteeringSettings,
        maximumTransferBytes: Int
    ) {
        self.mediaPlaylistResolver = HLSMediaPlaylistResolver(
            client: client,
            selectionPolicy: selectionPolicy,
            contentSteering: contentSteering
        )
        self.maximumTransferBytes = maximumTransferBytes
    }

    func resolve(
        sourceURL: URL
    ) async throws -> HLSResolvedDownloadPlan {
        let selection = try await mediaPlaylistResolver.resolve(
            from: sourceURL
        )
        guard
            let media = selection.playlist.media,
            let mediaContainer = selection.playlist.mediaContainer
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        try HLSMediaPlaylistValidator.validate(media)
        return HLSResolvedDownloadPlan(
            mediaPlaylistURL: selection.playlist.sourceURL,
            mediaPlaylistIdentity: selection.mediaPlaylistIdentity,
            selectedVariant: selection.selectedVariant,
            availableRenditions: selection.renditions,
            mediaContainer: mediaContainer,
            media: media,
            resourcePlan: HLSResourcePlan(
                resources: media.resources,
                maximumTransferBytes: maximumTransferBytes
            ),
            pathwayID: selection.pathwayID,
            fallbackCandidates: selection.fallbackCandidates
        )
    }

}

enum HLSMediaPlaylistValidator {
    static func validate(
        _ media: HLSMediaPlaylist
    ) throws {
        try validate(
            media,
            allowing: [
                .preloadHintResource,
                .renditionReportResource,
            ]
        )
    }

    static func validateOfflinePackage(
        _ media: HLSMediaPlaylist
    ) throws {
        try validate(media, allowing: [])
    }

    static func validateIFrameTrickPlay(
        _ media: HLSMediaPlaylist
    ) throws {
        guard media.unsupportedFeatures.contains(.iFramesOnly) else {
            throw HLSDownloadError.invalidPlaylist
        }
        try validate(media, allowing: [.iFramesOnly])
    }

    private static func validate(
        _ media: HLSMediaPlaylist,
        allowing allowedFeatures: Set<HLSUnsupportedMediaFeature>
    ) throws {
        guard media.segmentCount > 0 else {
            throw HLSDownloadError.emptyMediaPlaylist
        }
        guard media.hasEndList else {
            throw HLSDownloadError.livePlaylistUnsupported
        }
        if let feature = media.unsupportedFeatures.first(where: {
            !allowedFeatures.contains($0)
        }) {
            throw HLSDownloadError.unsupportedMediaFeature(feature)
        }
        if let encryptionMethod = media.encryptionMethod,
            encryptionMethod != "AES-128"
        {
            throw HLSDownloadError.encryptedPlaylistUnsupported(
                method: encryptionMethod
            )
        }
    }
}
