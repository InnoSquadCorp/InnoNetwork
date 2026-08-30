import Foundation
import InnoNetworkHLS

struct HLSLiveDVRSelectedRendition: Sendable {
    let identity: HLSLiveDVRRenditionIdentity
    let rendition: HLSRendition
    let track: HLSLiveDVRTrack
    let relativeDirectoryPath: String

    func source(
        in snapshot: HLSLivePlaylistSnapshot,
        initialPathwayID: String?
    ) throws -> HLSRendition {
        if snapshot.pathwayID != initialPathwayID,
            rendition.stableID == nil
        {
            throw HLSLiveDVRError.unsupportedFeature(
                .incompleteExternalRendition
            )
        }
        guard
            let candidate = snapshot.availableRenditions.first(
                where: { identity.matches($0) }
            ),
            candidate.url != nil,
            let variant = snapshot.selectedVariant,
            Self.groupID(
                for: candidate.kind,
                in: variant
            ) == candidate.groupID
        else {
            throw HLSLiveDVRError.unsupportedFeature(
                .incompleteExternalRendition
            )
        }
        return candidate
    }

    private static func groupID(
        for kind: HLSRenditionKind,
        in variant: HLSVariant
    ) -> String? {
        switch kind {
        case .audio:
            return variant.audioGroupID
        case .video:
            return variant.videoGroupID
        case .subtitles:
            return variant.subtitleGroupID
        case .closedCaptions:
            guard case .group(let groupID) = variant.closedCaptions else {
                return nil
            }
            return groupID
        }
    }
}

enum HLSLiveDVRRenditionIdentity: Hashable, Sendable {
    case stable(kind: HLSRenditionKind, id: String)
    case declared(
        kind: HLSRenditionKind,
        groupID: String,
        name: String,
        language: String?
    )

    init(_ rendition: HLSRendition) {
        if let stableID = rendition.stableID {
            self = .stable(kind: rendition.kind, id: stableID)
        } else {
            self = .declared(
                kind: rendition.kind,
                groupID: rendition.groupID,
                name: rendition.name,
                language: rendition.language
            )
        }
    }

    func matches(_ rendition: HLSRendition) -> Bool {
        switch self {
        case .stable(let kind, let id):
            return rendition.kind == kind
                && rendition.stableID == id
        case .declared(let kind, let groupID, let name, let language):
            return rendition.kind == kind
                && rendition.groupID == groupID
                && rendition.name == name
                && rendition.language == language
        }
    }
}

struct HLSLiveDVRRenditionSelection: Sendable {
    let external: [HLSLiveDVRSelectedRendition]
    let inBandClosedCaptions: [HLSRendition]
}

enum HLSLiveDVRRenditionSelector {
    static func select(
        from snapshot: HLSLivePlaylistSnapshot,
        pack: HLSLiveDVRRenditionPack
    ) throws -> HLSLiveDVRRenditionSelection {
        guard let variant = snapshot.selectedVariant else {
            return HLSLiveDVRRenditionSelection(
                external: [],
                inBandClosedCaptions: []
            )
        }

        var external: [HLSLiveDVRSelectedRendition] = []
        for kind in supportedExternalKinds {
            let candidates = candidates(
                for: kind,
                variant: variant,
                renditions: snapshot.availableRenditions
            )
            let selected = select(
                candidates,
                policy: pack.policy(for: kind)
            ).filter { $0.url != nil }
            guard selected.count <= pack.maximumRenditionsPerKind else {
                throw HLSLiveDVRError.renditionLimitExceeded(
                    limit: pack.maximumRenditionsPerKind
                )
            }
            let kindIndex = external.count(where: { $0.rendition.kind == kind })
            external.append(
                contentsOf: selected.enumerated().compactMap { offset, rendition in
                    descriptor(
                        for: rendition,
                        index: kindIndex + offset
                    )
                }
            )
        }

        let closedCaptions: [HLSRendition]
        if case .group(let groupID) = variant.closedCaptions {
            closedCaptions = snapshot.availableRenditions.filter {
                $0.kind == .closedCaptions
                    && $0.groupID == groupID
                    && $0.url == nil
            }
        } else {
            closedCaptions = []
        }
        return HLSLiveDVRRenditionSelection(
            external: external,
            inBandClosedCaptions: closedCaptions
        )
    }

