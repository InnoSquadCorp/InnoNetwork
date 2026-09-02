import Foundation
import InnoNetwork

struct HLSOfflinePackagePlan: Sendable {
    let selectedVariant: HLSVariant?
    let selectedIFrameVariant: HLSVariant?
    let tracks: [HLSOfflinePackageTrackPlan]
    let preloadedAES128Keys: HLSAES128KeySet

    var resourceCount: Int {
        tracks.reduce(0) { $0 + $1.resources.count }
    }

    func preparation(
        sourceURL: URL
    ) -> HLSOfflinePackagePreparation {
        HLSOfflinePackagePreparation(
            sourceURL: sourceURL,
            selectedVariant: selectedVariant,
            selectedIFrameVariant: selectedIFrameVariant,
            tracks: tracks.map(\.descriptor),
            resourceTransferCount: resourceCount
        )
    }
}

struct HLSOfflinePackageTrackPlan: Sendable {
    let descriptor: HLSOfflinePackageTrack
    let document: HLSResolvedPlaylistDocument

    var resources: [HLSMediaResource] {
        document.playlist.media?.resources ?? []
    }

    var relativeDirectoryPath: String {
        String(
            descriptor.relativePlaylistPath.dropLast(
                "/index.m3u8".count
            )
        )
    }
}

struct HLSOfflinePackagePlanner: Sendable {
    private let playlistResolver: PlaylistResolver
    private let variantSelector = VariantSelector()
    private let variantSelectionPolicy: HLSVariantSelectionPolicy
    private let renditionPack: HLSOfflineRenditionPack
    private let contentSteeringResolver: HLSContentSteeringResolver
    private let contentSteering: HLSContentSteeringSettings
    private let isContentSteeringEnabled: Bool
    private let clock: any InnoNetworkClock
    private let sessionKeyPreloader: HLSAES128SessionKeyPreloader

    init(
        client: HLSHTTPClient,
        variantSelectionPolicy: HLSVariantSelectionPolicy,
        renditionPack: HLSOfflineRenditionPack,
        contentSteering: HLSContentSteeringSettings,
        sessionKeyPreloadPolicy: HLSSessionKeyPreloadPolicy,
        clock: any InnoNetworkClock
    ) {
        self.playlistResolver = PlaylistResolver(client: client)
        self.variantSelectionPolicy = variantSelectionPolicy
        self.renditionPack = renditionPack
        self.contentSteeringResolver = HLSContentSteeringResolver(
            client: client,
            settings: contentSteering
        )
        self.contentSteering = contentSteering
        self.isContentSteeringEnabled = contentSteering.isEnabled
        self.clock = clock
        self.sessionKeyPreloader = HLSAES128SessionKeyPreloader(
            client: client,
            policy: sessionKeyPreloadPolicy,
            clock: clock
        )
    }

