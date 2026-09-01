import Foundation
import InnoNetwork

struct HLSResolvedDownloadPlan: Sendable {
    let mediaPlaylistURL: URL
    let mediaPlaylistIdentity: HLSContentIdentity
    let selectedVariant: HLSVariant?
    let availableRenditions: [HLSRendition]
    let mediaContainer: HLSMediaContainer
    let media: HLSMediaPlaylist
    let resourcePlan: HLSResourcePlan
    let pathwayID: String?
    let pathwayCandidates: [HLSMediaPlaylistCandidate]
    let contentSteeringSession: HLSContentSteeringSession

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
    private let contentSteering: HLSContentSteeringSettings
    private let clock: any InnoNetworkClock

    init(
        client: HLSHTTPClient,
        selectionPolicy: HLSVariantSelectionPolicy,
        contentSteering: HLSContentSteeringSettings,
        maximumTransferBytes: Int,
        clock: any InnoNetworkClock
    ) {
        self.mediaPlaylistResolver = HLSMediaPlaylistResolver(
            client: client,
            selectionPolicy: selectionPolicy,
            contentSteering: contentSteering
        )
        self.maximumTransferBytes = maximumTransferBytes
        self.contentSteering = contentSteering
        self.clock = clock
    }

    func resolve(
        sourceURL: URL
    ) async throws -> HLSResolvedDownloadPlan {
        let contentSteeringSession = HLSContentSteeringSession(
            settings: contentSteering,
            now: { clock.now() }
        )
        let selection = try await mediaPlaylistResolver.resolve(
            from: sourceURL,
            session: contentSteeringSession
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
            pathwayCandidates: selection.pathwayCandidates,
            contentSteeringSession: contentSteeringSession
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
        if let encryptionMethod =
            media.unsupportedEncryptionMethodForTransfer
        {
            throw HLSDownloadError.encryptedPlaylistUnsupported(
                method: encryptionMethod
            )
        }
    }
}
