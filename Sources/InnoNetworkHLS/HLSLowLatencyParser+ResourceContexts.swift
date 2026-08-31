import Foundation

extension HLSLowLatencyParser {
    struct ResourceContexts {
        let partialSegments: [HLSLowLatencyResourceContext]
        let preloadHints: [HLSPreloadHintType: HLSLowLatencyResourceContext]
        let initializationMaps: [HLSLowLatencyInitializationMap]
    }

    static func parseResourceContexts(
        _ lines: [String],
        partialSegments: [HLSPartialSegment],
        preloadHints: [HLSPreloadHint],
        relativeTo sourceURL: URL
    ) throws -> ResourceContexts {
        let metadata = try HLSMediaPlaylistMetadataParser.parse(lines)
        var discontinuitySequence = metadata.discontinuitySequence
        var initializationMap: HLSLowLatencyResourceIdentity?
        var anticipatedInitializationMap: HLSLowLatencyResourceIdentity?
        var encryption: HLSLowLatencyEncryptionIdentity?
        var previousSegment: HLSLowLatencyResourceIdentity?
        var pendingSegmentByteRange: String?
        var expectsSegmentURI = false
        var partialContexts: [HLSLowLatencyResourceContext] = []
        var hintContexts: [HLSPreloadHintType: HLSLowLatencyResourceContext] = [:]
        var initializationMaps: [HLSLowLatencyInitializationMap] = []
        var retainedHintTypes: Set<HLSPreloadHintType> = []

        for line in lines {
            if line == "#EXT-X-DISCONTINUITY" {
                let (next, overflow) =
                    discontinuitySequence.addingReportingOverflow(1)
                guard !overflow else {
                    throw HLSDownloadError.invalidPlaylist
                }
                discontinuitySequence = next
                anticipatedInitializationMap = nil
                continue
            }
            if line.hasPrefix("#EXT-X-KEY:") {
                encryption = try parseEncryptionContext(
                    line,
                    relativeTo: sourceURL
                )
                continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                let resource = try parseInitializationMap(
                    line,
                    previousSegment: previousSegment,
                    relativeTo: sourceURL
                )
                initializationMap = resource
                anticipatedInitializationMap = nil
                initializationMaps.append(
                    HLSLowLatencyInitializationMap(
                        resource: resource,
                        context: HLSLowLatencyResourceContext(
                            discontinuitySequence:
                                discontinuitySequence,
                            initializationMap: resource,
                            encryption: encryption
                        )
                    )
                )
                continue
            }
            if line.hasPrefix("#EXT-X-PART:") {
                partialContexts.append(
                    HLSLowLatencyResourceContext(
                        discontinuitySequence:
                            discontinuitySequence,
                        initializationMap: initializationMap,
                        encryption: encryption
                    )
                )
                continue
            }
            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingSegmentByteRange = String(
                    line.dropFirst("#EXT-X-BYTERANGE:".count)
                )
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                expectsSegmentURI = true
                continue
            }
            if expectsSegmentURI,
                !line.isEmpty,
                !line.hasPrefix("#"),
                let url = URL(
                    string: line,
                    relativeTo: sourceURL
                )?.absoluteURL
            {
                let byteRange = try pendingSegmentByteRange.map {
                    try resolveByteRange(
                        $0,
                        previous:
                            previousSegment?.url == url
                            ? previousSegment?.byteRange
                            : nil
                    )
                }
                previousSegment = HLSLowLatencyResourceIdentity(
                    url: url,
                    byteRange: byteRange,
                    openEndedByteRangeStart: nil
                )
                pendingSegmentByteRange = nil
                expectsSegmentURI = false
                continue
            }
            guard line.hasPrefix("#EXT-X-PRELOAD-HINT:") else {
                continue
            }
            let attributes = try HLSAttributeListParser.parse(
                String(line.dropFirst("#EXT-X-PRELOAD-HINT:".count))
            )
            guard let typeValue = attributes["TYPE"] else {
                continue
            }
            let type: HLSPreloadHintType
            switch typeValue {
            case "PART":
                type = .partialSegment
            case "MAP":
                type = .initializationMap
            case "KEY":
                type = .encryptionKey
            default:
                continue
            }
            guard retainedHintTypes.insert(type).inserted,
                preloadHints.contains(where: { $0.type == type })
            else {
                continue
            }
            if type == .initializationMap {
                anticipatedInitializationMap = try parsePreloadResource(
                    attributes,
                    relativeTo: sourceURL
                )
            }
            guard type != .encryptionKey else {
                continue
            }
            hintContexts[type] = HLSLowLatencyResourceContext(
                discontinuitySequence: discontinuitySequence,
                initializationMap:
                    type == .partialSegment
                    ? anticipatedInitializationMap ?? initializationMap
                    : initializationMap,
                encryption: encryption
            )
        }

