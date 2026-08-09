import Foundation

enum HLSOfflineMediaPlaylistWriter {
    static func validate(contents: String) throws {
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !line.hasPrefix("#EXT-X-DEFINE:") else {
                continue
            }
            guard line.hasPrefix("#EXT-X-"), line.contains("URI=") else {
                continue
            }
            guard
                line.hasPrefix("#EXT-X-MAP:")
                    || line.hasPrefix("#EXT-X-KEY:")
            else {
                throw HLSDownloadError.invalidPlaylist
            }
        }
    }

    static func resourceFileNames(
        for resources: [HLSMediaResource]
    ) -> [String] {
        resources.enumerated().map { index, resource in
            let sourceExtension =
                resource.url.pathExtension.lowercased()
            let safeExtension =
                sourceExtension.count <= 8
                    && !sourceExtension.isEmpty
                    && sourceExtension.allSatisfy {
                        $0.isLetter || $0.isNumber
                    }
                ? sourceExtension
                : "bin"
            return String(
                format: "resources/%05d.%@",
                index,
                safeExtension
            )
        }
    }

    static func rewrite(
        contents: String,
        resources: [HLSMediaResource],
        resourceFileNames: [String]
    ) throws -> String {
        guard resources.count == resourceFileNames.count else {
            throw HLSDownloadError.invalidPlaylist
        }

        var output: [String] = []
        var resourceIndex = 0
        var expectsSegmentURI = false

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if line.hasPrefix("#EXT-X-MAP:") {
                guard resourceIndex < resources.count,
                    resources[resourceIndex].kind == .initialization
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                output.append(
                    "#EXT-X-MAP:URI=\""
                        + resourceFileNames[resourceIndex]
                        + "\""
                )
                resourceIndex += 1
            } else if line.hasPrefix("#EXT-X-DEFINE:") {
                // Resource references are already modeled by the parsed
                // playlist. Definitions can contain signed values and must
                // not be persisted in the URL-free package.
                continue
            } else if line.hasPrefix("#EXT-X-KEY:") {
                // Stored resources are plaintext, so source key declarations
                // must not survive in the localized playlist.
                continue
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                // Each byte range becomes its own complete local resource.
                continue
            } else if line.hasPrefix("#EXTINF:") {
                expectsSegmentURI = true
                output.append(line)
            } else if !line.isEmpty, !line.hasPrefix("#"),
                expectsSegmentURI
            {
                guard resourceIndex < resources.count,
                    resources[resourceIndex].kind == .segment
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                output.append(resourceFileNames[resourceIndex])
                resourceIndex += 1
                expectsSegmentURI = false
            } else {
                output.append(line)
            }
        }

        guard !expectsSegmentURI, resourceIndex == resources.count else {
            throw HLSDownloadError.invalidPlaylist
        }
        while output.last?.isEmpty == true {
            output.removeLast()
        }
        let rewritten = output.joined(separator: "\n") + "\n"
        guard !rewritten.contains("{$") else {
            throw HLSDownloadError.invalidPlaylist
        }
        return rewritten
    }
}