    func resolve(
        sourceURL: URL,
        preloadsSessionKeys: Bool = false
    ) async throws -> HLSOfflinePackagePlan {
        let sourceDocument = try await playlistResolver.resolveDocument(
            from: sourceURL
        )
        let sessionKeyPreload = sessionKeyPreloader.start(
            sessionKeys: sourceDocument.playlist.sessionKeys,
            isDownloadExecution: preloadsSessionKeys
        )
        defer {
            sessionKeyPreload.cancel()
        }
        guard sourceDocument.playlist.kind == .multivariant else {
            return HLSOfflinePackagePlan(
                selectedVariant: nil,
                selectedIFrameVariant: nil,
                tracks: [
                    try makeTrackPlan(
                        document: sourceDocument,
                        descriptor: HLSOfflinePackageTrack(
                            kind: .primary,
                            name: nil,
                            language: nil,
                            isDefault: true,
                            isAutoselect: true,
                            isForced: false,
                            relativePlaylistPath:
                                "media/primary/index.m3u8"
                        )
                    )
                ],
                preloadedAES128Keys: .empty
            )
        }

        let catalog = try await contentSteeringResolver.catalog(
            for: sourceDocument.playlist
        )
        let contentSteeringSession = HLSContentSteeringSession(
            settings: contentSteering,
            now: { clock.now() }
        )
        if isContentSteeringEnabled,
            sourceDocument.playlist.contentSteering != nil
        {
            try Self.validateDownloadablePathways(
                catalog.pathways,
                includesIFrameTrickPlay:
                    renditionPack.retainsIFrameTrickPlay
            )
        }
        var terminalError: (any Error)?
        var previousFailure:
            (
                pathwayID: String?,
                errorCode: HLSDownloadErrorCode
            )?
        for pathway in catalog.pathways {
            guard
                let selectedVariant = variantSelector.select(
                    in: pathway.variants,
                    policy: variantSelectionPolicy
                )
            else {
                terminalError =
                    HLSDownloadError.noVariantMatchesSelectionPolicy(
                        variantSelectionPolicy
                    )
                continue
            }
            let admission = await contentSteeringSession.beginAttempt(
                pathwayID: pathway.id,
                phase: .mediaPlaylist,
                resourceIndex: nil
            )
            guard admission != .penalized else {
                continue
            }
            do {
                let plan = try await makePlan(
                    sourceDocument: sourceDocument,
                    pathway: pathway,
                    selectedVariant: selectedVariant
                )
                let reason: HLSContentSteeringSelectionReason
                let fromPathwayID: String?
                if admission == .recovered {
                    reason = .cooldownRecovery
                    fromPathwayID = previousFailure?.pathwayID
                } else if let previousFailure {
                    reason = .pathwayFailure(
                        phase: .mediaPlaylist,
                        errorCode: previousFailure.errorCode
                    )
                    fromPathwayID = previousFailure.pathwayID
                } else {
                    reason = .initial
                    fromPathwayID = nil
                }
                await contentSteeringSession.recordSuccess(
                    pathwayID: pathway.id,
                    phase: .mediaPlaylist,
                    resourceIndex: nil,
                    selection: HLSContentSteeringSession.Selection(
                        fromPathwayID: fromPathwayID,
                        reason: reason
                    )
                )
                let requiredKeyURLs = Set(
                    plan.tracks.flatMap(\.resources).compactMap {
                        $0.encryption?.keyURL
                    }
                )
                return HLSOfflinePackagePlan(
                    selectedVariant: plan.selectedVariant,
                    selectedIFrameVariant: plan.selectedIFrameVariant,
                    tracks: plan.tracks,
                    preloadedAES128Keys:
                        try await sessionKeyPreload.resolve(
                            requiredKeyURLs: requiredKeyURLs
                        )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                terminalError = error
                let errorCode =
                    (error as? HLSDownloadError)?.code
                    ?? .transferFailed
                previousFailure = (
                    pathwayID: pathway.id,
                    errorCode: errorCode
                )
                await contentSteeringSession.recordFailure(
                    pathwayID: pathway.id,
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

    private func makePlan(
        sourceDocument: HLSResolvedPlaylistDocument,
        pathway: HLSPathway,
        selectedVariant: HLSVariant
    ) async throws -> HLSOfflinePackagePlan {
        let selectedAudio = try selectRenditions(
            in: pathway.renditions,
            groupID: selectedVariant.audioGroupID,
            kind: .audio
        )
        let selectedSubtitles = try selectRenditions(
            in: pathway.renditions,
            groupID: selectedVariant.subtitleGroupID,
            kind: .subtitles
        )
        let selectedVideo = try selectRenditions(
            in: pathway.renditions,
            groupID: selectedVariant.videoGroupID,
            kind: .video
        )
        let selectedIFrameVariant: HLSVariant?
        if renditionPack.retainsIFrameTrickPlay,
            !pathway.iFrameVariants.isEmpty
        {
            guard
                let variant = selectIFrameVariant(
                    in: pathway.iFrameVariants,
                    matching: selectedVariant
                )
            else {
                throw HLSDownloadError.noVariantMatchesSelectionPolicy(
                    variantSelectionPolicy
                )
            }
            selectedIFrameVariant = variant
        } else {
            selectedIFrameVariant = nil
        }
        let selectedIFrameVideo = try selectRenditions(
            in: pathway.renditions,
            groupID: selectedIFrameVariant?.videoGroupID,
            kind: .video
        )
        guard
            selectedVideo.count(where: { $0.url != nil })
                + selectedIFrameVideo.count(where: { $0.url != nil })
                <= renditionPack.renditionLimit
        else {
            throw HLSDownloadError.offlineRenditionLimitExceeded(
                limit: renditionPack.renditionLimit
            )
        }
        let primaryDocument =
            try await playlistResolver.resolveDocument(
                from: selectedVariant.url,
                multivariantVariables: sourceDocument.variables,
                purpose: .mediaPlaylist
            )
        var tracks = [
            try makeTrackPlan(
                document: primaryDocument,
                descriptor: HLSOfflinePackageTrack(
                    kind: .primary,
                    name: nil,
                    language: nil,
                    isDefault: true,
                    isAutoselect: true,
                    isForced: false,
                    relativePlaylistPath:
                        "media/primary/index.m3u8"
                )
            )
        ]

        tracks.append(
            contentsOf: try await makeRenditionTrackPlans(
                selectedVideo,
                kind: .video,
                multivariantVariables: sourceDocument.variables
            )
        )
        tracks.append(
            contentsOf: try await makeRenditionTrackPlans(
                selectedAudio,
                kind: .audio,
                multivariantVariables: sourceDocument.variables
            )
        )
        tracks.append(
            contentsOf: try await makeRenditionTrackPlans(
                selectedSubtitles,
                kind: .subtitles,
                multivariantVariables: sourceDocument.variables
            )
        )
        if let selectedIFrameVariant {
            let document = try await playlistResolver.resolveDocument(
                from: selectedIFrameVariant.url,
                multivariantVariables: sourceDocument.variables,
                purpose: .mediaPlaylist
            )
            tracks.append(
                try makeTrackPlan(
                    document: document,
                    descriptor: HLSOfflinePackageTrack(
                        kind: .iFrames,
                        name: nil,
                        language: nil,
                        isDefault: false,
                        isAutoselect: false,
                        isForced: false,
                        relativePlaylistPath:
                            "media/i-frames/index.m3u8"
                    )
                )
            )
            tracks.append(
                contentsOf: try await makeRenditionTrackPlans(
                    selectedIFrameVideo,
                    kind: .iFrameVideo,
                    multivariantVariables: sourceDocument.variables
                )
            )
        }

        return HLSOfflinePackagePlan(
            selectedVariant: selectedVariant,
            selectedIFrameVariant: selectedIFrameVariant,
            tracks: tracks,
            preloadedAES128Keys: .empty
        )
    }

    private func selectIFrameVariant(
        in variants: [HLSVariant],
        matching selectedVariant: HLSVariant
    ) -> HLSVariant? {
        var candidates = variants
        if let width = selectedVariant.width,
            let height = selectedVariant.height
        {
            let exact = variants.filter {
                $0.width == width && $0.height == height
            }
            if !exact.isEmpty {
                candidates = exact
            } else {
                let bounded = variants.filter {
                    guard let candidateWidth = $0.width,
                        let candidateHeight = $0.height
                    else {
                        return false
                    }
                    return candidateWidth <= width
                        && candidateHeight <= height
                }
                if !bounded.isEmpty {
                    candidates = bounded
                }
            }
        }
        return variantSelector.select(
            in: candidates,
            policy: variantSelectionPolicy
        )
    }

    private static func validateDownloadablePathways(
        _ pathways: [HLSPathway],
        includesIFrameTrickPlay: Bool
    ) throws {
        guard let first = pathways.first else {
            throw HLSDownloadError.invalidPlaylist
        }
        let expectedVariants = try stableVariantIDs(
            in: first.variants
        )
        let expectedIFrameVariants: Set<String>
        if includesIFrameTrickPlay {
            expectedIFrameVariants = try stableVariantIDs(
                in: first.iFrameVariants
            )
        } else {
            expectedIFrameVariants = []
        }
        guard
            expectedVariants.isDisjoint(
                with: expectedIFrameVariants
            )
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let expectedRenditions = try stableRenditionIDs(
            in: first,
            includesIFrameTrickPlay: includesIFrameTrickPlay
        )
        for pathway in pathways.dropFirst() {
            let iFrameVariants: Set<String>
            if includesIFrameTrickPlay {
                iFrameVariants = try stableVariantIDs(
                    in: pathway.iFrameVariants
                )
            } else {
                iFrameVariants = []
            }
            guard
                try stableVariantIDs(in: pathway.variants)
                    == expectedVariants,
                iFrameVariants == expectedIFrameVariants,
                expectedVariants.isDisjoint(with: iFrameVariants),
                try stableRenditionIDs(
                    in: pathway,
                    includesIFrameTrickPlay: includesIFrameTrickPlay
                ) == expectedRenditions
            else {
                throw HLSDownloadError.invalidPlaylist
            }
        }
    }

    private static func stableVariantIDs(
        in variants: [HLSVariant]
    ) throws -> Set<String> {
        let ids = variants.compactMap(\.stableID)
        guard ids.count == variants.count,
            Set(ids).count == ids.count
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return Set(ids)
    }

    private static func stableRenditionIDs(
        in pathway: HLSPathway,
        includesIFrameTrickPlay: Bool
    ) throws -> Set<StableRenditionKey> {
        let variants =
            pathway.variants
            + (includesIFrameTrickPlay ? pathway.iFrameVariants : [])
        let groupKeys = renditionGroupKeys(in: variants)
        let downloadable = pathway.renditions.filter {
            $0.url != nil
                && groupKeys.contains(
                    StableRenditionGroupKey(
                        kind: $0.kind,
                        groupID: $0.groupID
                    )
                )
        }
        let keys = downloadable.compactMap { rendition in
            rendition.stableID.map {
                StableRenditionKey(kind: rendition.kind, id: $0)
            }
        }
        guard keys.count == downloadable.count,
            Set(keys).count == keys.count
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return Set(keys)
    }

    private static func renditionGroupKeys(
        in variants: [HLSVariant]
    ) -> Set<StableRenditionGroupKey> {
        var keys: Set<StableRenditionGroupKey> = []
        for variant in variants {
            if let groupID = variant.audioGroupID {
                keys.insert(.init(kind: .audio, groupID: groupID))
            }
            if let groupID = variant.subtitleGroupID {
                keys.insert(.init(kind: .subtitles, groupID: groupID))
            }
            if let groupID = variant.videoGroupID {
                keys.insert(.init(kind: .video, groupID: groupID))
            }
            if case .group(let groupID) = variant.closedCaptions {
                keys.insert(
                    .init(kind: .closedCaptions, groupID: groupID)
                )
            }
        }
        return keys
    }

    private struct StableRenditionKey: Hashable {
        let kind: HLSRenditionKind
        let id: String

        func hash(into hasher: inout Hasher) {
            hasher.combine(kind)
            hasher.combine(id)
        }
    }

    private struct StableRenditionGroupKey: Hashable {
        let kind: HLSRenditionKind
        let groupID: String

        func hash(into hasher: inout Hasher) {
            hasher.combine(kind)
            hasher.combine(groupID)
        }
    }

    private func makeTrackPlan(
        document: HLSResolvedPlaylistDocument,
        descriptor: HLSOfflinePackageTrack
    ) throws -> HLSOfflinePackageTrackPlan {
        guard document.playlist.kind == .media,
            let media = document.playlist.media
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        if descriptor.kind == .iFrames
            || descriptor.kind == .iFrameVideo
        {
            try HLSMediaPlaylistValidator.validateIFrameTrickPlay(media)
        } else {
            try HLSMediaPlaylistValidator.validateOfflinePackage(
                media
            )
        }
        try HLSOfflineMediaPlaylistWriter.validate(
            contents: document.contents
        )
        return HLSOfflinePackageTrackPlan(
            descriptor: descriptor,
            document: document
        )
    }

    private func makeRenditionTrackPlans(
        _ renditions: [HLSRendition],
        kind: HLSOfflinePackageTrackKind,
        multivariantVariables: [String: String]
    ) async throws -> [HLSOfflinePackageTrackPlan] {
        var tracks: [HLSOfflinePackageTrackPlan] = []
        for (index, rendition) in renditions.lazy.filter({
            $0.url != nil
        }).enumerated() {
            guard let url = rendition.url else {
                continue
            }
            let document = try await playlistResolver.resolveDocument(
                from: url,
                multivariantVariables: multivariantVariables,
                purpose: .mediaPlaylist
            )
            tracks.append(
                try makeTrackPlan(
                    document: document,
                    descriptor: Self.descriptor(
                        for: rendition,
                        kind: kind,
                        index: index
                    )
                )
            )
        }
        return tracks
    }

    private func selectRenditions(
        in renditions: [HLSRendition],
        groupID: String?,
        kind: HLSRenditionKind
    ) throws -> [HLSRendition] {
        guard let groupID else {
            return []
        }
        let provenanceResolver = HLSSubtitleProvenanceResolver(
            policy: renditionPack.resolvedSubtitleProvenance,
            kind: kind
        )
        let candidates = provenanceResolver.eligible(
            renditions.filter {
                $0.groupID == groupID && $0.kind == kind
            })
        let selected: [HLSRendition]
        switch renditionPack.policy(for: kind) {
        case .disabled:
            selected = []
        case .defaultOrFirst:
            selected =
                Self.defaultOrFirst(
                    in: provenanceResolver.preferred(candidates)
                ).map { [$0] }
                ?? []
        case .preferredLanguages(let languages):
            var languageSelections: [HLSRendition] = []
            for language in languages {
                let normalized = Self.normalizedLanguage(language)
                guard !normalized.isEmpty else {
                    continue
                }
                let exactMatches = candidates.filter {
                    Self.normalizedLanguage($0.language)
                        == normalized
                }
                let fallbackMatches = candidates.filter {
                    Self.languagesMatch(
                        Self.normalizedLanguage($0.language),
                        normalized
                    )
                }
                let match =
                    provenanceResolver.preferred(exactMatches).first
                    ?? provenanceResolver.preferred(fallbackMatches)
                    .first
                if let match, !languageSelections.contains(match) {
                    languageSelections.append(match)
                }
            }
            if languageSelections.isEmpty,
                let fallback = Self.defaultOrFirst(
                    in: provenanceResolver.preferred(candidates)
                )
            {
                languageSelections.append(fallback)
            }
            selected = languageSelections
        case .named(let names):
            var namedSelections: [HLSRendition] = []
            for name in names {
                let matches = candidates.filter { $0.name == name }
                if let match = provenanceResolver.preferred(matches).first,
                    !namedSelections.contains(match)
                {
                    namedSelections.append(match)
                }
            }
            selected = namedSelections
        case .all:
            selected = candidates.filter { $0.url != nil }
        }
        guard
            selected.lazy.filter({ $0.url != nil }).count
                <= renditionPack.renditionLimit
        else {
            throw HLSDownloadError.offlineRenditionLimitExceeded(
                limit: renditionPack.renditionLimit
            )
        }
        return selected
    }

    private static func defaultOrFirst(
        in renditions: [HLSRendition]
    ) -> HLSRendition? {
        renditions.first(where: \.isDefault)
            ?? renditions.first(where: \.isAutoselect)
            ?? renditions.first
    }

    private static func descriptor(
        for rendition: HLSRendition,
        kind: HLSOfflinePackageTrackKind,
        index: Int
    ) -> HLSOfflinePackageTrack {
        let directoryName: String
        switch kind {
        case .primary:
            directoryName = "primary"
        case .audio:
            directoryName = String(format: "audio-%03d", index)
        case .subtitles:
            directoryName = String(format: "subtitles-%03d", index)
        case .video:
            directoryName = String(format: "video-%03d", index)
        case .iFrames:
            directoryName = "i-frames"
        case .iFrameVideo:
            directoryName = String(format: "i-frame-video-%03d", index)
        }
        return HLSOfflinePackageTrack(
            kind: kind,
            name: rendition.name,
            language: rendition.language,
            associatedLanguage: rendition.associatedLanguage,
            stableID: rendition.stableID,
            instreamID: rendition.instreamID,
            characteristics: rendition.characteristics,
            channels: rendition.channels,
            audioBitDepth: rendition.audioBitDepth,
            audioSampleRate: rendition.audioSampleRate,
            isDefault: rendition.isDefault,
            isAutoselect: rendition.isAutoselect,
            isForced: rendition.isForced,
            relativePlaylistPath:
                "media/\(directoryName)/index.m3u8"
        )
    }

    private static func normalizedLanguage(
        _ language: String?
    ) -> String {
        language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
            ?? ""
    }

    private static func languagesMatch(
        _ renditionLanguage: String,
        _ preferredLanguage: String
    ) -> Bool {
        guard !renditionLanguage.isEmpty, !preferredLanguage.isEmpty else {
            return false
        }
        return renditionLanguage == preferredLanguage
            || renditionLanguage.hasPrefix(preferredLanguage + "-")
            || preferredLanguage.hasPrefix(renditionLanguage + "-")
    }
}
