import Foundation

enum HLSPlaylistDocumentParser {
    static func parse(
        _ playlist: String,
        relativeTo sourceURL: URL,
        expansion: HLSVariableExpansion
    ) throws -> HLSPlaylist {
        let lines =
            playlist
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard
            lines.first(where: { !$0.isEmpty }) == "#EXTM3U"
        else {
            throw HLSDownloadError.invalidPlaylist
        }

        let protocolVersion = try HLSPlaylistAttributeDecoder.parseProtocolVersion(lines)
        if expansion.containsDefinitions,
            (protocolVersion ?? 1) < 8
        {
            throw HLSDownloadError.invalidPlaylist
        }
        if expansion.containsQueryParameters,
            (protocolVersion ?? 1) < 11
        {
            throw HLSDownloadError.invalidPlaylist
        }
        let independentSegmentTags = lines.filter {
            $0 == "#EXT-X-INDEPENDENT-SEGMENTS"
        }
        guard independentSegmentTags.count <= 1 else {
            throw HLSDownloadError.invalidPlaylist
        }
        let hasIndependentSegments = !independentSegmentTags.isEmpty
        let renditions = try HLSMultivariantPlaylistParser.parseRenditions(
            lines,
            relativeTo: sourceURL
        )
        if renditions.contains(where: {
            $0.kind != .closedCaptions && $0.instreamID != nil
        }), (protocolVersion ?? 1) < 13 {
            throw HLSDownloadError.invalidPlaylist
        }
        if renditions.contains(where: {
            $0.kind == .closedCaptions
                && $0.instreamID?.hasPrefix("SERVICE") == true
        }), (protocolVersion ?? 1) < 7 {
            throw HLSDownloadError.invalidPlaylist
        }

        let hasRegularStreamInformation = lines.contains {
            $0.hasPrefix("#EXT-X-STREAM-INF:")
        }
        let hasIFrameStreamInformation = lines.contains {
            $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
        }
        let hasStreamInformation =
            hasRegularStreamInformation || hasIFrameStreamInformation
        if try containsRequiredVideoLayout(lines),
            (protocolVersion ?? 1) < 12
        {
            throw HLSDownloadError.invalidPlaylist
        }
        let hasMediaSegmentInformation = lines.contains {
            $0.hasPrefix("#EXTINF:")
                || $0.hasPrefix("#EXT-X-BYTERANGE:")
                || $0.hasPrefix("#EXT-X-BITRATE:")
                || $0.hasPrefix("#EXT-X-DATERANGE:")
                || $0.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:")
                || $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:")
                || $0.hasPrefix("#EXT-X-PLAYLIST-TYPE:")
                || $0.hasPrefix("#EXT-X-TARGETDURATION:")
                || $0.hasPrefix("#EXT-X-KEY:")
                || $0.hasPrefix("#EXT-X-MAP:")
                || $0.hasPrefix("#EXT-X-PART:")
                || $0.hasPrefix("#EXT-X-PART-INF:")
                || $0.hasPrefix("#EXT-X-PRELOAD-HINT:")
                || $0.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
                || $0.hasPrefix("#EXT-X-RENDITION-REPORT:")
                || $0.hasPrefix("#EXT-X-SERVER-CONTROL:")
                || $0.hasPrefix("#EXT-X-SKIP:")
                || $0 == "#EXT-X-DISCONTINUITY"
                || $0 == "#EXT-X-GAP"
                || $0 == "#EXT-X-I-FRAMES-ONLY"
                || $0 == "#EXT-X-ENDLIST"
        }
        if hasStreamInformation, hasMediaSegmentInformation {
            throw HLSDownloadError.invalidPlaylist
        }
        if !hasStreamInformation, !renditions.isEmpty {
            throw HLSDownloadError.invalidPlaylist
        }

        let variants = try HLSMultivariantPlaylistParser.parseVariants(
            lines,
            renditions: renditions,
            relativeTo: sourceURL
        )

        let iFrameVariants = try HLSMultivariantPlaylistParser.parseIFrameVariants(
            lines,
            renditions: renditions,
            relativeTo: sourceURL
        )

        if hasStreamInformation, variants.isEmpty {
            throw HLSDownloadError.invalidPlaylist
        }
        if renditions.contains(where: { $0.kind == .closedCaptions }),
            variants.contains(where: { $0.closedCaptions == nil })
        {
            throw HLSDownloadError.invalidPlaylist
        }

        let kind: HLSPlaylist.Kind =
            hasStreamInformation ? .multivariant : .media
        let sessionMetadata = try HLSSessionMetadataParser.parse(
            lines,
            kind: kind,
            protocolVersion: protocolVersion,
            relativeTo: sourceURL
        )
        let lowLatency = try HLSLowLatencyParser.parse(
            lines,
            kind: kind,
            protocolVersion: protocolVersion,
            relativeTo: sourceURL
        )
        let timeline = try HLSTimelineParser.parse(
            lines,
            kind: kind,
            relativeTo: sourceURL
        )
        let media =
            hasStreamInformation
            ? nil
            : try HLSMediaPlaylistParser.parse(
                lines,
                relativeTo: sourceURL,
                additionalUnsupportedFeatures:
                    timeline.unsupportedMediaFeatures
                    + lowLatency.unsupportedMediaFeatures
            )
        let contentSteering = try HLSPlaylistAttributeDecoder.parseContentSteering(
            lines,
            variants: variants,
            relativeTo: sourceURL
        )
        if contentSteering != nil, !hasStreamInformation {
            throw HLSDownloadError.invalidPlaylist
        }
        let mediaContainer = media.map(HLSMediaPlaylistParser.mediaContainer(for:))
        let separateAudioGroupIDs = Set(
            Dictionary(grouping: renditions.filter { $0.kind == .audio }) {
                $0.groupID
            }.compactMap { groupID, groupRenditions in
                groupRenditions.allSatisfy { $0.url != nil } ? groupID : nil
            }
        )

        if expansion.containsImports, kind != .media {
            throw HLSDownloadError.invalidPlaylist
        }
        return HLSPlaylist(
            sourceURL: sourceURL,
            kind: kind,
            variants: variants,
            iFrameVariants: iFrameVariants,
            renditions: renditions,
            protocolVersion: protocolVersion,
            hasIndependentSegments: hasIndependentSegments,
            contentSteering: contentSteering,
            sessionData: sessionMetadata.data,
            sessionKeys: sessionMetadata.keys,
            preferredStartPosition: timeline.preferredStartPosition,
            programDateTimes: timeline.programDateTimes,
            dateRanges: timeline.dateRanges,
            lowLatency: lowLatency.metadata,
            mediaContainer: mediaContainer,
            targetDuration: media?.targetDuration,
            mediaSequence: media?.mediaSequence,
            discontinuitySequence: media?.discontinuitySequence,
            mediaPlaylistType: media?.playlistType,
            segmentBitrates: media?.segmentBitrates ?? [],
            media: media,
            separateAudioGroupIDs: separateAudioGroupIDs
        )
    }

    private static func containsRequiredVideoLayout(_ lines: [String]) throws -> Bool {
        try lines.contains { line in
            let attributeList: Substring
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                attributeList = line.dropFirst("#EXT-X-STREAM-INF:".count)
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                attributeList = line.dropFirst("#EXT-X-I-FRAME-STREAM-INF:".count)
            } else {
                return false
            }

            return try HLSAttributeListParser.parse(String(attributeList))[
                "REQ-VIDEO-LAYOUT"
            ] != nil
        }
    }

}
