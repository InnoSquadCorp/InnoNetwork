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

}
