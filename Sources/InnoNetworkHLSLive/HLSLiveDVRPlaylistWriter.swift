import Foundation
import InnoNetworkHLS

struct HLSLiveDVRStoredSegment: Equatable, Sendable {
    let sequenceNumber: Int64
    let duration: TimeInterval
    let beginsDiscontinuity: Bool
    let programDateTime: Date?
    let initializationSourceIdentity: String?
    let initializationFileName: String?
    let fileName: String
    let byteCount: Int64
    let contentSHA256: String

    init(
        sequenceNumber: Int64,
        duration: TimeInterval,
        beginsDiscontinuity: Bool,
        programDateTime: Date?,
        initializationSourceIdentity: String? = nil,
        initializationFileName: String? = nil,
        fileName: String,
        byteCount: Int64,
        contentSHA256: String
    ) {
        self.sequenceNumber = sequenceNumber
        self.duration = duration
        self.beginsDiscontinuity = beginsDiscontinuity
        self.programDateTime = programDateTime
        self.initializationSourceIdentity =
            initializationSourceIdentity
        self.initializationFileName = initializationFileName
        self.fileName = fileName
        self.byteCount = byteCount
        self.contentSHA256 = contentSHA256
    }
}

enum HLSLiveDVRPlaylistWriter {
    static func make(
        container: HLSMediaContainer,
        segments: [HLSLiveDVRStoredSegment],
        dateRanges: [HLSDateRange] = []
    ) throws -> String {
        guard
            let first = segments.first,
            segments.allSatisfy({
                $0.duration.isFinite && $0.duration > 0
            })
        else {
            throw HLSLiveDVRError.noSegmentsRecorded
        }
        let maximumDuration =
            segments.map(\.duration).max() ?? 1
        guard
            maximumDuration <= TimeInterval(Int.max)
        else {
            throw HLSLiveDVRError.storageFailed
        }

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(1, Int(ceil(maximumDuration))))",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:\(first.sequenceNumber)",
        ]
        switch container {
        case .mpegTransportStream:
            guard
                segments.allSatisfy({
                    $0.initializationSourceIdentity == nil
                        && $0.initializationFileName == nil
                })
            else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .changingInitializationSegment
                )
            }
        case .fragmentedMP4:
            guard
                segments.allSatisfy({
                    $0.initializationSourceIdentity != nil
                        && $0.initializationFileName != nil
                })
            else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .missingInitializationSegment
                )
            }
        }

        var activeInitializationFileName: String?
        for (index, segment) in segments.enumerated() {
            if segment.beginsDiscontinuity {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            if let initializationFileName =
                segment.initializationFileName,
                initializationFileName
                    != activeInitializationFileName
            {
                lines.append(
                    "#EXT-X-MAP:URI=\"\(initializationFileName)\""
                )
                activeInitializationFileName = initializationFileName
            }
            if let programDateTime = segment.programDateTime {
                lines.append(
                    "#EXT-X-PROGRAM-DATE-TIME:"
                        + dateString(programDateTime)
                )
            }
            if index == 0 {
                lines.append(
                    contentsOf: try dateRanges.map(dateRangeLine)
                )
            }
            lines.append("#EXTINF:\(durationString(segment.duration)),")
            lines.append(segment.fileName)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    static func makeMaster(
        variant: HLSVariant?,
        renditions: [HLSLiveDVRSelectedRendition],
        inBandClosedCaptions: [HLSRendition]
    ) throws -> String {
        let protocolVersion = inBandClosedCaptions.isEmpty ? 7 : 13
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:\(protocolVersion)",
        ]
        for kind in [
            HLSRenditionKind.video,
            .audio,
            .subtitles,
        ] {
            lines.append(
                contentsOf:
                    try renditions
                    .filter { $0.rendition.kind == kind }
                    .map(mediaLine)
            )
        }
        lines.append(
            contentsOf: try inBandClosedCaptions.map {
                try mediaLine(
                    rendition: $0,
                    relativePlaylistPath: nil
                )
            }
        )

        var attributes =
            try HLSPackageMasterPlaylistWriter
            .variantAttributes(
                variant,
                fallbackBandwidth: 1,
                includesFrameRate: true,
                includesCodecs: false,
                includesContentProtectionAttributes: false
            )
        if renditions.contains(where: { $0.rendition.kind == .video }) {
            attributes.append("VIDEO=\"live-dvr-video\"")
        }
        if renditions.contains(where: { $0.rendition.kind == .audio }) {
            attributes.append("AUDIO=\"live-dvr-audio\"")
        }
        if renditions.contains(where: { $0.rendition.kind == .subtitles }) {
            attributes.append("SUBTITLES=\"live-dvr-subtitles\"")
        }
        if !inBandClosedCaptions.isEmpty {
            attributes.append(
                "CLOSED-CAPTIONS=\"live-dvr-closed-captions\""
            )
        } else if variant?.closedCaptions == .explicitlyNone {
            attributes.append("CLOSED-CAPTIONS=NONE")
        }
        lines.append(
            "#EXT-X-STREAM-INF:"
                + attributes.joined(separator: ",")
        )
        lines.append("index.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    static func fileExtension(
        for sourceURL: URL,
        fallback: String
    ) -> String {
        let candidate = sourceURL.pathExtension.lowercased()
        guard
            !candidate.isEmpty,
            candidate.count <= 8,
            candidate.allSatisfy({
                $0.isLetter || $0.isNumber
            })
        else {
            return fallback
        }
        return candidate
    }

    private static func durationString(
        _ duration: TimeInterval
    ) -> String {
        var value = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            duration
        )
        while value.last == "0" {
            value.removeLast()
        }
        if value.last == "." {
            value.append("0")
        }
        return value
    }

    private static func mediaLine(
        _ selection: HLSLiveDVRSelectedRendition
    ) throws -> String {
        try mediaLine(
            rendition: selection.rendition,
            relativePlaylistPath:
                selection.track.relativePlaylistPath
        )
    }

    private static func mediaLine(
        rendition: HLSRendition,
        relativePlaylistPath: String?
    ) throws -> String {
        let type: String
        let groupID: String
        switch rendition.kind {
        case .audio:
            type = "AUDIO"
            groupID = "live-dvr-audio"
        case .video:
            type = "VIDEO"
            groupID = "live-dvr-video"
        case .subtitles:
            type = "SUBTITLES"
            groupID = "live-dvr-subtitles"
        case .closedCaptions:
            type = "CLOSED-CAPTIONS"
            groupID = "live-dvr-closed-captions"
        }
        try HLSPackageMasterPlaylistWriter.validateQuotedAttribute(
            rendition.name
        )
        var attributes = [
            "TYPE=\(type)",
            "GROUP-ID=\"\(groupID)\"",
            "NAME=\"\(rendition.name)\"",
        ]
        if let language = rendition.language {
            try HLSPackageMasterPlaylistWriter
                .validateQuotedAttribute(language)
            attributes.append("LANGUAGE=\"\(language)\"")
        }
        if let associatedLanguage = rendition.associatedLanguage {
            try HLSPackageMasterPlaylistWriter
                .validateQuotedAttribute(associatedLanguage)
            attributes.append(
                "ASSOC-LANGUAGE=\"\(associatedLanguage)\""
            )
        }
        if let stableID = rendition.stableID {
            try HLSPackageMasterPlaylistWriter
                .validateQuotedAttribute(stableID)
            attributes.append(
                "STABLE-RENDITION-ID=\"\(stableID)\""
            )
        }
        if let instreamID = rendition.instreamID {
            try HLSPackageMasterPlaylistWriter
                .validateQuotedAttribute(instreamID)
            attributes.append("INSTREAM-ID=\"\(instreamID)\"")
        }
        attributes.append(
            "DEFAULT=\(rendition.isDefault ? "YES" : "NO")"
        )
        attributes.append(
            "AUTOSELECT=\(rendition.isAutoselect ? "YES" : "NO")"
        )
        if rendition.kind == .subtitles {
            attributes.append(
                "FORCED=\(rendition.isForced ? "YES" : "NO")"
            )
        }
        if !rendition.characteristics.isEmpty {
            try rendition.characteristics.forEach(
                HLSPackageMasterPlaylistWriter
                    .validateQuotedAttribute
            )
            attributes.append(
                "CHARACTERISTICS=\""
                    + rendition.characteristics.joined(separator: ",")
                    + "\""
            )
        }
        if rendition.kind == .audio {
            if let channels = rendition.channels {
                try HLSPackageMasterPlaylistWriter
                    .validateQuotedAttribute(channels)
                attributes.append("CHANNELS=\"\(channels)\"")
            }
            if let bitDepth = rendition.audioBitDepth {
                attributes.append("BIT-DEPTH=\(bitDepth)")
            }
            if let sampleRate = rendition.audioSampleRate {
                attributes.append("SAMPLE-RATE=\(sampleRate)")
            }
        }
        if let relativePlaylistPath {
            attributes.append("URI=\"\(relativePlaylistPath)\"")
        }
        return "#EXT-X-MEDIA:" + attributes.joined(separator: ",")
    }

    private static func dateRangeLine(
        _ dateRange: HLSDateRange
    ) throws -> String {
        try HLSPackageMasterPlaylistWriter.validateQuotedAttribute(
            dateRange.id
        )
        var attributes = [
            "ID=\"\(dateRange.id)\"",
            "START-DATE=\"\(dateString(dateRange.startDate))\"",
        ]
        if let className = dateRange.className {
            try HLSPackageMasterPlaylistWriter
                .validateQuotedAttribute(className)
            attributes.append("CLASS=\"\(className)\"")
        }
        if let endDate = dateRange.endDate {
            attributes.append(
                "END-DATE=\"\(dateString(endDate))\""
            )
        }
        if let duration = dateRange.duration {
            attributes.append("DURATION=\(durationString(duration))")
        }
        if let plannedDuration = dateRange.plannedDuration {
            attributes.append(
                "PLANNED-DURATION=\(durationString(plannedDuration))"
            )
        }
        if !dateRange.cues.isEmpty {
            let cueValues = dateRange.cues.map { cue in
                switch cue {
                case .pre:
                    return "PRE"
                case .post:
                    return "POST"
                case .once:
                    return "ONCE"
                }
            }
            attributes.append(
                "CUE=\"\(cueValues.joined(separator: ","))\""
            )
        }
        if dateRange.endsOnNext {
            attributes.append("END-ON-NEXT=YES")
        }
        return "#EXT-X-DATERANGE:"
            + attributes.joined(separator: ",")
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }
}