        guard partialContexts.count == partialSegments.count else {
            throw HLSDownloadError.invalidPlaylist
        }
        return ResourceContexts(
            partialSegments: partialContexts,
            preloadHints: hintContexts,
            initializationMaps: initializationMaps
        )
    }

    private static func parseInitializationMap(
        _ line: String,
        previousSegment: HLSLowLatencyResourceIdentity?,
        relativeTo sourceURL: URL
    ) throws -> HLSLowLatencyResourceIdentity {
        let attributes = try HLSAttributeListParser.parse(
            String(line.dropFirst("#EXT-X-MAP:".count))
        )
        guard let uri = attributes["URI"],
            let url = URL(string: uri, relativeTo: sourceURL)?.absoluteURL
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let byteRange: HLSByteRange?
        if let value = attributes["BYTERANGE"] {
            byteRange = try resolveByteRange(
                value,
                previous: previousSegment?.url == url
                    ? previousSegment?.byteRange
                    : nil
            )
        } else {
            byteRange = nil
        }
        return HLSLowLatencyResourceIdentity(
            url: url,
            byteRange: byteRange,
            openEndedByteRangeStart: nil
        )
    }

    private static func parsePreloadResource(
        _ attributes: HLSAttributeList,
        relativeTo sourceURL: URL
    ) throws -> HLSLowLatencyResourceIdentity {
        guard let uri = attributes["URI"],
            let url = URL(string: uri, relativeTo: sourceURL)?.absoluteURL
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let start =
            try optionalNonnegativeInteger(
                attributes,
                name: "BYTERANGE-START"
            ) ?? 0
        let length = try optionalPositiveInteger(
            attributes,
            name: "BYTERANGE-LENGTH"
        )
        return HLSLowLatencyResourceIdentity(
            url: url,
            byteRange: length.flatMap {
                HLSByteRange(offset: start, length: $0)
            },
            openEndedByteRangeStart:
                length == nil && attributes["BYTERANGE-START"] != nil
                ? start
                : nil
        )
    }

    private static func parseEncryptionContext(
        _ line: String,
        relativeTo sourceURL: URL
    ) throws -> HLSLowLatencyEncryptionIdentity? {
        let attributes = try HLSAttributeListParser.parse(
            String(line.dropFirst("#EXT-X-KEY:".count))
        )
        guard let method = attributes["METHOD"] else {
            throw HLSDownloadError.invalidPlaylist
        }
        guard method != "NONE" else {
            return nil
        }
        let keyURL = attributes["URI"].flatMap {
            URL(string: $0, relativeTo: sourceURL)?.absoluteURL
        }
        return HLSLowLatencyEncryptionIdentity(
            method: method,
            keyURL: keyURL,
            keyFormat: attributes["KEYFORMAT"] ?? "identity",
            keyFormatVersions:
                try HLSKeyAttributeParser
                .parseKeyFormatVersions(
                    attributes["KEYFORMATVERSIONS"]
                ),
            initializationVector: try attributes["IV"].map(
                HLSKeyAttributeParser.parseInitializationVector
            )
        )
    }
}