    static func retainedClosedCaptions(
        _ selected: [HLSRendition],
        in snapshot: HLSLivePlaylistSnapshot,
        initialPathwayID: String?
    ) -> [HLSRendition] {
        guard
            let variant = snapshot.selectedVariant,
            case .group(let groupID) = variant.closedCaptions
        else {
            return []
        }
        let candidates = snapshot.availableRenditions.filter {
            $0.kind == .closedCaptions
                && $0.groupID == groupID
                && $0.url == nil
        }
        return selected.compactMap { rendition in
            if snapshot.pathwayID != initialPathwayID,
                rendition.stableID == nil
            {
                return nil
            }
            let identity = HLSLiveDVRRenditionIdentity(rendition)
            return candidates.first(where: identity.matches)
        }
    }

    private static let supportedExternalKinds: [HLSRenditionKind] = [
        .video,
        .audio,
        .subtitles,
    ]

    private static func candidates(
        for kind: HLSRenditionKind,
        variant: HLSVariant,
        renditions: [HLSRendition]
    ) -> [HLSRendition] {
        let groupID: String?
        switch kind {
        case .audio:
            groupID = variant.audioGroupID
        case .video:
            groupID = variant.videoGroupID
        case .subtitles:
            groupID = variant.subtitleGroupID
        case .closedCaptions:
            groupID = nil
        }
        guard let groupID else {
            return []
        }
        return renditions.filter {
            $0.kind == kind && $0.groupID == groupID
        }
    }

    private static func select(
        _ candidates: [HLSRendition],
        policy: HLSLiveDVRRenditionSelectionPolicy
    ) -> [HLSRendition] {
        switch policy {
        case .disabled:
            return []
        case .defaultOrFirst:
            return defaultOrFirst(in: candidates).map { [$0] } ?? []
        case .preferredLanguages(let languages):
            var result: [HLSRendition] = []
            for language in languages {
                let preferred = normalizedLanguage(language)
                guard !preferred.isEmpty else {
                    continue
                }
                let candidate =
                    candidates.first {
                        normalizedLanguage($0.language) == preferred
                    }
                    ?? candidates.first {
                        languagesMatch(
                            normalizedLanguage($0.language),
                            preferred
                        )
                    }
                if let candidate, !result.contains(candidate) {
                    result.append(candidate)
                }
            }
            if result.isEmpty,
                let fallback = defaultOrFirst(in: candidates)
            {
                result.append(fallback)
            }
            return result
        case .named(let names):
            var result: [HLSRendition] = []
            for name in names {
                if let candidate = candidates.first(where: { $0.name == name }),
                    !result.contains(candidate)
                {
                    result.append(candidate)
                }
            }
            return result
        case .all:
            return candidates
        }
    }

    private static func defaultOrFirst(
        in candidates: [HLSRendition]
    ) -> HLSRendition? {
        candidates.first(where: \.isDefault)
            ?? candidates.first(where: \.isAutoselect)
            ?? candidates.first
    }

    private static func descriptor(
        for rendition: HLSRendition,
        index: Int
    ) -> HLSLiveDVRSelectedRendition? {
        let label: String
        let kind: HLSLiveDVRTrackKind
        switch rendition.kind {
        case .audio:
            label = "audio"
            kind = .audio
        case .video:
            label = "video"
            kind = .video
        case .subtitles:
            label = "subtitles"
            kind = .subtitles
        case .closedCaptions:
            return nil
        }
        let directoryPath = String(
            format: "renditions/%@-%03d",
            label,
            index
        )
        return HLSLiveDVRSelectedRendition(
            identity: HLSLiveDVRRenditionIdentity(rendition),
            rendition: rendition,
            track: HLSLiveDVRTrack(
                kind: kind,
                name: rendition.name,
                language: rendition.language,
                stableID: rendition.stableID,
                relativePlaylistPath: directoryPath + "/index.m3u8"
            ),
            relativeDirectoryPath: directoryPath
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
