import Foundation

struct HLSAuthoringLine: Sendable {
    let number: Int
    let text: String
}

enum HLSAppleAuthoringAnalyzer {
    private static let videoCodecPrefixes = [
        "avc1",
        "avc3",
        "hvc1",
        "hev1",
        "dvh1",
        "dvhe",
        "av01",
    ]

    static func diagnostics(
        for playlist: HLSPlaylist,
        lines: [HLSAuthoringLine]
    ) -> [HLSPlaylistDiagnostic] {
        var diagnostics: [HLSPlaylistDiagnostic] = []
        if playlist.sourceURL.scheme?.lowercased() != "https" {
            diagnostics.append(
                warning(.appleTLSRecommended, lineNumber: nil)
            )
        }
        if !playlist.hasIndependentSegments {
            diagnostics.append(
                warning(
                    .appleIndependentSegmentsMissing,
                    lineNumber: nil
                )
            )
        }
        switch playlist.kind {
        case .media:
            diagnostics.append(
                contentsOf: mediaDiagnostics(
                    playlist: playlist,
                    lines: lines
                )
            )
        case .multivariant:
            diagnostics.append(
                contentsOf: multivariantDiagnostics(
                    playlist: playlist,
                    lines: lines
                )
            )
        }
        return diagnostics
    }

    private static func mediaDiagnostics(
        playlist: HLSPlaylist,
        lines: [HLSAuthoringLine]
    ) -> [HLSPlaylistDiagnostic] {
        var diagnostics: [HLSPlaylistDiagnostic] = []
        if let targetDuration = playlist.targetDuration {
            for line in lines
            where line.text.hasPrefix("#EXTINF:") {
                let value = line.text.dropFirst("#EXTINF:".count)
                    .split(
                        separator: ",",
                        maxSplits: 1,
                        omittingEmptySubsequences: false
                    ).first
                if let value,
                    let duration = Double(value),
                    duration.isFinite,
                    Int(duration.rounded()) > targetDuration
                {
                    diagnostics.append(
                        warning(
                            .appleSegmentExceedsTargetDuration,
                            lineNumber: line.number
                        )
                    )
                }
            }
        } else {
            diagnostics.append(
                warning(.appleTargetDurationMissing, lineNumber: nil)
            )
        }
        if lines.contains(where: {
            $0.text.hasPrefix("#EXT-X-MAP:")
        }), (playlist.protocolVersion ?? 1) < 6 {
            diagnostics.append(
                warning(
                    .appleProtocolVersionTooLow,
                    lineNumber: lines.first(where: {
                        $0.text.hasPrefix("#EXT-X-MAP:")
                    })?.number
                )
            )
        }
        if let lowLatency = playlist.lowLatency,
            !lowLatency.partialSegments.isEmpty,
            playlist.programDateTimes.isEmpty
        {
            diagnostics.append(
                warning(
                    .appleLowLatencyProgramDateTimeMissing,
                    lineNumber: lines.first(where: {
                        $0.text.hasPrefix("#EXT-X-PART:")
                    })?.number
                )
            )
        }
        if let lowLatency = playlist.lowLatency,
            let partialTarget =
                lowLatency.partialSegmentTargetDuration,
            let partialHoldBack =
                lowLatency.serverControl?
                .partialSegmentHoldBack,
            partialHoldBack < 3 * partialTarget
        {
            diagnostics.append(
                warning(
                    .applePartialSegmentHoldBackTooShort,
                    lineNumber: lines.first(where: {
                        $0.text.hasPrefix(
                            "#EXT-X-SERVER-CONTROL:"
                        )
                    })?.number
                )
            )
        }
        return diagnostics
    }

