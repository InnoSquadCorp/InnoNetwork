import Foundation

extension HLSLowLatencyParser {
    static func parsePreloadHints(
        _ lines: [String],
        protocolVersion: Int?,
        partialTargetDuration: Double?,
        relativeTo sourceURL: URL
    ) throws -> [HLSPreloadHint] {
        if lines.contains("#EXT-X-ENDLIST"),
            lines.contains(where: {
                $0.hasPrefix("#EXT-X-PRELOAD-HINT:")
            })
        {
            throw HLSDownloadError.invalidPlaylist
        }
        var hints: [HLSPreloadHint] = []
        var identities: Set<PreloadHintIdentity> = []
        for line in lines
        where line.hasPrefix("#EXT-X-PRELOAD-HINT:") {
            let attributes = try HLSAttributeListParser.parse(
                String(
                    line.dropFirst("#EXT-X-PRELOAD-HINT:".count)
                )
            )
            guard
                let typeValue = attributes["TYPE"],
                !attributes.isQuoted("TYPE")
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            let type: HLSPreloadHintType
            let encryptionKey: HLSEncryptionKeyPreload?
            let identity: PreloadHintIdentity
            switch typeValue {
            case "PART":
                guard partialTargetDuration != nil else {
                    throw HLSDownloadError.invalidPlaylist
                }
                type = .partialSegment
                encryptionKey = nil
                identity = .resource(type)
            case "MAP":
                type = .initializationMap
                encryptionKey = nil
                identity = .resource(type)
            case "KEY":
                let keyFormat = try parseEncryptionKeyFormat(
                    attributes,
                    protocolVersion: protocolVersion
                )
                identity = .key(keyFormat)
                guard identities.insert(identity).inserted else {
                    continue
                }
                let key = try parseEncryptionKeyPreload(
                    attributes,
                    protocolVersion: protocolVersion,
                    keyFormat: keyFormat
                )
                type = .encryptionKey
                encryptionKey = key
            default:
                continue
            }
            if type != .encryptionKey,
                !identities.insert(identity).inserted
            {
                continue
            }
            let estimatedFirstUseDate =
                try parseEstimatedFirstUseDate(attributes)
            if type != .encryptionKey,
                containsKeyOnlyAttributes(attributes)
            {
                throw HLSDownloadError.invalidPlaylist
            }
            guard
                let uri = attributes["URI"],
                attributes.isQuoted("URI"),
                !uri.isEmpty,
                let url = URL(
                    string: uri,
                    relativeTo: sourceURL
                )?.absoluteURL
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            let start = try optionalNonnegativeInteger(
                attributes,
                name: "BYTERANGE-START"
            )
            let length = try optionalPositiveInteger(
                attributes,
                name: "BYTERANGE-LENGTH"
            )
            hints.append(
                HLSPreloadHint(
                    type: type,
                    url: url,
                    byteRangeStart: start,
                    byteRangeLength: length,
                    estimatedFirstUseDate:
                        estimatedFirstUseDate,
                    encryptionKey: encryptionKey
                )
            )
        }
        return hints
    }

    static func parseEncryptionKeyPreload(
        _ attributes: HLSAttributeList,
        protocolVersion: Int?,
        keyFormat: String
    ) throws -> HLSEncryptionKeyPreload {
        guard
            let method = attributes["METHOD"],
            !attributes.isQuoted("METHOD"),
            !method.isEmpty,
            method != "NONE"
        else {
            throw HLSDownloadError.invalidPlaylist
        }

        let keyFormatVersions: [Int]
        if let value = attributes["KEYFORMATVERSIONS"] {
            guard
                (protocolVersion ?? 1) >= 5,
                attributes.isQuoted("KEYFORMATVERSIONS")
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            keyFormatVersions =
                try HLSKeyAttributeParser
                .parseKeyFormatVersions(value)
        } else {
            keyFormatVersions = [1]
        }

        return HLSEncryptionKeyPreload(
            method: method,
            keyFormat: keyFormat,
            keyFormatVersions: keyFormatVersions
        )
    }

    static func parseEncryptionKeyFormat(
        _ attributes: HLSAttributeList,
        protocolVersion: Int?
    ) throws -> String {
        guard let value = attributes["KEYFORMAT"] else {
            return "identity"
        }
        guard
            (protocolVersion ?? 1) >= 5,
            attributes.isQuoted("KEYFORMAT"),
            !value.isEmpty
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return value
    }

    static func parseEstimatedFirstUseDate(
        _ attributes: HLSAttributeList
    ) throws -> Date? {
        guard let value = attributes["DATE-OF-FIRST-USE"] else {
            return nil
        }
        guard attributes.isQuoted("DATE-OF-FIRST-USE") else {
            throw HLSDownloadError.invalidPlaylist
        }
        return try HLSTimelineParser.parseDate(value)
    }

    static func containsKeyOnlyAttributes(
        _ attributes: HLSAttributeList
    ) -> Bool {
        [
            "KEYFORMAT",
            "KEYFORMATVERSIONS",
            "METHOD",
        ].contains { attributes[$0] != nil }
    }

    private enum PreloadHintIdentity: Hashable {
        case resource(HLSPreloadHintType)
        case key(String)
    }

}
