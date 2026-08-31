import Foundation
import InnoNetworkHLS

struct HLSLiveDVRCheckpoint: Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let sourceURLSHA256: String
    let variantIdentity: String?
    let primary: Track
    let renditions: [Rendition]
    let inBandClosedCaptionIdentities: [String]
    let dateRanges: [DateRange]
    let promotedPartCount: Int

    struct FileRecord: Codable, Sendable {
        let relativePath: String
        let byteCount: Int64
        let contentSHA256: String
    }

    struct Segment: Codable, Sendable {
        let sequenceNumber: Int64
        let duration: TimeInterval
        let beginsDiscontinuity: Bool
        let programDateTime: Date?
        let playlistPath: String
        let file: FileRecord

        init(
            _ segment: HLSLiveDVRStoredSegment,
            storagePrefix: String = ""
        ) {
            sequenceNumber = segment.sequenceNumber
            duration = segment.duration
            beginsDiscontinuity = segment.beginsDiscontinuity
            programDateTime = segment.programDateTime
            playlistPath = segment.fileName
            file = FileRecord(
                relativePath: Self.storagePath(
                    prefix: storagePrefix,
                    playlistPath: segment.fileName
                ),
                byteCount: segment.byteCount,
                contentSHA256: segment.contentSHA256
            )
        }

        var storedSegment: HLSLiveDVRStoredSegment {
            HLSLiveDVRStoredSegment(
                sequenceNumber: sequenceNumber,
                duration: duration,
                beginsDiscontinuity: beginsDiscontinuity,
                programDateTime: programDateTime,
                fileName: playlistPath,
                byteCount: file.byteCount,
                contentSHA256: file.contentSHA256
            )
        }

        private static func storagePath(
            prefix: String,
            playlistPath: String
        ) -> String {
            guard !prefix.isEmpty else {
                return playlistPath
            }
            return prefix + "/" + playlistPath
        }
    }

    struct Track: Codable, Sendable {
        let container: String
        let initializationSourceIdentity: String?
        let initializationPlaylistPath: String?
        let initialization: FileRecord?
        let segments: [Segment]

        var mediaContainer: HLSMediaContainer? {
            switch container {
            case "mpegTransportStream":
                return .mpegTransportStream
            case "fragmentedMP4":
                return .fragmentedMP4
            default:
                return nil
            }
        }
    }

    struct Rendition: Codable, Sendable {
        let identity: String
        let track: Track
    }

    struct DateRange: Codable, Sendable {
        let id: String
        let className: String?
        let startDate: Date
        let endDate: Date?
        let duration: TimeInterval?
        let plannedDuration: TimeInterval?
        let cues: [String]
        let endsOnNext: Bool

        init(_ dateRange: HLSDateRange) {
            id = dateRange.id
            className = dateRange.className
            startDate = dateRange.startDate
            endDate = dateRange.endDate
            duration = dateRange.duration
            plannedDuration = dateRange.plannedDuration
            cues = dateRange.cues.map { cue in
                switch cue {
                case .pre:
                    return "pre"
                case .post:
                    return "post"
                case .once:
                    return "once"
                }
            }
            endsOnNext = dateRange.endsOnNext
        }

        var model: HLSDateRange? {
            var decodedCues: [HLSDateRangeCue] = []
            for cue in cues {
                switch cue {
                case "pre":
                    decodedCues.append(.pre)
                case "post":
                    decodedCues.append(.post)
                case "once":
                    decodedCues.append(.once)
                default:
                    return nil
                }
            }
            return HLSDateRange(
                id: id,
                className: className,
                startDate: startDate,
                endDate: endDate,
                duration: duration,
                plannedDuration: plannedDuration,
                cues: decodedCues,
                endsOnNext: endsOnNext
            )
        }
    }

    var files: [FileRecord] {
        let primaryFiles =
            primary.initialization.map { [$0] } ?? []
            + primary.segments.map(\.file)
        return primaryFiles
            + renditions.flatMap { rendition in
                (rendition.track.initialization.map { [$0] } ?? [])
                    + rendition.track.segments.map(\.file)
            }
    }
}
