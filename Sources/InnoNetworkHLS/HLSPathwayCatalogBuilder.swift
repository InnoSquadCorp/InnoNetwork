import Foundation

enum HLSPathwayCatalogBuilder {
    static func make(
        playlist: HLSPlaylist,
        manifest: HLSContentSteeringManifest
    ) -> HLSPathwayCatalog? {
        var variants = playlist.variants
        var iFrameVariants = playlist.iFrameVariants
        var renditions = playlist.renditions
        var knownPathwayIDs = Set(
            variants.map { $0.pathwayID ?? HLSPathwayID.implicit }
        )

        for clone in manifest.pathwayClones {
            guard knownPathwayIDs.contains(clone.baseID) else {
                continue
            }
            guard !knownPathwayIDs.contains(clone.id) else {
                return nil
            }
            let baseVariants = variants.filter {
                ($0.pathwayID ?? HLSPathwayID.implicit) == clone.baseID
            }
            let baseIFrameVariants = iFrameVariants.filter {
                ($0.pathwayID ?? HLSPathwayID.implicit) == clone.baseID
            }
            let groupMappings = makeGroupMappings(
                variants: baseVariants + baseIFrameVariants,
                cloneID: clone.id
            )
            let baseRenditions = renditions.filter { rendition in
                groupMappings[
                    GroupKey(
                        kind: rendition.kind,
                        groupID: rendition.groupID
                    )
                ] != nil
            }
            let clonedRenditions: [HLSRendition] = baseRenditions.compactMap {
                rendition in
                let key = GroupKey(
                    kind: rendition.kind,
                    groupID: rendition.groupID
                )
                guard let clonedGroupID = groupMappings[key] else {
                    return nil
                }
                let transformedURL = rendition.url.flatMap {
                    transformedURL(
                        $0,
                        stableID: rendition.stableID,
                        overrideURLs: clone.perRenditionURLs,
                        clone: clone
                    )
                }
                guard rendition.url == nil || transformedURL != nil else {
                    return nil
                }
                return HLSRendition(
                    kind: rendition.kind,
                    groupID: clonedGroupID,
                    name: rendition.name,
                    language: rendition.language,
                    associatedLanguage: rendition.associatedLanguage,
                    stableID: rendition.stableID,
                    instreamID: rendition.instreamID,
                    characteristics: rendition.characteristics,
                    channels: rendition.channels,
                    audioBitDepth: rendition.audioBitDepth,
                    audioSampleRate: rendition.audioSampleRate,
                    url: transformedURL,
                    isDefault: rendition.isDefault,
                    isAutoselect: rendition.isAutoselect,
                    isForced: rendition.isForced
                )
            }
            let clonedVariants = baseVariants.compactMap {
                clonedVariant(
                    $0,
                    groupMappings: groupMappings,
                    clone: clone
                )
            }
            let clonedIFrameVariants = baseIFrameVariants.compactMap {
                clonedVariant(
                    $0,
                    groupMappings: groupMappings,
                    clone: clone
                )
            }
            guard clonedVariants.count == baseVariants.count,
                clonedIFrameVariants.count == baseIFrameVariants.count,
                clonedRenditions.count == baseRenditions.count
            else {
                return nil
            }
            renditions.append(contentsOf: clonedRenditions)
            variants.append(contentsOf: clonedVariants)
            iFrameVariants.append(contentsOf: clonedIFrameVariants)
            knownPathwayIDs.insert(clone.id)
        }

        var pathways: [HLSPathway] = []
        for pathwayID in manifest.pathwayPriority
        where knownPathwayIDs.contains(pathwayID) {
            let pathwayVariants = variants.filter {
                ($0.pathwayID ?? HLSPathwayID.implicit) == pathwayID
            }
            let pathwayIFrameVariants = iFrameVariants.filter {
                ($0.pathwayID ?? HLSPathwayID.implicit) == pathwayID
            }
            guard !pathwayVariants.isEmpty else {
                continue
            }
            pathways.append(
                HLSPathway(
                    id: pathwayID,
                    variants: pathwayVariants,
                    iFrameVariants: pathwayIFrameVariants,
                    renditions: referencedRenditions(
                        variants:
                            pathwayVariants + pathwayIFrameVariants,
                        renditions: renditions
                    )
                )
            )
        }
        return HLSPathwayCatalog(pathways: pathways)
    }

