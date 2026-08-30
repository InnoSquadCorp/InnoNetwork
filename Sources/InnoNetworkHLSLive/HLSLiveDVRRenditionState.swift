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
    var initializationFileName: String?
    private(set) var segments: [HLSLiveDVRStoredSegment] = []
    private(set) var recordedDuration: TimeInterval = 0
    private(set) var lastObservedSequence: Int64?
    private(set) var didObserveInitialSnapshot = false

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
        fileName: String
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
                fileName: fileName
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
}
