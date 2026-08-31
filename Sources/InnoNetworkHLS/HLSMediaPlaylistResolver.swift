import Foundation

struct HLSResolvedMediaSelection: Sendable {
    let playlist: HLSPlaylist
    let mediaPlaylistIdentity: HLSContentIdentity
    let responseFreshness: HLSHTTPResponseFreshness
    let selectedVariant: HLSVariant?
    let renditions: [HLSRendition]
    let pathwayID: String?
    let multivariantVariables: [String: String]
    let pathwayCandidates: [HLSMediaPlaylistCandidate]
}

struct HLSMediaPlaylistCandidate: Sendable {
    let pathwayID: String?
    let variant: HLSVariant
    let renditions: [HLSRendition]
    let multivariantVariables: [String: String]
}

struct HLSMediaPlaylistResolver: Sendable {
    private let playlistResolver: PlaylistResolver
    private let variantSelector: VariantSelector
    private let selectionPolicy: HLSVariantSelectionPolicy
    private let contentSteeringResolver: HLSContentSteeringResolver
    private let allowsSeparateAudioRenditions: Bool

    init(
        client: HLSHTTPClient,
        selectionPolicy: HLSVariantSelectionPolicy,
        contentSteering: HLSContentSteeringSettings,
        allowsSeparateAudioRenditions: Bool = false
    ) {
        self.playlistResolver = PlaylistResolver(client: client)
        self.variantSelector = VariantSelector()
        self.selectionPolicy = selectionPolicy
        self.allowsSeparateAudioRenditions =
            allowsSeparateAudioRenditions
        self.contentSteeringResolver = HLSContentSteeringResolver(
            client: client,
            settings: contentSteering
        )
    }

    func resolve(
        from sourceURL: URL,
        session: HLSContentSteeringSession,
        requestTimeout: TimeInterval = 15,
        disablesCaching: Bool = false
    ) async throws -> HLSResolvedMediaSelection {
        let document = try await playlistResolver.resolveDocument(
            from: sourceURL,
            requestTimeout: requestTimeout,
            disablesCaching: disablesCaching
        )
        let playlist = document.playlist
        guard playlist.kind == .multivariant else {
            return HLSResolvedMediaSelection(
                playlist: playlist,
                mediaPlaylistIdentity: document.identity,
                responseFreshness: document.responseFreshness,
                selectedVariant: nil,
                renditions: [],
                pathwayID: nil,
                multivariantVariables: [:],
                pathwayCandidates: []
            )
        }

        let catalog = try await contentSteeringResolver.catalog(
            for: playlist
        )
        let candidates = try makeCandidates(
            from: catalog,
            multivariantVariables: document.variables
        )
        var terminalError: (any Error)?
        var previousFailure:
            (
                pathwayID: String?,
                errorCode: HLSDownloadErrorCode
            )?
        for candidate in candidates {
            let admission = await session.beginAttempt(
                pathwayID: candidate.pathwayID,
                phase: .mediaPlaylist,
                resourceIndex: nil
            )
            guard admission != .penalized else {
                continue
            }
            do {
                let mediaDocument =
                    try await playlistResolver.resolveDocument(
                        from: candidate.variant.url,
                        multivariantVariables:
                            candidate.multivariantVariables,
                        purpose: .mediaPlaylist,
                        requestTimeout: requestTimeout,
                        disablesCaching: disablesCaching
                    )
                guard mediaDocument.playlist.kind == .media else {
                    throw HLSDownloadError.invalidPlaylist
                }
                let selectionReason: HLSContentSteeringSelectionReason
                let fromPathwayID: String?
                if admission == .recovered {
                    selectionReason = .cooldownRecovery
                    fromPathwayID = previousFailure?.pathwayID
                } else if let previousFailure {
                    selectionReason = .pathwayFailure(
                        phase: .mediaPlaylist,
                        errorCode: previousFailure.errorCode
                    )
                    fromPathwayID = previousFailure.pathwayID
                } else {
                    selectionReason = .initial
                    fromPathwayID = nil
                }
                await session.recordSuccess(
                    pathwayID: candidate.pathwayID,
                    phase: .mediaPlaylist,
                    resourceIndex: nil,
                    selection: HLSContentSteeringSession.Selection(
                        fromPathwayID: fromPathwayID,
                        reason: selectionReason
                    )
                )
                return HLSResolvedMediaSelection(
                    playlist: mediaDocument.playlist,
                    mediaPlaylistIdentity: mediaDocument.identity,
                    responseFreshness:
                        mediaDocument.responseFreshness,
                    selectedVariant: candidate.variant,
                    renditions: candidate.renditions,
                    pathwayID: candidate.pathwayID,
                    multivariantVariables:
                        candidate.multivariantVariables,
                    pathwayCandidates: candidates
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                terminalError = error
                let errorCode = Self.errorCode(for: error)
                previousFailure = (
                    pathwayID: candidate.pathwayID,
                    errorCode: errorCode
                )
                await session.recordFailure(
                    pathwayID: candidate.pathwayID,
                    phase: .mediaPlaylist,
                    resourceIndex: nil,
                    errorCode: errorCode
                )
            }
        }
        if let terminalError {
            throw terminalError
        }
        throw HLSDownloadError.emptyMediaPlaylist
    }

    private func makeCandidates(
        from catalog: HLSPathwayCatalog,
        multivariantVariables: [String: String]
    ) throws -> [HLSMediaPlaylistCandidate] {
        var candidates: [HLSMediaPlaylistCandidate] = []
        var terminalError: HLSDownloadError?
        for pathway in catalog.pathways {
            let separateAudioGroupIDs = Set(
                Dictionary(
                    grouping: pathway.renditions.filter {
                        $0.kind == .audio
                    }
                ) { $0.groupID }.compactMap { groupID, renditions in
                    renditions.allSatisfy { $0.url != nil }
                        ? groupID
                        : nil
                }
            )
            let supportedVariants =
                allowsSeparateAudioRenditions
                ? pathway.variants
                : pathway.variants.filter { variant in
                    guard let audioGroupID = variant.audioGroupID else {
                        return true
                    }
                    return !separateAudioGroupIDs.contains(audioGroupID)
                }
            guard !supportedVariants.isEmpty else {
                if let audioGroupID = pathway.variants
                    .compactMap(\.audioGroupID)
                    .first(where: { separateAudioGroupIDs.contains($0) })
                {
                    terminalError =
                        HLSDownloadError
                        .separateAudioRenditionUnsupported(
                            groupID: audioGroupID
                        )
                }
                continue
            }
            guard
                let variant = variantSelector.select(
                    in: supportedVariants,
                    policy: selectionPolicy
                )
            else {
                terminalError =
                    HLSDownloadError.noVariantMatchesSelectionPolicy(
                        selectionPolicy
                    )
                continue
            }
            candidates.append(
                HLSMediaPlaylistCandidate(
                    pathwayID: pathway.id,
                    variant: variant,
                    renditions: pathway.renditions,
                    multivariantVariables: multivariantVariables
                )
            )
        }
        if candidates.isEmpty, let terminalError {
            throw terminalError
        }
        return candidates
    }

    private static func errorCode(
        for error: any Error
    ) -> HLSDownloadErrorCode {
        (error as? HLSDownloadError)?.code ?? .transferFailed
    }
}