    private static func multivariantDiagnostics(
        playlist: HLSPlaylist,
        lines: [HLSAuthoringLine]
    ) -> [HLSPlaylistDiagnostic] {
        var diagnostics: [HLSPlaylistDiagnostic] = []
        let containsExplicitNonSDRRange = playlist.variants.contains {
            $0.videoRange != nil && $0.videoRange != "SDR"
        }
        let containsScores = playlist.variants.contains {
            $0.score != nil
        }
        let variantLineNumbers = eligibleVariantLineNumbers(lines)
        for (index, variant) in playlist.variants.enumerated() {
            let lineNumber =
                variantLineNumbers.indices.contains(index)
                ? variantLineNumbers[index] : nil
            if variant.codecs.isEmpty {
                diagnostics.append(
                    warning(
                        .appleCodecsMissing,
                        lineNumber: lineNumber
                    )
                )
            }
            if variant.averageBandwidth == nil {
                diagnostics.append(
                    warning(
                        .appleAverageBandwidthMissing,
                        lineNumber: lineNumber
                    )
                )
            }
            if containsVideoCodec(variant.codecs),
                variant.width == nil || variant.height == nil
            {
                diagnostics.append(
                    warning(
                        .appleResolutionMissing,
                        lineNumber: lineNumber
                    )
                )
            }
            if containsVideoCodec(variant.codecs),
                variant.frameRate == nil
            {
                diagnostics.append(
                    warning(
                        .appleFrameRateMissing,
                        lineNumber: lineNumber
                    )
                )
            }
            if containsVideoCodec(variant.codecs),
                containsExplicitNonSDRRange,
                variant.videoRange == nil
            {
                diagnostics.append(
                    warning(
                        .appleVideoRangeMissing,
                        lineNumber: lineNumber
                    )
                )
            }
            if containsScores, variant.score == nil {
                diagnostics.append(
                    warning(
                        .appleScoreIncomplete,
                        lineNumber: lineNumber
                    )
                )
            }
            if index > 0,
                let previousBandwidth =
                    playlist.variants[index - 1].bandwidth,
                let bandwidth = variant.bandwidth,
                bandwidth < previousBandwidth
            {
                diagnostics.append(
                    warning(
                        .appleVariantOrder,
                        lineNumber: lineNumber
                    )
                )
            }
        }
        diagnostics.append(
            contentsOf: steeringDiagnostics(
                playlist: playlist,
                lines: lines,
                variantLineNumbers: variantLineNumbers
            )
        )
        for rendition in playlist.renditions
        where
            (rendition.kind == .subtitles
            || rendition.kind == .closedCaptions)
            && rendition.language == nil
        {
            diagnostics.append(
                warning(
                    .appleCaptionLanguageMissing,
                    lineNumber: renditionLineNumber(
                        rendition,
                        lines: lines
                    )
                )
            )
        }
        return diagnostics
    }

    private static func steeringDiagnostics(
        playlist: HLSPlaylist,
        lines: [HLSAuthoringLine],
        variantLineNumbers: [Int]
    ) -> [HLSPlaylistDiagnostic] {
        guard playlist.contentSteering != nil else {
            return []
        }
        var diagnostics: [HLSPlaylistDiagnostic] = []
        let steeringLine = lines.first {
            $0.text.hasPrefix("#EXT-X-CONTENT-STEERING:")
        }?.number
        if playlist.contentSteering?.initialPathwayID == nil {
            diagnostics.append(
                warning(
                    .appleContentSteeringPathwayMissing,
                    lineNumber: steeringLine
                )
            )
        }
        for (index, variant) in playlist.variants.enumerated()
        where variant.stableID == nil {
            diagnostics.append(
                warning(
                    .appleStableVariantIDMissing,
                    lineNumber:
                        variantLineNumbers.indices.contains(index)
                        ? variantLineNumbers[index] : nil
                )
            )
        }
        for rendition in playlist.renditions
        where rendition.url != nil && rendition.stableID == nil {
            diagnostics.append(
                warning(
                    .appleStableRenditionIDMissing,
                    lineNumber: renditionLineNumber(
                        rendition,
                        lines: lines
                    )
                )
            )
        }
        return diagnostics
    }

    private static func containsVideoCodec(
        _ codecs: [String]
    ) -> Bool {
        codecs.contains { codec in
            let normalized = codec.lowercased()
            return videoCodecPrefixes.contains {
                normalized.hasPrefix($0)
            }
        }
    }

    private static func eligibleVariantLineNumbers(
        _ lines: [HLSAuthoringLine]
    ) -> [Int] {
        lines.compactMap { line in
            guard
                line.text.hasPrefix("#EXT-X-STREAM-INF:"),
                let attributes = try? HLSAttributeListParser.parse(
                    String(
                        line.text.dropFirst(
                            "#EXT-X-STREAM-INF:".count
                        )
                    )
                ),
                let videoRange =
                    try? HLSPlaylistAttributeDecoder
                    .parseVideoRange(attributes["VIDEO-RANGE"]),
                let videoLayouts =
                    try? HLSPlaylistAttributeDecoder
                    .parseRequiredVideoLayouts(
                        attributes["REQ-VIDEO-LAYOUT"]
                    ),
                case .supported = videoRange,
                case .supported = videoLayouts
            else {
                return nil
            }
            return line.number
        }
    }

    private static func renditionLineNumber(
        _ rendition: HLSRendition,
        lines: [HLSAuthoringLine]
    ) -> Int? {
        for line in lines
        where line.text.hasPrefix("#EXT-X-MEDIA:") {
            guard
                let attributes = try? HLSAttributeListParser.parse(
                    String(
                        line.text.dropFirst("#EXT-X-MEDIA:".count)
                    )
                ),
                attributes["GROUP-ID"] == rendition.groupID,
                attributes["NAME"] == rendition.name
            else {
                continue
            }
            return line.number
        }
        return nil
    }

    private static func warning(
        _ code: HLSPlaylistDiagnostic.Code,
        lineNumber: Int?
    ) -> HLSPlaylistDiagnostic {
        HLSPlaylistDiagnostic(
            severity: .warning,
            scope: .appleAuthoring,
            code: code,
            lineNumber: lineNumber
        )
    }
}
