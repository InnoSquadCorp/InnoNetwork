import Foundation

extension HLSLowLatencyParser {
    static func parsePartialTargetDuration(
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

    static func parseServerControl(
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

    static func parsePartialSegments(
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
                    byteRange: byteRange,
                    resourceContext: nil
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

}
