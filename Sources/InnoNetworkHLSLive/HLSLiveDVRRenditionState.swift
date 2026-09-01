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
    var initializationState = HLSLiveDVRInitializationRecordingState()
    private(set) var segments: [HLSLiveDVRStoredSegment] = []
    private(set) var recordedDuration: TimeInterval = 0
    private(set) var lastObservedSequence: Int64?
    private(set) var didObserveInitialSnapshot = false
    private var requiresRecoveryPresentationValidation = false

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
        let restoredInitializations =
            try HLSLiveDVRRecordingState.validatedInitializations(
                checkpoint,
                container: container
            )
        let legacyInitialization =
            checkpoint.initializations == nil
            ? checkpoint.resolvedInitializations.first
            : nil
        let restoredSegments = try checkpoint.segments.map {
            try $0.storedSegment(
                defaultInitialization: legacyInitialization
            )
        }
        guard
            Self.initializationReferencesAreValid(
                restoredSegments,
                initializations: restoredInitializations,
                container: container
            )
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        self.selection = selection
        self.container = container
        self.initializationState =
            HLSLiveDVRInitializationRecordingState(
                records: restoredInitializations
            )
        self.segments = restoredSegments
        self.recordedDuration = try Self.validatedDuration(segments)
        guard segments.count <= limits.maximumSegmentCount,
            recordedDuration <= limits.maximumDuration
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        self.lastObservedSequence = segments.last?.sequenceNumber
        self.didObserveInitialSnapshot = true
        self.requiresRecoveryPresentationValidation = true
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
        let initializations = initializationState.records.map {
            HLSLiveDVRCheckpoint.Initialization(
                $0,
                storagePrefix: selection.relativeDirectoryPath
            )
        }
        let legacyInitialization = initializations.first
        return HLSLiveDVRCheckpoint.Track(
            container: containerValue,
            initializationSourceIdentity:
                legacyInitialization?.sourceIdentity,
            initializationPlaylistPath:
                legacyInitialization?.playlistPath,
            initialization: legacyInitialization?.file,
            initializations: initializations,
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
        switch snapshotContainer {
        case .mpegTransportStream:
            guard snapshot.initializationSegments.isEmpty,
                snapshot.segments.allSatisfy({
                    $0.initializationSegment == nil
                })
            else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .changingInitializationSegment
                )
            }
        case .fragmentedMP4:
            guard
                snapshot.segments.allSatisfy({
                    $0.initializationSegment != nil
                })
            else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .missingInitializationSegment
                )
            }
        }
        guard
            HLSLiveDVRRecordingState
                .matchesOverlappingInitializations(
                    segments,
                    snapshot: snapshot
                )
        else {
            if requiresRecoveryPresentationValidation {
                throw HLSLiveDVRError.recoveryMismatch
            }
            throw HLSLiveDVRError.unsupportedFeature(
                .changingInitializationSegment
            )
        }
        guard
            HLSLiveDVRRecordingState.matchesOverlappingGaps(
                segments,
                snapshot: snapshot
            )
        else {
            if requiresRecoveryPresentationValidation {
                throw HLSLiveDVRError.recoveryMismatch
            }
            throw HLSLiveDVRError.unsupportedFeature(.gap)
        }
        requiresRecoveryPresentationValidation = false
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
        if limits.retentionPolicy == .rollingWindow {
            return segment.duration.isFinite
                && segment.duration > 0
                && segment.duration <= limits.maximumDuration
        }
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
        switch container {
        case .mpegTransportStream:
            guard segment.initializationSegment == nil else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .changingInitializationSegment
                )
            }
        case .fragmentedMP4:
            guard segment.initializationSegment != nil else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .missingInitializationSegment
                )
            }
        case nil:
            throw HLSLiveDVRError.unsupportedFeature(
                .unknownMediaContainer
            )
        }
    }

    mutating func retain(
        _ segment: HLSLiveSegment,
        fileName: String,
        byteCount: Int64,
        contentSHA256: String
    ) throws {
        guard !segment.isGap else {
            throw HLSLiveDVRError.storageFailed
        }
        let nextDuration = recordedDuration + segment.duration
        guard nextDuration.isFinite else {
            throw HLSLiveDVRError.storageFailed
        }
        let initialization = try storedInitialization(for: segment)
        segments.append(
            HLSLiveDVRStoredSegment(
                sequenceNumber: segment.sequenceNumber,
                duration: segment.duration,
                beginsDiscontinuity: segment.beginsDiscontinuity,
                programDateTime: segment.programDateTime,
                initializationSourceIdentity:
                    initialization?.sourceIdentity,
                initializationFileName: initialization?.fileName,
                fileName: fileName,
                byteCount: byteCount,
                contentSHA256: contentSHA256
            )
        )
        recordedDuration = nextDuration
        lastObservedSequence = segment.sequenceNumber
    }

    mutating func retainGap(
        _ segment: HLSLiveSegment,
        fileName: String
    ) throws {
        guard segment.isGap else {
            throw HLSLiveDVRError.storageFailed
        }
        let nextDuration = recordedDuration + segment.duration
        guard nextDuration.isFinite else {
            throw HLSLiveDVRError.storageFailed
        }
        let initialization = try storedInitialization(for: segment)
        segments.append(
            HLSLiveDVRStoredSegment.gap(
                sequenceNumber: segment.sequenceNumber,
                duration: segment.duration,
                beginsDiscontinuity:
                    segment.beginsDiscontinuity,
                programDateTime: segment.programDateTime,
                initializationSourceIdentity:
                    initialization?.sourceIdentity,
                initializationFileName: initialization?.fileName,
                fileName: fileName
            )
        )
        recordedDuration = nextDuration
        lastObservedSequence = segment.sequenceNumber
    }

    mutating func evictOldestSegment()
        -> HLSLiveDVRStoredSegment?
    {
        guard segments.count > 1 else {
            return nil
        }
        let removed = segments.removeFirst()
        recordedDuration = max(0, recordedDuration - removed.duration)
        return removed
    }

    mutating func removeUnreferencedInitializations()
        -> [HLSLiveDVRStoredInitialization]
    {
        initializationState.removeUnreferenced(
            retaining: Set(
                segments.compactMap(
                    \.initializationSourceIdentity
                )
            )
        )
    }

    private func storedInitialization(
        for segment: HLSLiveSegment
    ) throws -> HLSLiveDVRStoredInitialization? {
        switch container {
        case .mpegTransportStream:
            guard segment.initializationSegment == nil else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .changingInitializationSegment
                )
            }
            return nil
        case .fragmentedMP4:
            guard let source = segment.initializationSegment,
                let initialization = initializationState.retained(
                    for: source
                )
            else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .missingInitializationSegment
                )
            }
            return initialization
        case nil:
            throw HLSLiveDVRError.unsupportedFeature(
                .unknownMediaContainer
            )
        }
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

    private static func initializationReferencesAreValid(
        _ segments: [HLSLiveDVRStoredSegment],
        initializations: [HLSLiveDVRStoredInitialization],
        container: HLSMediaContainer
    ) -> Bool {
        switch container {
        case .mpegTransportStream:
            return initializations.isEmpty
                && segments.allSatisfy {
                    $0.initializationSourceIdentity == nil
                        && $0.initializationFileName == nil
                }
        case .fragmentedMP4:
            return !initializations.isEmpty
                && segments.allSatisfy { segment in
                    guard
                        let sourceIdentity =
                            segment.initializationSourceIdentity,
                        let fileName = segment.initializationFileName
                    else {
                        return false
                    }
                    return initializations.contains {
                        $0.sourceIdentity == sourceIdentity
                            && $0.fileName == fileName
                    }
                }
        }
    }
}
