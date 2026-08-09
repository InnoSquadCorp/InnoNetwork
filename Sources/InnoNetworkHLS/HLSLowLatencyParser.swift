import Foundation

struct HLSLowLatencyParseResult: Sendable {
    let metadata: HLSLowLatencyMetadata?
    let unsupportedMediaFeatures: [HLSUnsupportedMediaFeature]
}

enum HLSLowLatencyParser {
    private static let tagPrefixes = [
        "#EXT-X-SERVER-CONTROL:",
        "#EXT-X-PART-INF:",
        "#EXT-X-PART:",
        "#EXT-X-PRELOAD-HINT:",
        "#EXT-X-RENDITION-REPORT:",
        "#EXT-X-SKIP:",
    ]

    static func parse(
        _ lines: [String],
        kind: HLSPlaylist.Kind,
        protocolVersion: Int?,
        relativeTo sourceURL: URL
    ) throws -> HLSLowLatencyParseResult {
        let containsLowLatencyTags = lines.contains { line in
            tagPrefixes.contains { line.hasPrefix($0) }
        }
        guard containsLowLatencyTags else {
            return HLSLowLatencyParseResult(
                metadata: nil,
                unsupportedMediaFeatures: []
            )
        }
        guard kind == .media else {
            throw HLSDownloadError.invalidPlaylist
        }
        let effectiveProtocolVersion = protocolVersion ?? 1
        if lines.contains(where: {
            $0.hasPrefix("#EXT-X-SKIP:")
        }), effectiveProtocolVersion < 9 {
            throw HLSDownloadError.invalidPlaylist
        }

        let targetDuration =
            try HLSMediaPlaylistMetadataParser
            .parse(lines)
            .targetDuration
            .map(Double.init)
        let partialTargetDuration = try parsePartialTargetDuration(lines)
        let serverControl = try parseServerControl(
            lines,
            targetDuration: targetDuration,
            partialTargetDuration: partialTargetDuration
        )
        if partialTargetDuration != nil,
            serverControl?.partialSegmentHoldBack == nil
        {
            throw HLSDownloadError.invalidPlaylist
        }
        let partialSegments = try parsePartialSegments(
            lines,
            partialTargetDuration: partialTargetDuration,
            relativeTo: sourceURL
        )
        let preloadHints = try parsePreloadHints(
            lines,
            protocolVersion: protocolVersion,
            partialTargetDuration: partialTargetDuration,
            relativeTo: sourceURL
        )
        let renditionReports = try parseRenditionReports(
            lines,
            relativeTo: sourceURL
        )
        let deltaUpdate = try parseDeltaUpdate(lines)
        if deltaUpdate?.recentlyRemovedDateRangeIDs.isEmpty == false,
            effectiveProtocolVersion < 10
        {
            throw HLSDownloadError.invalidPlaylist
        }

        var unsupportedFeatures: [HLSUnsupportedMediaFeature] = []
        if !partialSegments.isEmpty {
            unsupportedFeatures.append(.partialSegments)
        }
        if !preloadHints.isEmpty {
            unsupportedFeatures.append(.preloadHintResource)
        }
        if !renditionReports.isEmpty {
            unsupportedFeatures.append(.renditionReportResource)
        }
        if deltaUpdate != nil {
            unsupportedFeatures.append(.deltaUpdate)
        }
        return HLSLowLatencyParseResult(
            metadata: HLSLowLatencyMetadata(
                serverControl: serverControl,
                partialSegmentTargetDuration: partialTargetDuration,
                partialSegments: partialSegments,
                preloadHints: preloadHints,
                renditionReports: renditionReports,
                deltaUpdate: deltaUpdate
            ),
            unsupportedMediaFeatures: unsupportedFeatures
        )
    }

