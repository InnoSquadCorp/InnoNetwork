import Foundation

enum HLSMultivariantPlaylistParser {
    static func parseVariants(
        _ lines: [String],
        renditions: [HLSRendition],
        relativeTo sourceURL: URL
    ) throws -> [HLSVariant] {
        var variants: [HLSVariant] = []
        for index in lines.indices {
            let line = lines[index]
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else {
                continue
            }
            let attributes = try HLSAttributeListParser.parse(
                String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            )
            try HLSPlaylistAttributeDecoder.requireQuotedAttributes(
                [
                    "AUDIO",
                    "ALLOWED-CPC",
                    "SUBTITLES",
                    "VIDEO",
                    "CODECS",
                    "REQ-VIDEO-LAYOUT",
                    "SUPPLEMENTAL-CODECS",
                    "STABLE-VARIANT-ID",
                    "PATHWAY-ID",
                ],
                in: attributes
            )
            try HLSPlaylistAttributeDecoder.requireUnquotedAttributes(
                [
                    "AVERAGE-BANDWIDTH",
                    "BANDWIDTH",
                    "FRAME-RATE",
                    "HDCP-LEVEL",
                    "RESOLUTION",
                    "SCORE",
                    "VIDEO-RANGE",
                ],
                in: attributes
            )
            let followingLine = lines.dropFirst(index + 1).first {
                !$0.isEmpty
            }
            guard
                let uriLine = followingLine,
                !uriLine.hasPrefix("#"),
                let variantURL = URL(
                    string: uriLine,
                    relativeTo: sourceURL
                )?.absoluteURL,
                let bandwidth = attributes["BANDWIDTH"].flatMap(Int.init),
                bandwidth > 0
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            try validateReferencedGroups(
                attributes,
                renditions: renditions
            )
            let closedCaptions = try parseClosedCaptions(
                attributes,
                renditions: renditions
            )
            let resolution = HLSPlaylistAttributeDecoder.parseResolution(
                attributes["RESOLUTION"]
            )
            let videoRange: String?
            switch try HLSPlaylistAttributeDecoder.parseVideoRange(
                attributes["VIDEO-RANGE"]
            ) {
            case .supported(let value):
                videoRange = value
            case .unsupported:
                continue
            }
            let requiredVideoLayouts: [HLSRequiredVideoLayout]
            switch try HLSPlaylistAttributeDecoder
                .parseRequiredVideoLayouts(
                    attributes["REQ-VIDEO-LAYOUT"]
                )
            {
            case .supported(let value):
                requiredVideoLayouts = value
            case .unsupported:
                continue
            }
            variants.append(
                HLSVariant(
                    url: variantURL,
                    bandwidth: bandwidth,
                    averageBandwidth:
                        try HLSPlaylistAttributeDecoder
                        .parsePositiveInteger(
                            attributes["AVERAGE-BANDWIDTH"]
                        ),
                    score:
                        try HLSPlaylistAttributeDecoder
                        .parsePositiveDouble(attributes["SCORE"]),
                    width: resolution?.width,
                    height: resolution?.height,
                    audioGroupID: attributes["AUDIO"],
                    subtitleGroupID: attributes["SUBTITLES"],
                    videoGroupID: attributes["VIDEO"],
                    closedCaptions: closedCaptions,
                    codecs:
                        try HLSPlaylistAttributeDecoder
                        .parseStringList(attributes["CODECS"]),
                    supplementalCodecs:
                        try HLSPlaylistAttributeDecoder
                        .parseStringList(
                            attributes["SUPPLEMENTAL-CODECS"]
                        ),
                    frameRate:
                        try HLSPlaylistAttributeDecoder
                        .parsePositiveDouble(
                            attributes["FRAME-RATE"]
                        ),
                    videoRange: videoRange,
                    hdcpLevel:
                        try HLSPlaylistAttributeDecoder
                        .parseHDCPLevel(attributes["HDCP-LEVEL"]),
                    allowedContentProtectionConfigurations:
                        try HLSPlaylistAttributeDecoder
                        .parseAllowedContentProtectionConfigurations(
                            attributes["ALLOWED-CPC"]
                        ),
                    requiredVideoLayouts: requiredVideoLayouts,
                    stableID:
                        try HLSPlaylistAttributeDecoder
                        .parseStableID(
                            attributes["STABLE-VARIANT-ID"]
                        ),
                    pathwayID:
                        try HLSPlaylistAttributeDecoder
                        .parsePathwayID(attributes["PATHWAY-ID"])
                )
            )
        }
        return variants
    }

