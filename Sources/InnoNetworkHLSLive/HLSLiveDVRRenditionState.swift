import Foundation
import InnoNetworkHLS

struct HLSLiveDVRRenditionRequest: Sendable {
    let index: Int
    let url: URL
    let multivariantVariables: [String: String]
    let generation: Int
}

struct HLSLiveDVRRenditionRecordingState {
    let selection: HLSLiveDVRSelectedRendition
    private(set) var container: HLSMediaContainer?
    private(set) var initializationSegment: HLSLiveInitializationSegment?
    private var expectedInitializationIdentity: String?
    var initializationFileName: String?
    var initializationByteCount: Int64?
    var initializationContentSHA256: String?
    private(set) var segments: [HLSLiveDVRStoredSegment] = []
    private(set) var recordedDuration: TimeInterval = 0
    private(set) var lastObservedSequence: Int64?
    private(set) var didObserveInitialSnapshot = false

    init(selection: HLSLiveDVRSelectedRendition) {
        self.selection = selection
    }

    init(
        selection: HLSLiveDVRSelectedRendition,
        checkpoint: HLSLiveDVRCheckpoint.Track,
        limits: HLSLiveDVRLimitPack
    ) throws {
        guard let container = checkpoint.mediaContainer,
            !checkpoint.segments.isEmpty
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        switch container {
        case .mpegTransportStream:
            guard checkpoint.initialization == nil,
                checkpoint.initializationPlaylistPath == nil,
                checkpoint.initializationSourceIdentity == nil
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
        case .fragmentedMP4:
            guard checkpoint.initialization != nil,
                checkpoint.initializationPlaylistPath != nil,
                checkpoint.initializationSourceIdentity != nil
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
        }
        self.selection = selection
        self.container = container
        self.initializationFileName =
            checkpoint.initializationPlaylistPath
        self.initializationByteCount =
            checkpoint.initialization?.byteCount
        self.initializationContentSHA256 =
            checkpoint.initialization?.contentSHA256
        self.expectedInitializationIdentity =
            checkpoint.initializationSourceIdentity
        self.segments = checkpoint.segments.map(\.storedSegment)
        self.recordedDuration = try Self.validatedDuration(segments)
        guard segments.count <= limits.maximumSegmentCount,
            recordedDuration <= limits.maximumDuration
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        self.lastObservedSequence = segments.last?.sequenceNumber
        self.didObserveInitialSnapshot = true
    }

    var checkpointTrack: HLSLiveDVRCheckpoint.Track? {
        guard let container else {
            return nil
        }
        let containerValue: String
        switch container {
        case .mpegTransportStream:
            containerValue = "mpegTransportStream"
        case .fragmentedMP4:
            containerValue = "fragmentedMP4"
        }
        let initialization: HLSLiveDVRCheckpoint.FileRecord?
        if let initializationFileName,
            let initializationByteCount,
            let initializationContentSHA256
        {
            initialization = HLSLiveDVRCheckpoint.FileRecord(
                relativePath: initializationFileName,
                byteCount: initializationByteCount,
                contentSHA256: initializationContentSHA256
            )
        } else {
            initialization = nil
        }
        return HLSLiveDVRCheckpoint.Track(
            container: containerValue,
            initializationSourceIdentity:
                initializationSegment.map(
                    HLSLiveDVRRecoveryIdentity
                        .initializationSegmentIdentity
                ) ?? expectedInitializationIdentity,
            initializationPlaylistPath: initializationFileName,
            initialization: initialization.map { record in
                HLSLiveDVRCheckpoint.FileRecord(
                    relativePath:
                        selection.relativeDirectoryPath
                        + "/"
                        + record.relativePath,
                    byteCount: record.byteCount,
                    contentSHA256: record.contentSHA256
                )
            },
            segments: segments.map { segment in
                HLSLiveDVRCheckpoint.Segment(
                    segment,
                    storagePrefix: selection.relativeDirectoryPath
                )
            }
        )
    }