enum HLSOfflineMasterPlaylistWriter {
    static func make(
        plan: HLSOfflinePackagePlan
    ) throws -> String {
        let descriptors = plan.tracks.map(\.descriptor)
        let audioTracks = descriptors.filter { $0.kind == .audio }
        let subtitleTracks = descriptors.filter { $0.kind == .subtitles }
        let videoTracks = descriptors.filter { $0.kind == .video }
        let iFrameTracks = descriptors.filter { $0.kind == .iFrames }
        let iFrameVideoTracks = descriptors.filter {
            $0.kind == .iFrameVideo
        }
        guard iFrameTracks.count <= 1,
            (plan.selectedIFrameVariant == nil) == iFrameTracks.isEmpty,
            plan.selectedIFrameVariant != nil || iFrameVideoTracks.isEmpty
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let protocolVersion: Int
        if descriptors.contains(where: {
            $0.instreamID != nil
        }) {
            protocolVersion = 13
        } else {
            protocolVersion = 7
        }
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:\(protocolVersion)",
        ]
        lines.append(
            contentsOf: try videoTracks.map {
                try mediaLine(
                    track: $0,
                    type: "VIDEO",
                    groupID: "offline-video"
                )
            }
        )
        lines.append(
            contentsOf: try iFrameVideoTracks.map {
                try mediaLine(
                    track: $0,
                    type: "VIDEO",
                    groupID: "offline-iframe-video"
                )
            }
        )
        lines.append(
            contentsOf: try audioTracks.map {
                try mediaLine(
                    track: $0,
                    type: "AUDIO",
                    groupID: "offline-audio"
                )
            }
        )
        lines.append(
            contentsOf: try subtitleTracks.map {
                try mediaLine(
                    track: $0,
                    type: "SUBTITLES",
                    groupID: "offline-subtitles"
                )
            }
        )