    static func parseIFrameVariants(
        _ lines: [String],
        renditions: [HLSRendition],
        relativeTo sourceURL: URL
    ) throws -> [HLSVariant] {
        try lines.compactMap { line -> HLSVariant? in
            guard line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") else {
                return nil
            }
            let attributes = try HLSAttributeListParser.parse(
                String(
                    line.dropFirst(
                        "#EXT-X-I-FRAME-STREAM-INF:".count
                    )
                )
            )
            try HLSPlaylistAttributeDecoder.requireQuotedAttributes(
                [
                    "ALLOWED-CPC",
                    "VIDEO",
                    "CODECS",
                    "REQ-VIDEO-LAYOUT",
                    "SUPPLEMENTAL-CODECS",
                    "STABLE-VARIANT-ID",
                    "PATHWAY-ID",
                ],
                in: attributes
            )
            try HLSPlaylistAttributeDecoder.requireUnquotedAttributes(
                [
                    "AVERAGE-BANDWIDTH",
                    "BANDWIDTH",
                    "HDCP-LEVEL",
                    "RESOLUTION",
                    "SCORE",
                    "VIDEO-RANGE",
                ],
                in: attributes
            )
            guard
                attributes["FRAME-RATE"] == nil,
                attributes["AUDIO"] == nil,
                attributes["SUBTITLES"] == nil,
                attributes["CLOSED-CAPTIONS"] == nil,
                let uri = attributes["URI"],
                attributes.isQuoted("URI"),
                !uri.isEmpty,
                let url = URL(
                    string: uri,
                    relativeTo: sourceURL
                )?.absoluteURL,
                let bandwidth = attributes["BANDWIDTH"].flatMap(Int.init),
                bandwidth > 0
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            if let videoGroupID = attributes["VIDEO"],
                !renditions.contains(where: {
                    $0.kind == .video && $0.groupID == videoGroupID
                })
            {
                throw HLSDownloadError.invalidPlaylist
            }
            let resolution = HLSPlaylistAttributeDecoder.parseResolution(attributes["RESOLUTION"])
            let videoRange: String?
            switch try HLSPlaylistAttributeDecoder.parseVideoRange(
                attributes["VIDEO-RANGE"]
            ) {
            case .supported(let value):
                videoRange = value
            case .unsupported:
                return nil
            }
            let requiredVideoLayouts: [HLSRequiredVideoLayout]
            switch try HLSPlaylistAttributeDecoder
                .parseRequiredVideoLayouts(
                    attributes["REQ-VIDEO-LAYOUT"]
                )
            {
            case .supported(let value):
                requiredVideoLayouts = value
            case .unsupported:
                return nil
            }
            return HLSVariant(
                url: url,
                bandwidth: bandwidth,
                averageBandwidth: try HLSPlaylistAttributeDecoder.parsePositiveInteger(
                    attributes["AVERAGE-BANDWIDTH"]
                ),
                score: try HLSPlaylistAttributeDecoder.parsePositiveDouble(attributes["SCORE"]),
                width: resolution?.width,
                height: resolution?.height,
                audioGroupID: nil,
                subtitleGroupID: nil,
                videoGroupID: attributes["VIDEO"],
                closedCaptions: nil,
                codecs: try HLSPlaylistAttributeDecoder.parseStringList(attributes["CODECS"]),
                supplementalCodecs: try HLSPlaylistAttributeDecoder.parseStringList(
                    attributes["SUPPLEMENTAL-CODECS"]
                ),
                frameRate: nil,
                videoRange: videoRange,
                hdcpLevel:
                    try HLSPlaylistAttributeDecoder
                    .parseHDCPLevel(attributes["HDCP-LEVEL"]),
                allowedContentProtectionConfigurations:
                    try HLSPlaylistAttributeDecoder
                    .parseAllowedContentProtectionConfigurations(
                        attributes["ALLOWED-CPC"]
                    ),
                requiredVideoLayouts: requiredVideoLayouts,
                stableID: try HLSPlaylistAttributeDecoder.parseStableID(
                    attributes["STABLE-VARIANT-ID"]
                ),
                pathwayID: try HLSPlaylistAttributeDecoder.parsePathwayID(
                    attributes["PATHWAY-ID"]
                )
            )
        }
    }

    static func parseRenditions(
        _ lines: [String],
        relativeTo sourceURL: URL
    ) throws -> [HLSRendition] {
        var renditions: [HLSRendition] = []
        var groupNames: [RenditionGroupKey: Set<String>] = [:]
        var defaultGroups: Set<RenditionGroupKey> = []

        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            let attributes = try HLSAttributeListParser.parse(
                String(line.dropFirst("#EXT-X-MEDIA:".count))
            )
            try HLSPlaylistAttributeDecoder.requireQuotedAttributes(
                [
                    "ASSOC-LANGUAGE",
                    "CHANNELS",
                    "CHARACTERISTICS",
                    "GROUP-ID",
                    "INSTREAM-ID",
                    "LANGUAGE",
                    "NAME",
                    "STABLE-RENDITION-ID",
                    "URI",
                ],
                in: attributes
            )
            try HLSPlaylistAttributeDecoder.requireUnquotedAttributes(
                [
                    "AUTOSELECT",
                    "BIT-DEPTH",
                    "DEFAULT",
                    "FORCED",
                    "SAMPLE-RATE",
                    "TYPE",
                ],
                in: attributes
            )
            let kind: HLSRenditionKind
            switch attributes["TYPE"]?.uppercased() {
            case "AUDIO":
                kind = .audio
            case "SUBTITLES":
                kind = .subtitles
            case "VIDEO":
                kind = .video
            case "CLOSED-CAPTIONS":
                kind = .closedCaptions
            default:
                throw HLSDownloadError.invalidPlaylist
            }
            guard let groupID = attributes["GROUP-ID"], !groupID.isEmpty,
                let name = attributes["NAME"], !name.isEmpty
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            let groupKey = RenditionGroupKey(
                kind: kind,
                groupID: groupID
            )
            guard groupNames[groupKey, default: []].insert(name).inserted
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            let isDefault = try parseYesNo(
                attributes["DEFAULT"],
                defaultValue: false
            )
            let isAutoselect = try parseYesNo(
                attributes["AUTOSELECT"],
                defaultValue: false
            )
            let isForced = try parseYesNo(
                attributes["FORCED"],
                defaultValue: false
            )
            guard kind == .subtitles || attributes["FORCED"] == nil else {
                throw HLSDownloadError.invalidPlaylist
            }
            guard
                !isDefault
                    || attributes["AUTOSELECT"] == nil
                    || isAutoselect
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            if isDefault,
                !defaultGroups.insert(groupKey).inserted
            {
                throw HLSDownloadError.invalidPlaylist
            }
            let renditionURL: URL?
            if let uri = attributes["URI"], !uri.isEmpty {
                guard kind != .closedCaptions else {
                    throw HLSDownloadError.invalidPlaylist
                }
                guard
                    let resolvedURL = URL(
                        string: uri,
                        relativeTo: sourceURL
                    )?.absoluteURL
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                renditionURL = resolvedURL
            } else {
                guard
                    kind == .audio
                        || kind == .video
                        || kind == .closedCaptions
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                renditionURL = nil
            }
            let language = try HLSPlaylistAttributeDecoder.parseNonemptyString(
                attributes["LANGUAGE"]
            )
            let associatedLanguage = try HLSPlaylistAttributeDecoder.parseNonemptyString(
                attributes["ASSOC-LANGUAGE"]
            )
            let stableID = try HLSPlaylistAttributeDecoder.parseStableID(
                attributes["STABLE-RENDITION-ID"]
            )
            let instreamID = try HLSPlaylistAttributeDecoder.parseInstreamID(
                attributes["INSTREAM-ID"],
                kind: kind
            )
            let characteristics = try HLSPlaylistAttributeDecoder.parseStringList(
                attributes["CHARACTERISTICS"]
            )
            let channels = try HLSPlaylistAttributeDecoder.parseAudioChannels(
                attributes["CHANNELS"],
                kind: kind
            )
            let audioBitDepth = try HLSPlaylistAttributeDecoder.parseAudioInteger(
                attributes["BIT-DEPTH"],
                kind: kind
            )
            let audioSampleRate = try HLSPlaylistAttributeDecoder.parseAudioInteger(
                attributes["SAMPLE-RATE"],
                kind: kind
            )
            renditions.append(
                HLSRendition(
                    kind: kind,
                    groupID: groupID,
                    name: name,
                    language: language,
                    associatedLanguage: associatedLanguage,
                    stableID: stableID,
                    instreamID: instreamID,
                    characteristics: characteristics,
                    channels: channels,
                    audioBitDepth: audioBitDepth,
                    audioSampleRate: audioSampleRate,
                    url: renditionURL,
                    isDefault: isDefault,
                    isAutoselect: isAutoselect,
                    isForced: isForced
                )
            )
        }
        return renditions
    }

    private static func validateReferencedGroups(
        _ attributes: HLSAttributeList,
        renditions: [HLSRendition]
    ) throws {
        for reference in [
            (name: "AUDIO", kind: HLSRenditionKind.audio),
            (name: "SUBTITLES", kind: .subtitles),
            (name: "VIDEO", kind: .video),
        ] {
            guard let groupID = attributes[reference.name] else {
                continue
            }
            guard
                renditions.contains(where: {
                    $0.kind == reference.kind && $0.groupID == groupID
                })
            else {
                throw HLSDownloadError.invalidPlaylist
            }
        }
    }

    private static func parseClosedCaptions(
        _ attributes: HLSAttributeList,
        renditions: [HLSRendition]
    ) throws -> HLSClosedCaptionReference? {
        guard let value = attributes["CLOSED-CAPTIONS"] else {
            return nil
        }
        if value == "NONE", !attributes.isQuoted("CLOSED-CAPTIONS") {
            return .explicitlyNone
        }
        guard
            attributes.isQuoted("CLOSED-CAPTIONS"),
            renditions.contains(where: {
                $0.kind == .closedCaptions && $0.groupID == value
            })
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return .group(value)
    }

    static func parseYesNo(
        _ value: String?,
        defaultValue: Bool
    ) throws -> Bool {
        guard let value else {
            return defaultValue
        }
        switch value {
        case "YES":
            return true
        case "NO":
            return false
        default:
            throw HLSDownloadError.invalidPlaylist
        }
    }

    private struct RenditionGroupKey: Hashable {
        let kind: HLSRenditionKind
        let groupID: String

        func hash(into hasher: inout Hasher) {
            hasher.combine(kind)
            hasher.combine(groupID)
        }
    }
}