    mutating func validatePresentation(
        _ snapshot: HLSLivePlaylistSnapshot
    ) throws {
        guard let snapshotContainer = snapshot.playlist.mediaContainer else {
            throw HLSLiveDVRError.unsupportedFeature(
                .unknownMediaContainer
            )
        }
        if let container, container != snapshotContainer {
            throw HLSLiveDVRError.unsupportedFeature(
                .changingInitializationSegment
            )
        }
        container = snapshotContainer
        if let encryptionMethod = snapshot.encryptionMethod,
            encryptionMethod != "AES-128"
        {
            throw HLSLiveDVRError.unsupportedFeature(.encryptedMedia)
        }
        guard snapshot.initializationSegments.count <= 1 else {
            throw HLSLiveDVRError.unsupportedFeature(
                .changingInitializationSegment
            )
        }
        let candidate = snapshot.initializationSegments.first
        switch snapshotContainer {
        case .mpegTransportStream:
            guard candidate == nil else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .changingInitializationSegment
                )
            }
        case .fragmentedMP4:
            guard let candidate else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .missingInitializationSegment
                )
            }
            if let initializationSegment,
                initializationSegment != candidate
            {
                throw HLSLiveDVRError.unsupportedFeature(
                    .changingInitializationSegment
                )
            }
            if let expectedInitializationIdentity,
                HLSLiveDVRRecoveryIdentity
                    .initializationSegmentIdentity(candidate)
                    != expectedInitializationIdentity
            {
                throw HLSLiveDVRError.recoveryMismatch
            }
            initializationSegment = candidate
        }
    }

    mutating func candidates(
        in snapshot: HLSLivePlaylistSnapshot,
        startPosition: HLSLiveDVRStartPosition
    ) throws -> [HLSLiveSegment] {
        try validateSequence(snapshot.segments)
        if !didObserveInitialSnapshot {
            didObserveInitialSnapshot = true
            if startPosition == .nextCompletedSegment {
                lastObservedSequence =
                    snapshot.segments.last?.sequenceNumber
                return []
            }
        }
        let candidates: [HLSLiveSegment]
        if let lastObservedSequence {
            candidates = snapshot.segments.filter {
                $0.sequenceNumber > lastObservedSequence
            }
            if let first = candidates.first {
                let (expected, overflow) =
                    lastObservedSequence.addingReportingOverflow(1)
                guard !overflow, first.sequenceNumber == expected else {
                    throw HLSLiveDVRError.liveWindowAdvanced
                }
            }
        } else {
            candidates = snapshot.segments
        }
        return candidates
    }

    func canRetain(
        _ segment: HLSLiveSegment,
        limits: HLSLiveDVRLimitPack
    ) -> Bool {
        guard segments.count < limits.maximumSegmentCount else {
            return false
        }
        let nextDuration = recordedDuration + segment.duration
        return nextDuration.isFinite
            && nextDuration <= limits.maximumDuration
    }

    func validate(_ segment: HLSLiveSegment) throws {
        guard segment.duration.isFinite, segment.duration > 0 else {
            throw HLSLiveDVRError.transferFailed
        }
        guard !segment.isGap else {
            throw HLSLiveDVRError.unsupportedFeature(.gap)
        }
    }

    mutating func retain(
        _ segment: HLSLiveSegment,
        fileName: String,
        byteCount: Int64,
        contentSHA256: String
    ) throws {
        let nextDuration = recordedDuration + segment.duration
        guard nextDuration.isFinite else {
            throw HLSLiveDVRError.storageFailed
        }
        segments.append(
            HLSLiveDVRStoredSegment(
                sequenceNumber: segment.sequenceNumber,
                duration: segment.duration,
                beginsDiscontinuity: segment.beginsDiscontinuity,
                programDateTime: segment.programDateTime,
                fileName: fileName,
                byteCount: byteCount,
                contentSHA256: contentSHA256
            )
        )
        recordedDuration = nextDuration
        lastObservedSequence = segment.sequenceNumber
    }

    private func validateSequence(
        _ segments: [HLSLiveSegment]
    ) throws {
        var previous: Int64?
        for segment in segments {
            if let previous {
                let (expected, overflow) =
                    previous.addingReportingOverflow(1)
                guard !overflow, segment.sequenceNumber == expected else {
                    throw HLSLiveDVRError.liveWindowAdvanced
                }
            }
            previous = segment.sequenceNumber
        }
    }

    private static func validatedDuration(
        _ segments: [HLSLiveDVRStoredSegment]
    ) throws -> TimeInterval {
        var duration: TimeInterval = 0
        var previousSequence: Int64?
        for segment in segments {
            guard segment.duration.isFinite, segment.duration > 0 else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            if let previousSequence {
                let (expected, overflow) =
                    previousSequence.addingReportingOverflow(1)
                guard !overflow, segment.sequenceNumber == expected else {
                    throw HLSLiveDVRError.recoveryCorrupted
                }
            }
            duration += segment.duration
            guard duration.isFinite else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            previousSequence = segment.sequenceNumber
        }
        return duration
    }
}