        var streamAttributes = try variantAttributes(
            plan.selectedVariant,
            fallbackBandwidth: 1,
            includesFrameRate: true
        )
        if !videoTracks.isEmpty {
            streamAttributes.append("VIDEO=\"offline-video\"")
        }
        if !audioTracks.isEmpty {
            streamAttributes.append("AUDIO=\"offline-audio\"")
        }
        if !subtitleTracks.isEmpty {
            streamAttributes.append(
                "SUBTITLES=\"offline-subtitles\""
            )
        }
        lines.append(
            "#EXT-X-STREAM-INF:"
                + streamAttributes.joined(separator: ",")
        )
        lines.append("media/primary/index.m3u8")
        if let iFrameVariant = plan.selectedIFrameVariant,
            let iFrameTrack = iFrameTracks.first
        {
            var attributes = try variantAttributes(
                iFrameVariant,
                fallbackBandwidth: 1,
                includesFrameRate: false
            )
            if !iFrameVideoTracks.isEmpty {
                attributes.append("VIDEO=\"offline-iframe-video\"")
            }
            attributes.append(
                "URI=\"\(iFrameTrack.relativePlaylistPath)\""
            )
            lines.append(
                "#EXT-X-I-FRAME-STREAM-INF:"
                    + attributes.joined(separator: ",")
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func variantAttributes(
        _ variant: HLSVariant?,
        fallbackBandwidth: Int,
        includesFrameRate: Bool
    ) throws -> [String] {
        var attributes = [
            "BANDWIDTH=\(max(1, variant?.bandwidth ?? fallbackBandwidth))"
        ]
        if let averageBandwidth = variant?.averageBandwidth,
            averageBandwidth > 0
        {
            attributes.append("AVERAGE-BANDWIDTH=\(averageBandwidth)")
        }
        if let score = variant?.score {
            attributes.append(
                "SCORE=\(try decimalFloatingPoint(score))"
            )
        }
        if let width = variant?.width, let height = variant?.height {
            attributes.append("RESOLUTION=\(width)x\(height)")
        }
        if let codecs = variant?.codecs, !codecs.isEmpty {
            try codecs.forEach(validateQuotedAttribute)
            attributes.append(
                "CODECS=\"\(codecs.joined(separator: ","))\""
            )
        }
        if let codecs = variant?.supplementalCodecs, !codecs.isEmpty {
            try codecs.forEach(validateQuotedAttribute)
            attributes.append(
                "SUPPLEMENTAL-CODECS=\""
                    + codecs.joined(separator: ",") + "\""
            )
        }
        if includesFrameRate, let frameRate = variant?.frameRate {
            attributes.append("FRAME-RATE=\(frameRate)")
        }
        if let videoRange = variant?.videoRange {
            attributes.append("VIDEO-RANGE=\(videoRange)")
        }
        if let hdcpLevel = variant?.hdcpLevel {
            attributes.append("HDCP-LEVEL=\(hdcpLevel.rawValue)")
        }
        if let configurations =
            variant?.allowedContentProtectionConfigurations,
            !configurations.isEmpty
        {
            let value =
                configurations
                .map(\.playlistValue)
                .joined(separator: ",")
            try validateQuotedAttribute(value)
            attributes.append("ALLOWED-CPC=\"\(value)\"")
        }
        if let layouts = variant?.requiredVideoLayouts,
            !layouts.isEmpty
        {
            let value =
                layouts
                .map(\.playlistValue)
                .joined(separator: ",")
            try validateQuotedAttribute(value)
            attributes.append("REQ-VIDEO-LAYOUT=\"\(value)\"")
        }
        if let stableID = variant?.stableID {
            try validateQuotedAttribute(stableID)
            attributes.append("STABLE-VARIANT-ID=\"\(stableID)\"")
        }
        return attributes
    }

    private static func mediaLine(
        track: HLSOfflinePackageTrack,
        type: String,
        groupID: String
    ) throws -> String {
        let name = track.name ?? type.capitalized
        try validateQuotedAttribute(name)
        var attributes = [
            "TYPE=\(type)",
            "GROUP-ID=\"\(groupID)\"",
            "NAME=\"\(name)\"",
        ]
        if let language = track.language {
            try validateQuotedAttribute(language)
            attributes.append(
                "LANGUAGE=\"\(language)\""
            )
        }
        if let associatedLanguage = track.associatedLanguage {
            try validateQuotedAttribute(associatedLanguage)
            attributes.append(
                "ASSOC-LANGUAGE=\"\(associatedLanguage)\""
            )
        }
        if let stableID = track.stableID {
            try validateQuotedAttribute(stableID)
            attributes.append(
                "STABLE-RENDITION-ID=\"\(stableID)\""
            )
        }
        if let instreamID = track.instreamID {
            try validateQuotedAttribute(instreamID)
            attributes.append(
                "INSTREAM-ID=\"\(instreamID)\""
            )
        }
        attributes.append(
            "DEFAULT=\(track.isDefault ? "YES" : "NO")"
        )
        attributes.append(
            "AUTOSELECT=\(track.isAutoselect ? "YES" : "NO")"
        )
        if type == "SUBTITLES" {
            attributes.append(
                "FORCED=\(track.isForced ? "YES" : "NO")"
            )
        }
        if !track.characteristics.isEmpty {
            try track.characteristics.forEach(validateQuotedAttribute)
            attributes.append(
                "CHARACTERISTICS=\""
                    + track.characteristics.joined(separator: ",")
                    + "\""
            )
        }
        if type == "AUDIO" {
            if let channels = track.channels {
                try validateQuotedAttribute(channels)
                attributes.append("CHANNELS=\"\(channels)\"")
            }
            if let audioBitDepth = track.audioBitDepth {
                attributes.append("BIT-DEPTH=\(audioBitDepth)")
            }
            if let audioSampleRate = track.audioSampleRate {
                attributes.append("SAMPLE-RATE=\(audioSampleRate)")
            }
        }
        attributes.append(
            "URI=\"\(track.relativePlaylistPath)\""
        )
        return "#EXT-X-MEDIA:" + attributes.joined(separator: ",")
    }

    private static func validateQuotedAttribute(
        _ value: String
    ) throws {
        guard
            !value.contains("\""),
            !value.contains("\r"),
            !value.contains("\n")
        else {
            throw HLSDownloadError.invalidPlaylist
        }
    }

    private static func decimalFloatingPoint(
        _ value: Double
    ) throws -> String {
        guard value.isFinite, value > 0 else {
            throw HLSDownloadError.invalidPlaylist
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 1
        formatter.maximumSignificantDigits = 17
        guard
            let text = formatter.string(
                from: NSNumber(value: value)
            ),
            !text.isEmpty
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        return text
    }
}
