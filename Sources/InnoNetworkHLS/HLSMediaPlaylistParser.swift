import Foundation

enum HLSMediaPlaylistParser {
    static func parse(
        _ lines: [String],
        relativeTo sourceURL: URL,
        additionalUnsupportedFeatures: [HLSUnsupportedMediaFeature] = []
    ) throws -> HLSMediaPlaylist {
        let metadata = try HLSMediaPlaylistMetadataParser.parse(lines)
        var resources: [HLSMediaResource] = []
        var currentInitializationResource: HLSMediaResource?
        var needsInitializationResource = false
        var encryptionMethod: String?
        var currentAES128Key: HLSAES128KeyDeclaration?
        var segmentIndex: Int64 = 0
        var expectsSegmentURI = false
        var pendingSegmentByteRange: HLSByteRangeSpecifier?
        var previousSegmentResource: HLSMediaResource?
        var initializationSectionCount = 0
        var unsupportedFeatures = additionalUnsupportedFeatures
        var currentSegmentBitrate: Int?
        var segmentBitrates: [HLSSegmentBitrate] = []
        var pendingSegmentDuration: TimeInterval?
        var pendingDiscontinuity = false
        var pendingDiscontinuityHasPartialSegment = false
        var pendingGap = false

        func recordUnsupportedFeature(
            _ feature: HLSUnsupportedMediaFeature
        ) {
            guard !unsupportedFeatures.contains(feature) else {
                return
            }
            unsupportedFeatures.append(feature)
        }

        for line in lines {
            if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = try HLSAttributeListParser.parse(
                    String(line.dropFirst("#EXT-X-MAP:".count))
                )
                try HLSPlaylistAttributeDecoder.requireQuotedAttributes(
                    ["BYTERANGE", "URI"],
                    in: attributes
                )
                guard let uri = attributes["URI"], !uri.isEmpty,
                    let initializationURL = URL(
                        string: uri,
                        relativeTo: sourceURL
                    )?.absoluteURL
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                let initializationByteRange: HLSByteRange?
                if let value = attributes["BYTERANGE"] {
                    let specification = try parseByteRangeSpecifier(value)
                    initializationByteRange = try resolveByteRange(
                        specification,
                        resourceURL: initializationURL,
                        previousResource: previousSegmentResource
                    )
                } else {
                    initializationByteRange = nil
                }
                initializationSectionCount += 1
                if initializationSectionCount > 1 {
                    recordUnsupportedFeature(
                        .multipleInitializationSections
                    )
                }
                let encryption: HLSAES128Encryption?
                if let currentAES128Key {
                    guard
                        let initializationVector =
                            currentAES128Key.explicitInitializationVector
                    else {
                        throw HLSDownloadError.invalidPlaylist
                    }
                    encryption = HLSAES128Encryption(
                        keyURL: currentAES128Key.keyURL,
                        initializationVector: initializationVector
                    )
                } else {
                    encryption = nil
                }
                currentInitializationResource = .initialization(
                    initializationURL,
                    byteRange: initializationByteRange,
                    encryption: encryption
                )
                needsInitializationResource = true
            } else if line == "#EXT-X-DISCONTINUITY" {
                recordUnsupportedFeature(.discontinuity)
                pendingDiscontinuity = true
                pendingDiscontinuityHasPartialSegment = false
            } else if line.hasPrefix("#EXT-X-PART:") {
                if pendingDiscontinuity {
                    pendingDiscontinuityHasPartialSegment = true
                }
            } else if line == "#EXT-X-GAP" {
                recordUnsupportedFeature(.gap)
                pendingGap = true
            } else if line == "#EXT-X-I-FRAMES-ONLY" {
                recordUnsupportedFeature(.iFramesOnly)
            } else if line.hasPrefix("#EXT-X-BITRATE:") {
                guard
                    let value = Int(
                        line.dropFirst("#EXT-X-BITRATE:".count)
                    ),
                    value >= 0
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                currentSegmentBitrate = value
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = try HLSAttributeListParser.parse(
                    String(line.dropFirst("#EXT-X-KEY:".count))
                )
                try HLSPlaylistAttributeDecoder.requireQuotedAttributes(
                    ["KEYFORMAT", "KEYFORMATVERSIONS", "URI"],
                    in: attributes
                )
                try HLSPlaylistAttributeDecoder.requireUnquotedAttributes(
                    ["IV", "METHOD"],
                    in: attributes
                )
                guard
                    let method = attributes["METHOD"],
                    !method.isEmpty
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                let hasValidKeyFormat =
                    attributes["KEYFORMAT"].map {
                        !$0.isEmpty
                    } ?? true
                switch method {
                case "NONE":
                    guard attributes["URI"] == nil,
                        attributes["IV"] == nil,
                        attributes["KEYFORMAT"] == nil,
                        attributes["KEYFORMATVERSIONS"] == nil
                    else {
                        throw HLSDownloadError.invalidPlaylist
                    }
                    currentAES128Key = nil
                case "AES-128":
                    guard
                        let uri = attributes["URI"],
                        !uri.isEmpty,
                        let keyURL = URL(
                            string: uri,
                            relativeTo: sourceURL
                        )?.absoluteURL,
                        hasValidKeyFormat,
                        (attributes["KEYFORMAT"]?.lowercased()
                            ?? "identity") == "identity",
                        try HLSKeyAttributeParser
                            .parseKeyFormatVersions(
                                attributes["KEYFORMATVERSIONS"]
                            ) == [1]
                    else {
                        throw HLSDownloadError.invalidPlaylist
                    }
                    let explicitInitializationVector =
                        try attributes["IV"].map(
                            HLSKeyAttributeParser
                                .parseInitializationVector
                        )
                    currentAES128Key = HLSAES128KeyDeclaration(
                        keyURL: keyURL,
                        explicitInitializationVector:
                            explicitInitializationVector
                    )
                    if encryptionMethod == nil {
                        encryptionMethod = method
                    }
                default:
                    guard
                        let uri = attributes["URI"],
                        !uri.isEmpty,
                        URL(
                            string: uri,
                            relativeTo: sourceURL
                        )?.absoluteURL != nil,
                        hasValidKeyFormat
                    else {
                        throw HLSDownloadError.invalidPlaylist
                    }
                    _ =
                        try HLSKeyAttributeParser
                        .parseKeyFormatVersions(
                            attributes["KEYFORMATVERSIONS"]
                        )
                    let initializationVector =
                        try attributes["IV"].map(
                            HLSKeyAttributeParser
                                .parseInitializationVector
                        )
                    if initializationVector != nil,
                        method == "AES-256-GCM"
                            || method == "SAMPLE-AES-CTR"
                    {
                        throw HLSDownloadError.invalidPlaylist
                    }
                    currentAES128Key = nil
                    encryptionMethod = method
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                guard pendingSegmentByteRange == nil else {
                    throw HLSDownloadError.invalidPlaylist
                }
                pendingSegmentByteRange = try parseByteRangeSpecifier(
                    String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                )
            } else if line.hasPrefix("#EXTINF:") {
                guard !expectsSegmentURI else {
                    throw HLSDownloadError.invalidPlaylist
                }
                let value = line.dropFirst("#EXTINF:".count)
                    .split(
                        separator: ",",
                        maxSplits: 1,
                        omittingEmptySubsequences: false
                    )[0]
                guard
                    let duration = TimeInterval(value),
                    duration.isFinite,
                    duration > 0
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                pendingSegmentDuration = duration
                expectsSegmentURI = true
            } else if !line.isEmpty, !line.hasPrefix("#"),
                expectsSegmentURI,
                let segmentURL = URL(
                    string: line,
                    relativeTo: sourceURL
                )?.absoluteURL
            {
                let segmentByteRange: HLSByteRange?
                if let pendingSegmentByteRange {
                    segmentByteRange = try resolveByteRange(
                        pendingSegmentByteRange,
                        resourceURL: segmentURL,
                        previousResource: previousSegmentResource
                    )
                } else {
                    segmentByteRange = nil
                }
                if Self.isFragmentedMP4Resource(segmentURL),
                    currentInitializationResource == nil
                {
                    throw HLSDownloadError.invalidPlaylist
                }
                if needsInitializationResource,
                    let currentInitializationResource
                {
                    resources.append(currentInitializationResource)
                    needsInitializationResource = false
                }
                let encryption: HLSAES128Encryption?
                if let currentAES128Key {
                    let initializationVector: Data
                    if let explicit =
                        currentAES128Key.explicitInitializationVector
                    {
                        initializationVector = explicit
                    } else {
                        let (sequence, overflow) =
                            metadata.mediaSequence
                            .addingReportingOverflow(
                                segmentIndex
                            )
                        guard !overflow else {
                            throw HLSDownloadError.invalidPlaylist
                        }
                        initializationVector =
                            implicitInitializationVector(
                                mediaSequence: sequence
                            )
                    }
                    encryption = HLSAES128Encryption(
                        keyURL: currentAES128Key.keyURL,
                        initializationVector: initializationVector
                    )
                } else {
                    encryption = nil
                }
                let segmentResource = HLSMediaResource.segment(
                    segmentURL,
                    byteRange: segmentByteRange,
                    encryption: encryption,
                    duration: pendingSegmentDuration,
                    beginsDiscontinuity: pendingDiscontinuity,
                    isGap: pendingGap
                )
                resources.append(segmentResource)
                if segmentByteRange == nil,
                    let currentSegmentBitrate,
                    let publicSegmentIndex = Int(exactly: segmentIndex)
                {
                    segmentBitrates.append(
                        HLSSegmentBitrate(
                            segmentIndex: publicSegmentIndex,
                            kilobitsPerSecond: currentSegmentBitrate
                        )
                    )
                }
                previousSegmentResource = segmentResource
                let (nextSegmentIndex, overflow) =
                    segmentIndex.addingReportingOverflow(1)
                guard !overflow else {
                    throw HLSDownloadError.invalidPlaylist
                }
                segmentIndex = nextSegmentIndex
                pendingSegmentByteRange = nil
                pendingSegmentDuration = nil
                pendingDiscontinuity = false
                pendingDiscontinuityHasPartialSegment = false
                pendingGap = false
                expectsSegmentURI = false
            } else if !line.isEmpty, !line.hasPrefix("#") {
                throw HLSDownloadError.invalidPlaylist
            }
        }
        guard
            !expectsSegmentURI,
            pendingSegmentByteRange == nil,
            pendingSegmentDuration == nil,
            !pendingGap
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        if pendingDiscontinuity,
            !pendingDiscontinuityHasPartialSegment
        {
            throw HLSDownloadError.invalidPlaylist
        }

        return HLSMediaPlaylist(
            resources: resources,
            hasEndList: metadata.hasEndList,
            targetDuration: metadata.targetDuration,
            mediaSequence: metadata.mediaSequence,
            discontinuitySequence: metadata.discontinuitySequence,
            playlistType: metadata.playlistType,
            segmentBitrates: segmentBitrates,
            encryptionMethod: encryptionMethod,
            unsupportedFeatures: unsupportedFeatures
        )
    }