    private static func clonedVariant(
        _ variant: HLSVariant,
        groupMappings: [GroupKey: String],
        clone: HLSContentSteeringManifest.PathwayClone
    ) -> HLSVariant? {
        guard
            let url = transformedURL(
                variant.url,
                stableID: variant.stableID,
                overrideURLs: clone.perVariantURLs,
                clone: clone
            )
        else {
            return nil
        }
        return HLSVariant(
            url: url,
            bandwidth: variant.bandwidth,
            averageBandwidth: variant.averageBandwidth,
            score: variant.score,
            width: variant.width,
            height: variant.height,
            audioGroupID: mappedGroupID(
                variant.audioGroupID,
                kind: .audio,
                mappings: groupMappings
            ),
            subtitleGroupID: mappedGroupID(
                variant.subtitleGroupID,
                kind: .subtitles,
                mappings: groupMappings
            ),
            videoGroupID: mappedGroupID(
                variant.videoGroupID,
                kind: .video,
                mappings: groupMappings
            ),
            closedCaptions: mappedClosedCaptions(
                variant.closedCaptions,
                mappings: groupMappings
            ),
            codecs: variant.codecs,
            supplementalCodecs: variant.supplementalCodecs,
            frameRate: variant.frameRate,
            videoRange: variant.videoRange,
            hdcpLevel: variant.hdcpLevel,
            allowedContentProtectionConfigurations:
                variant.allowedContentProtectionConfigurations,
            requiredVideoLayouts: variant.requiredVideoLayouts,
            stableID: variant.stableID,
            pathwayID: clone.id
        )
    }

    private static func makeGroupMappings(
        variants: [HLSVariant],
        cloneID: String
    ) -> [GroupKey: String] {
        var mappings: [GroupKey: String] = [:]
        for variant in variants {
            insertMapping(
                groupID: variant.audioGroupID,
                kind: .audio,
                cloneID: cloneID,
                into: &mappings
            )
            insertMapping(
                groupID: variant.subtitleGroupID,
                kind: .subtitles,
                cloneID: cloneID,
                into: &mappings
            )
            insertMapping(
                groupID: variant.videoGroupID,
                kind: .video,
                cloneID: cloneID,
                into: &mappings
            )
            if case .group(let groupID) = variant.closedCaptions {
                insertMapping(
                    groupID: groupID,
                    kind: .closedCaptions,
                    cloneID: cloneID,
                    into: &mappings
                )
            }
        }
        return mappings
    }

    private static func insertMapping(
        groupID: String?,
        kind: HLSRenditionKind,
        cloneID: String,
        into mappings: inout [GroupKey: String]
    ) {
        guard let groupID else {
            return
        }
        let key = GroupKey(kind: kind, groupID: groupID)
        mappings[key] = "\(groupID)@\(cloneID)"
    }

    private static func mappedGroupID(
        _ groupID: String?,
        kind: HLSRenditionKind,
        mappings: [GroupKey: String]
    ) -> String? {
        guard let groupID else {
            return nil
        }
        return mappings[GroupKey(kind: kind, groupID: groupID)]
    }

    private static func mappedClosedCaptions(
        _ closedCaptions: HLSClosedCaptionReference?,
        mappings: [GroupKey: String]
    ) -> HLSClosedCaptionReference? {
        guard case .group(let groupID) = closedCaptions else {
            return closedCaptions
        }
        guard
            let mapped = mappings[
                GroupKey(kind: .closedCaptions, groupID: groupID)
            ]
        else {
            return nil
        }
        return .group(mapped)
    }

    private static func referencedRenditions(
        variants: [HLSVariant],
        renditions: [HLSRendition]
    ) -> [HLSRendition] {
        var keys: Set<GroupKey> = []
        for variant in variants {
            if let groupID = variant.audioGroupID {
                keys.insert(GroupKey(kind: .audio, groupID: groupID))
            }
            if let groupID = variant.subtitleGroupID {
                keys.insert(GroupKey(kind: .subtitles, groupID: groupID))
            }
            if let groupID = variant.videoGroupID {
                keys.insert(GroupKey(kind: .video, groupID: groupID))
            }
            if case .group(let groupID) = variant.closedCaptions {
                keys.insert(
                    GroupKey(kind: .closedCaptions, groupID: groupID)
                )
            }
        }
        return renditions.filter {
            keys.contains(GroupKey(kind: $0.kind, groupID: $0.groupID))
        }
    }

    private static func transformedURL(
        _ sourceURL: URL,
        stableID: String?,
        overrideURLs: [String: URL],
        clone: HLSContentSteeringManifest.PathwayClone
    ) -> URL? {
        if let stableID, let override = overrideURLs[stableID] {
            return override
        }
        guard
            var components = URLComponents(
                url: sourceURL,
                resolvingAgainstBaseURL: true
            )
        else {
            return nil
        }
        if let host = clone.host {
            components.host = host
        }
        if !clone.parameters.isEmpty {
            let replacementNames = Set(clone.parameters.keys)
            var queryItems = (components.queryItems ?? []).filter {
                !replacementNames.contains($0.name)
            }
            let sortedNames = clone.parameters.keys.sorted {
                Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
            }
            queryItems.append(
                contentsOf: sortedNames.map {
                    URLQueryItem(
                        name: $0,
                        value: clone.parameters[$0]
                    )
                }
            )
            components.queryItems = queryItems
        }
        return components.url
    }

    private struct GroupKey: Hashable {
        let kind: HLSRenditionKind
        let groupID: String

        func hash(into hasher: inout Hasher) {
            hasher.combine(kind)
            hasher.combine(groupID)
        }
    }
}
