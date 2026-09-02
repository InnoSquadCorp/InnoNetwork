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
    var retentionPolicy: String? = nil
    var retentionStatistics: RetentionStatistics? = nil
    var interstitialPolicy: String? = nil
    var interstitials: [Interstitial]? = nil
    var omittedInterstitials: [OmittedInterstitial]? = nil

    struct FileRecord: Codable, Equatable, Sendable {
        let relativePath: String
        let byteCount: Int64
        let contentSHA256: String
    }

    struct RetentionStatistics: Codable, Sendable {
        let evictedPrimarySegmentCount: Int
        let evictedPrimaryDuration: TimeInterval
        let evictedMediaByteCount: Int64

        init(_ statistics: HLSLiveDVRRetentionStatistics) {
            evictedPrimarySegmentCount =
                statistics.evictedPrimarySegmentCount
            evictedPrimaryDuration = statistics.evictedPrimaryDuration
            evictedMediaByteCount = statistics.evictedMediaByteCount
        }

        var model: HLSLiveDVRRetentionStatistics? {
            guard evictedPrimarySegmentCount >= 0,
                evictedPrimaryDuration.isFinite,
                evictedPrimaryDuration >= 0,
                evictedMediaByteCount >= 0
            else {
                return nil
            }
            return HLSLiveDVRRetentionStatistics(
                evictedPrimarySegmentCount: evictedPrimarySegmentCount,
                evictedPrimaryDuration: evictedPrimaryDuration,
                evictedMediaByteCount: evictedMediaByteCount
            )
        }
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
        let isGap: Bool?
        let playlistPath: String
        let file: FileRecord?

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
            isGap = segment.isGap
            playlistPath = segment.fileName
            file = segment.contentSHA256.map {
                FileRecord(
                    relativePath: Self.storagePath(
                        prefix: storagePrefix,
                        playlistPath: segment.fileName
                    ),
                    byteCount: segment.byteCount,
                    contentSHA256: $0
                )
            }
        }

        func storedSegment() throws -> HLSLiveDVRStoredSegment {
            try storedSegment(defaultInitialization: nil)
        }

        func storedSegment(
            defaultInitialization: Initialization?
        ) throws -> HLSLiveDVRStoredSegment {
            let resolvedInitializationSourceIdentity =
                initializationSourceIdentity
                ?? defaultInitialization?.sourceIdentity
            let resolvedInitializationPlaylistPath =
                initializationPlaylistPath
                ?? defaultInitialization?.playlistPath
            switch (isGap ?? false, file) {
            case (false, let file?):
                return HLSLiveDVRStoredSegment(
                    sequenceNumber: sequenceNumber,
                    duration: duration,
                    beginsDiscontinuity: beginsDiscontinuity,
                    programDateTime: programDateTime,
                    initializationSourceIdentity:
                        resolvedInitializationSourceIdentity,
                    initializationFileName:
                        resolvedInitializationPlaylistPath,
                    fileName: playlistPath,
                    byteCount: file.byteCount,
                    contentSHA256: file.contentSHA256
                )
            case (true, nil):
                return HLSLiveDVRStoredSegment.gap(
                    sequenceNumber: sequenceNumber,
                    duration: duration,
                    beginsDiscontinuity: beginsDiscontinuity,
                    programDateTime: programDateTime,
                    initializationSourceIdentity:
                        resolvedInitializationSourceIdentity,
                    initializationFileName:
                        resolvedInitializationPlaylistPath,
                    fileName: playlistPath
                )
            default:
                throw HLSLiveDVRError.recoveryCorrupted
            }
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

    struct Interstitial: Codable, Sendable {
        let id: String
        let sourceIdentity: String
        let eventDirectoryPath: String
        let assetCount: Int
        let files: [FileRecord]

        init(_ interstitial: HLSLiveDVRStoredInterstitial) {
            id = interstitial.id
            sourceIdentity = interstitial.sourceIdentity
            eventDirectoryPath = interstitial.eventDirectoryPath
            assetCount = interstitial.assetCount
            files = interstitial.files
        }
    }

    struct OmittedInterstitial: Codable, Sendable {
        let id: String
        let sourceIdentity: String

        init(_ interstitial: HLSLiveDVROmittedInterstitial) {
            id = interstitial.id
            sourceIdentity = interstitial.sourceIdentity
        }
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
        let interstitial: InterstitialMetadata?

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
            interstitial = dateRange.interstitial.map(
                InterstitialMetadata.init
            )
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
                endsOnNext: endsOnNext,
                interstitial: interstitial?.model
            )
        }

        struct InterstitialMetadata: Codable, Sendable {
            let sourceKind: String
            let sourcePath: String
            let resumeOffset: TimeInterval?
            let playoutLimit: TimeInterval?
            let contentVariability: String
            let timelineOccupancy: String
            let timelineStyle: String
            let navigationRestrictions: [String]
            let skipControl: SkipControl?

            init(_ interstitial: HLSInterstitial) {
                switch interstitial.source {
                case .asset(let url):
                    sourceKind = "asset"
                    sourcePath = url.relativeString
                case .assetList(let url):
                    sourceKind = "assetList"
                    sourcePath = url.relativeString
                }
                resumeOffset = interstitial.resumeOffset
                playoutLimit = interstitial.playoutLimit
                contentVariability =
                    interstitial.contentVariability == .mayVary
                    ? "mayVary" : "sameForAllPlayers"
                timelineOccupancy =
                    interstitial.timelineOccupancy == .point
                    ? "point" : "range"
                timelineStyle =
                    interstitial.timelineStyle == .highlight
                    ? "highlight" : "primary"
                navigationRestrictions = [
                    HLSInterstitialNavigationRestriction.skip,
                    .jump,
                ].filter {
                    interstitial.navigationRestrictions.contains($0)
                }.map {
                    switch $0 {
                    case .skip:
                        "skip"
                    case .jump:
                        "jump"
                    }
                }
                skipControl = interstitial.skipControl.map(SkipControl.init)
            }

            var model: HLSInterstitial? {
                guard let sourceURL = URL(string: sourcePath),
                    sourceURL.scheme == nil,
                    sourceURL.host == nil,
                    sourceURL.user == nil,
                    sourceURL.password == nil,
                    sourceURL.port == nil,
                    sourceURL.query == nil,
                    sourceURL.fragment == nil,
                    !sourcePath.isEmpty,
                    resumeOffset.map({ $0.isFinite }) ?? true,
                    playoutLimit.map({ $0.isFinite && $0 >= 0 }) ?? true
                else {
                    return nil
                }
                let source: HLSInterstitialSource
                switch sourceKind {
                case "asset":
                    source = .asset(sourceURL)
                case "assetList":
                    source = .assetList(sourceURL)
                default:
                    return nil
                }
                let variability: HLSInterstitialContentVariability
                switch contentVariability {
                case "mayVary":
                    variability = .mayVary
                case "sameForAllPlayers":
                    variability = .sameForAllPlayers
                default:
                    return nil
                }
                let occupancy: HLSInterstitialTimelineOccupancy
                switch timelineOccupancy {
                case "point":
                    occupancy = .point
                case "range":
                    occupancy = .range
                default:
                    return nil
                }
                let style: HLSInterstitialTimelineStyle
                switch timelineStyle {
                case "highlight":
                    style = .highlight
                case "primary":
                    style = .primary
                default:
                    return nil
                }
                var restrictions:
                    Set<
                        HLSInterstitialNavigationRestriction
                    > = []
                for restriction in navigationRestrictions {
                    switch restriction {
                    case "skip":
                        restrictions.insert(.skip)
                    case "jump":
                        restrictions.insert(.jump)
                    default:
                        return nil
                    }
                }
                guard restrictions.count == navigationRestrictions.count
                else {
                    return nil
                }
                return HLSInterstitial(
                    source: source,
                    resumeOffset: resumeOffset,
                    playoutLimit: playoutLimit,
                    contentVariability: variability,
                    timelineOccupancy: occupancy,
                    timelineStyle: style,
                    navigationRestrictions: restrictions,
                    skipControl: skipControl?.model
                )
            }
        }

        struct SkipControl: Codable, Sendable {
            let offset: UInt64?
            let duration: UInt64?
            let labelID: String?

            init(_ skipControl: HLSInterstitialSkipControl) {
                offset = skipControl.offset
                duration = skipControl.duration
                labelID = skipControl.labelID
            }

            var model: HLSInterstitialSkipControl? {
                guard offset != nil || duration != nil || labelID != nil,
                    labelID?.allSatisfy({
                        $0.isASCII
                            && ($0.isLetter || $0 == "-" || $0 == "_")
                    }) != false
                else {
                    return nil
                }
                return HLSInterstitialSkipControl(
                    offset: offset,
                    duration: duration,
                    labelID: labelID
                )
            }
        }
    }

    var files: [FileRecord] {
        let primaryFiles =
            primary.resolvedInitializations.map(\.file)
            + primary.segments.compactMap(\.file)
        return primaryFiles
            + renditions.flatMap { rendition in
                rendition.track.resolvedInitializations.map(\.file)
                    + rendition.track.segments.compactMap(\.file)
            }
            + (interstitials ?? []).flatMap(\.files)
    }
}