    static func mediaContainer(
        for media: HLSMediaPlaylist,
        lowLatency: HLSLowLatencyMetadata? = nil
    ) -> HLSMediaContainer {
        if media.resources.contains(where: { resource in
            switch resource.kind {
            case .initialization:
                return true
            case .segment:
                return isFragmentedMP4Resource(resource.url)
            }
        })
            || lowLatency?.preloadHints.contains(where: {
                $0.type == .initializationMap
            }) == true
            || lowLatency?.initializationMaps.isEmpty == false
        {
            return .fragmentedMP4
        }
        return .mpegTransportStream
    }

    private static func isFragmentedMP4Resource(_ url: URL) -> Bool {
        ["m4s", "mp4", "cmfv", "cmfa"].contains(
            url.pathExtension.lowercased()
        )
    }

    private static func parseByteRangeSpecifier(
        _ value: String
    ) throws -> HLSByteRangeSpecifier {
        let fields = value.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard fields.count == 1 || fields.count == 2,
            let length = Int64(fields[0]),
            length > 0
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let offset: Int64?
        if fields.count == 2 {
            guard let parsedOffset = Int64(fields[1]), parsedOffset >= 0 else {
                throw HLSDownloadError.invalidPlaylist
            }
            offset = parsedOffset
        } else {
            offset = nil
        }
        return HLSByteRangeSpecifier(length: length, offset: offset)
    }

    private static func implicitInitializationVector(
        mediaSequence: Int64
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        var value = UInt64(mediaSequence)
        for index in stride(from: 15, through: 8, by: -1) {
            bytes[index] = UInt8(value & 0xff)
            value >>= 8
        }
        return Data(bytes)
    }

    private static func resolveByteRange(
        _ specification: HLSByteRangeSpecifier,
        resourceURL: URL,
        previousResource: HLSMediaResource?
    ) throws -> HLSByteRange {
        let offset: Int64
        if let explicitOffset = specification.offset {
            offset = explicitOffset
        } else {
            guard let previousResource,
                previousResource.url == resourceURL,
                let previousRange = previousResource.byteRange
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            offset = previousRange.endOffset
        }
        guard
            let range = HLSByteRange(
                offset: offset,
                length: specification.length
            )
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return range
    }

    private struct HLSByteRangeSpecifier {
        let length: Int64
        let offset: Int64?
    }

    private struct HLSAES128KeyDeclaration {
        let keyURL: URL
        let explicitInitializationVector: Data?
    }
}
