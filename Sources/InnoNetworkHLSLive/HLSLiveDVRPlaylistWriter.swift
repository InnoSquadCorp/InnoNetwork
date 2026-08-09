import Foundation
import InnoNetworkHLS

struct HLSLiveDVRStoredSegment: Equatable, Sendable {
    let sequenceNumber: Int64
    let duration: TimeInterval
    let beginsDiscontinuity: Bool
    let fileName: String
}

enum HLSLiveDVRPlaylistWriter {
    static func make(
        container: HLSMediaContainer,
        initializationFileName: String?,
        segments: [HLSLiveDVRStoredSegment]
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
            guard initializationFileName == nil else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .changingInitializationSegment
                )
            }
        case .fragmentedMP4:
            guard let initializationFileName else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .missingInitializationSegment
                )
            }
            lines.append(
                "#EXT-X-MAP:URI=\"\(initializationFileName)\""
            )
        }

        for segment in segments {
            if segment.beginsDiscontinuity {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            lines.append("#EXTINF:\(durationString(segment.duration)),")
            lines.append(segment.fileName)
        }
        lines.append("#EXT-X-ENDLIST")
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
}