    private static func parsePartialTargetDuration(
        _ lines: [String]
    ) throws -> Double? {
        let declarations = lines.filter {
            $0.hasPrefix("#EXT-X-PART-INF:")
        }
        guard declarations.count <= 1 else {
            throw HLSDownloadError.invalidPlaylist
        }
        guard let declaration = declarations.first else {
            return nil
        }
        let attributes = try HLSAttributeListParser.parse(
            String(declaration.dropFirst("#EXT-X-PART-INF:".count))
        )
        guard
            let value = attributes["PART-TARGET"],
            !attributes.isQuoted("PART-TARGET")
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return try positiveDecimal(value)
    }

    private static func parseServerControl(
        _ lines: [String],
        targetDuration: Double?,
        partialTargetDuration: Double?
    ) throws -> HLSServerControl? {
        let declarations = lines.filter {
            $0.hasPrefix("#EXT-X-SERVER-CONTROL:")
        }
        guard declarations.count <= 1 else {
            throw HLSDownloadError.invalidPlaylist
        }
        guard let declaration = declarations.first else {
            return nil
        }
        let attributes = try HLSAttributeListParser.parse(
            String(
                declaration.dropFirst(
                    "#EXT-X-SERVER-CONTROL:".count
                )
            )
        )
        let canBlockReload = try yesNo(
            attributes,
            name: "CAN-BLOCK-RELOAD"
        )
        let canSkipUntil = try optionalPositiveDecimal(
            attributes,
            name: "CAN-SKIP-UNTIL"
        )
        if let canSkipUntil {
            guard let targetDuration,
                canSkipUntil >= 6 * targetDuration
            else {
                throw HLSDownloadError.invalidPlaylist
            }
        }
        let canSkipDateRanges = try yesNo(
            attributes,
            name: "CAN-SKIP-DATERANGES"
        )
        guard !canSkipDateRanges || canSkipUntil != nil else {
            throw HLSDownloadError.invalidPlaylist
        }
        let holdBack = try optionalPositiveDecimal(
            attributes,
            name: "HOLD-BACK"
        )
        if let holdBack {
            guard let targetDuration,
                holdBack >= 3 * targetDuration
            else {
                throw HLSDownloadError.invalidPlaylist
            }
        }
        let partialHoldBack = try optionalPositiveDecimal(
            attributes,
            name: "PART-HOLD-BACK"
        )
        if let partialHoldBack {
            guard let partialTargetDuration,
                partialHoldBack >= 2 * partialTargetDuration
            else {
                throw HLSDownloadError.invalidPlaylist
            }
        }
        return HLSServerControl(
            canBlockReload: canBlockReload,
            canSkipUntil: canSkipUntil,
            canSkipDateRanges: canSkipDateRanges,
            holdBack: holdBack,
            partialSegmentHoldBack: partialHoldBack
        )
    }

