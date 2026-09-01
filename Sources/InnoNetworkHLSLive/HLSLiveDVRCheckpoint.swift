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

    struct Initialization: Codable, Sendable {
        let sourceIdentity: String
        let playlistPath: String
        let file: FileRecord

        init(
            _ initialization: HLSLiveDVRStoredInitialization,
            storagePrefix: String = ""
        ) {
            sourceIdentity = initialization.sourceIdentity
            playlistPath = initialization.fileName
            file = FileRecord(
                relativePath: Segment.storagePath(
                    prefix: storagePrefix,
                    playlistPath: initialization.fileName
                ),
                byteCount: initialization.byteCount,
                contentSHA256: initialization.contentSHA256
            )
        }

        init(
            sourceIdentity: String,
            playlistPath: String,
            file: FileRecord
        ) {
            self.sourceIdentity = sourceIdentity
            self.playlistPath = playlistPath
            self.file = file
        }

        var storedInitialization: HLSLiveDVRStoredInitialization {
            HLSLiveDVRStoredInitialization(
                sourceIdentity: sourceIdentity,
                fileName: playlistPath,
                byteCount: file.byteCount,
                contentSHA256: file.contentSHA256
            )
        }
    }

    struct Segment: Codable, Sendable {
        let sequenceNumber: Int64
        let duration: TimeInterval
        let beginsDiscontinuity: Bool
        let programDateTime: Date?
        let initializationSourceIdentity: String?
        let initializationPlaylistPath: String?
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
            initializationSourceIdentity =
                segment.initializationSourceIdentity
            initializationPlaylistPath =
                segment.initializationFileName
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
            storedSegment(defaultInitialization: nil)
        }

        func storedSegment(
            defaultInitialization: Initialization?
        ) -> HLSLiveDVRStoredSegment {
            HLSLiveDVRStoredSegment(
                sequenceNumber: sequenceNumber,
                duration: duration,
                beginsDiscontinuity: beginsDiscontinuity,
                programDateTime: programDateTime,
                initializationSourceIdentity:
                    initializationSourceIdentity
                    ?? defaultInitialization?.sourceIdentity,
                initializationFileName:
                    initializationPlaylistPath
                    ?? defaultInitialization?.playlistPath,
                fileName: playlistPath,
                byteCount: file.byteCount,
                contentSHA256: file.contentSHA256
            )
        }

        fileprivate static func storagePath(
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
        let initializations: [Initialization]?
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

        var resolvedInitializations: [Initialization] {
            if let initializations {
                return initializations
            }
            guard let initializationSourceIdentity,
                let initializationPlaylistPath,
                let initialization
            else {
                return []
            }
            return [
                Initialization(
                    sourceIdentity: initializationSourceIdentity,
                    playlistPath: initializationPlaylistPath,
                    file: initialization
                )
            ]
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
            primary.resolvedInitializations.map(\.file)
            + primary.segments.map(\.file)
        return primaryFiles
            + renditions.flatMap { rendition in
                rendition.track.resolvedInitializations.map(\.file)
                    + rendition.track.segments.map(\.file)
            }
    }
}