    private static func parsePartialSegments(
        _ lines: [String],
        partialTargetDuration: Double?,
        relativeTo sourceURL: URL
    ) throws -> [HLSPartialSegment] {
        var partialSegments: [HLSPartialSegment] = []
        var previousPartURL: URL?
        var previousPartByteRange: HLSByteRange?
        var completedParentFinalPartIndexes: Set<Int> = []
        var segmentIndex = 0
        var expectsSegmentURI = false

        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                expectsSegmentURI = true
                continue
            }
            if !line.isEmpty, !line.hasPrefix("#"), expectsSegmentURI {
                if partialSegments.last?.segmentIndex == segmentIndex {
                    completedParentFinalPartIndexes.insert(
                        partialSegments.count - 1
                    )
                }
                segmentIndex += 1
                expectsSegmentURI = false
                continue
            }
            guard line.hasPrefix("#EXT-X-PART:") else {
                continue
            }
            guard let partialTargetDuration else {
                throw HLSDownloadError.invalidPlaylist
            }
            let attributes = try HLSAttributeListParser.parse(
                String(line.dropFirst("#EXT-X-PART:".count))
            )
            guard
                let uri = attributes["URI"],
                attributes.isQuoted("URI"),
                !uri.isEmpty,
                let url = URL(
                    string: uri,
                    relativeTo: sourceURL
                )?.absoluteURL,
                let durationValue = attributes["DURATION"],
                !attributes.isQuoted("DURATION")
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            let duration = try positiveDecimal(durationValue)
            guard duration <= partialTargetDuration else {
                throw HLSDownloadError.invalidPlaylist
            }
            let byteRange: HLSByteRange?
            if let value = attributes["BYTERANGE"] {
                guard attributes.isQuoted("BYTERANGE") else {
                    throw HLSDownloadError.invalidPlaylist
                }
                byteRange = try resolveByteRange(
                    value,
                    previous:
                        previousPartURL == url
                        ? previousPartByteRange
                        : nil
                )
            } else {
                byteRange = nil
            }
            partialSegments.append(
                HLSPartialSegment(
                    url: url,
                    duration: duration,
                    segmentIndex: segmentIndex,
                    isIndependent: try yesNo(
                        attributes,
                        name: "INDEPENDENT"
                    ),
                    isGap: try yesNo(
                        attributes,
                        name: "GAP"
                    ),
                    byteRange: byteRange
                )
            )
            previousPartURL = url
            previousPartByteRange = byteRange
        }
        guard !partialSegments.isEmpty else {
            return []
        }
        guard let partialTargetDuration else {
            throw HLSDownloadError.invalidPlaylist
        }
        for index in partialSegments.indices {
            let part = partialSegments[index]
            guard part.duration < 0.85 * partialTargetDuration else {
                continue
            }
            let isFollowedByGap =
                partialSegments.indices.contains(index + 1)
                && partialSegments[index + 1].segmentIndex
                    == part.segmentIndex
                && partialSegments[index + 1].isGap
            guard
                part.isIndependent
                    || part.isGap
                    || isFollowedByGap
                    || completedParentFinalPartIndexes.contains(index)
            else {
                throw HLSDownloadError.invalidPlaylist
            }
        }
        return partialSegments
    }

    private static func parsePreloadHints(
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

    private static func parseEncryptionKeyPreload(
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

    private static func parseEncryptionKeyFormat(
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

    private static func parseEstimatedFirstUseDate(
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

    private static func containsKeyOnlyAttributes(
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

    private static func parseRenditionReports(
        _ lines: [String],
        relativeTo sourceURL: URL
    ) throws -> [HLSRenditionReport] {
        var reports: [HLSRenditionReport] = []
        var urls: Set<URL> = []
        for line in lines
        where line.hasPrefix("#EXT-X-RENDITION-REPORT:") {
            let attributes = try HLSAttributeListParser.parse(
                String(
                    line.dropFirst(
                        "#EXT-X-RENDITION-REPORT:".count
                    )
                )
            )
            guard
                let uri = attributes["URI"],
                attributes.isQuoted("URI"),
                !uri.isEmpty,
                URL(string: uri)?.scheme == nil,
                let url = URL(
                    string: uri,
                    relativeTo: sourceURL
                )?.absoluteURL,
                urls.insert(url).inserted
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            let lastMediaSequenceNumber =
                try optionalNonnegativeInteger(
                    attributes,
                    name: "LAST-MSN"
                )
            let lastPartialSegmentIndex =
                try optionalNonnegativeInt(
                    attributes,
                    name: "LAST-PART"
                )
            reports.append(
                HLSRenditionReport(
                    url: url,
                    lastMediaSequenceNumber:
                        lastMediaSequenceNumber,
                    lastPartialSegmentIndex:
                        lastPartialSegmentIndex
                )
            )
        }
        return reports
    }

    private static func parseDeltaUpdate(
        _ lines: [String]
    ) throws -> HLSDeltaUpdate? {
        let declarations = lines.filter {
            $0.hasPrefix("#EXT-X-SKIP:")
        }
        guard declarations.count <= 1 else {
            throw HLSDownloadError.invalidPlaylist
        }
        guard let declaration = declarations.first else {
            return nil
        }
        let attributes = try HLSAttributeListParser.parse(
            String(declaration.dropFirst("#EXT-X-SKIP:".count))
        )
        guard
            let value = attributes["SKIPPED-SEGMENTS"],
            !attributes.isQuoted("SKIPPED-SEGMENTS"),
            let skippedSegmentCount = Int(value),
            skippedSegmentCount >= 0
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let recentlyRemovedDateRangeIDs: [String]
        if let value = attributes["RECENTLY-REMOVED-DATERANGES"] {
            guard attributes.isQuoted("RECENTLY-REMOVED-DATERANGES") else {
                throw HLSDownloadError.invalidPlaylist
            }
            recentlyRemovedDateRangeIDs =
                value.split(
                    separator: "\t",
                    omittingEmptySubsequences: false
                ).map(String.init)
            guard
                !recentlyRemovedDateRangeIDs.isEmpty,
                recentlyRemovedDateRangeIDs.allSatisfy({
                    !$0.isEmpty
                }),
                Set(recentlyRemovedDateRangeIDs).count
                    == recentlyRemovedDateRangeIDs.count
            else {
                throw HLSDownloadError.invalidPlaylist
            }
        } else {
            recentlyRemovedDateRangeIDs = []
        }
        return HLSDeltaUpdate(
            skippedSegmentCount: skippedSegmentCount,
            recentlyRemovedDateRangeIDs:
                recentlyRemovedDateRangeIDs
        )
    }

    private static func yesNo(
        _ attributes: HLSAttributeList,
        name: String
    ) throws -> Bool {
        guard let value = attributes[name] else {
            return false
        }
        guard !attributes.isQuoted(name) else {
            throw HLSDownloadError.invalidPlaylist
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

    private static func optionalPositiveDecimal(
        _ attributes: HLSAttributeList,
        name: String
    ) throws -> Double? {
        guard let value = attributes[name] else {
            return nil
        }
        guard !attributes.isQuoted(name) else {
            throw HLSDownloadError.invalidPlaylist
        }
        return try positiveDecimal(value)
    }

    private static func positiveDecimal(
        _ value: String
    ) throws -> Double {
        guard let result = Double(value), result.isFinite, result > 0 else {
            throw HLSDownloadError.invalidPlaylist
        }
        return result
    }

    private static func optionalNonnegativeInteger(
        _ attributes: HLSAttributeList,
        name: String
    ) throws -> Int64? {
        guard let value = attributes[name] else {
            return nil
        }
        guard
            !attributes.isQuoted(name),
            let result = Int64(value),
            result >= 0
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return result
    }

    private static func optionalPositiveInteger(
        _ attributes: HLSAttributeList,
        name: String
    ) throws -> Int64? {
        guard
            let result = try optionalNonnegativeInteger(
                attributes,
                name: name
            )
        else {
            return nil
        }
        guard result > 0 else {
            throw HLSDownloadError.invalidPlaylist
        }
        return result
    }

    private static func optionalNonnegativeInt(
        _ attributes: HLSAttributeList,
        name: String
    ) throws -> Int? {
        guard
            let result = try optionalNonnegativeInteger(
                attributes,
                name: name
            ),
            result <= Int64(Int.max)
        else {
            if attributes[name] == nil {
                return nil
            }
            throw HLSDownloadError.invalidPlaylist
        }
        return Int(result)
    }

    private static func resolveByteRange(
        _ value: String,
        previous: HLSByteRange?
    ) throws -> HLSByteRange {
        let fields = value.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            let lengthValue = fields.first,
            let length = Int64(lengthValue),
            length > 0
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let offset: Int64
        if fields.count == 2 {
            guard let explicitOffset = Int64(fields[1]),
                explicitOffset >= 0
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            offset = explicitOffset
        } else {
            guard let previous else {
                throw HLSDownloadError.invalidPlaylist
            }
            offset = previous.endOffset
        }
        guard let range = HLSByteRange(offset: offset, length: length) else {
            throw HLSDownloadError.invalidPlaylist
        }
        return range
    }
}
