import Foundation
import InnoNetworkHLS

struct HLSLiveDVRRecordingState {
    let configuration: HLSLiveDVRConfiguration
    let workspace: HLSLiveDVRWorkspace

    var container: HLSMediaContainer?
    var initializationSegment: HLSLiveInitializationSegment?
    var initializationFileName: String?
    var initializationByteCount: Int64?
    var initializationContentSHA256: String?
    var segments: [HLSLiveDVRStoredSegment] = []
    var recordedDuration: TimeInterval = 0
    var mediaByteCount: Int64 = 0
    var lastObservedSequence: Int64?
    var didObserveInitialSnapshot = false
    var nextResourceIndex = 0
    var selectedVariant: HLSVariant?
    var selectedRenditions: [HLSLiveDVRSelectedRendition] = []
    var inBandClosedCaptions: [HLSRendition] = []
    var renditionStates: [HLSLiveDVRRenditionRecordingState] = []
    var dateRanges: [HLSDateRange] = []
    var partState: HLSLiveDVRPartRecordingState
    var preloadStatistics = HLSLiveDVRPreloadStatistics()
    var didConfigureRenditions = false
    var initialPathwayID: String?

    var promotedPartCount: Int {
        partState.promotedPartCount
    }

    init(
        configuration: HLSLiveDVRConfiguration,
        workspace: HLSLiveDVRWorkspace
    ) {
        self.configuration = configuration
        self.workspace = workspace
        self.partState = HLSLiveDVRPartRecordingState(
            pack: configuration.parts
        )
    }

    var reachedLimit: Bool {
        segments.count >= configuration.limits.maximumSegmentCount
            || recordedDuration
                >= configuration.limits.maximumDuration
            || mediaByteCount
                >= configuration.limits.maximumTotalMediaBytes
    }

    var progress: HLSLiveDVRProgress {
        HLSLiveDVRProgress(
            segmentCount: segments.count,
            recordedDuration: recordedDuration,
            mediaByteCount: mediaByteCount,
            stagedPartCount: partState.stagedParts.count,
            stagedPartDuration: partState.stagedPartDuration,
            stagedPartByteCount: partState.stagedPartByteCount,
            promotedPartCount: partState.promotedPartCount,
            preloadStatistics: preloadStatistics
        )
    }

    mutating func updateStagedParts(
        from snapshot: HLSLivePlaylistSnapshot
    ) -> HLSLiveDVRPartUpdate {
        partState.update(from: snapshot)
    }

    func availableStagedPartByteCount() -> Int64 {
        partState.availableByteCount(
            totalRetainedByteCount: mediaByteCount,
            maximumTotalByteCount:
                configuration.limits.maximumTotalMediaBytes
        )
    }

    func availableMediaByteCount() -> Int64 {
        let (retainedAndStaged, overflow) =
            mediaByteCount.addingReportingOverflow(
                partState.stagedPartByteCount
            )
        guard !overflow else {
            return 0
        }
        return max(
            0,
            configuration.limits.maximumTotalMediaBytes
                - retainedAndStaged
        )
    }

    mutating func retainStagedPart(
        _ candidate: HLSLiveDVRPartCandidate,
        relativeFilePath: String,
        byteCount: Int64
    ) throws {
        try partState.retain(
            candidate,
            relativeFilePath: relativeFilePath,
            byteCount: byteCount,
            totalRetainedByteCount: mediaByteCount,
            maximumTotalByteCount:
                configuration.limits.maximumTotalMediaBytes
        )
        nextResourceIndex += 1
    }

    func partPromotion(
        for segment: HLSLiveSegment
    ) -> HLSLiveDVRPartPromotion? {
        partState.promotion(for: segment)
    }

    mutating func promote(
        _ segment: HLSLiveSegment,
        fileName: String,
        promotion: HLSLiveDVRPartPromotion,
        contentSHA256: String
    ) throws {
        let nextDuration = recordedDuration + segment.duration
        let (nextBytes, byteOverflow) =
            mediaByteCount.addingReportingOverflow(
                promotion.byteCount
            )
        guard nextDuration.isFinite,
            !byteOverflow,
            nextBytes
                <= configuration.limits.maximumTotalMediaBytes
        else {
            throw HLSLiveDVRError.storageFailed
        }
        try partState.consumePromotion(promotion)
        mediaByteCount = nextBytes
        append(
            segment,
            fileName: fileName,
            byteCount: promotion.byteCount,
            contentSHA256: contentSHA256,
            nextDuration: nextDuration
        )
    }

    mutating func discardStagedParts(
        mediaSequenceNumber: Int64
    ) -> [String] {
        partState.discard(
            mediaSequenceNumber: mediaSequenceNumber
        )
    }

    mutating func discardAllStagedParts() -> [String] {
        partState.discardAll()
    }

    mutating func abandonStagedParts(
        mediaSequenceNumber: Int64
    ) -> [String] {
        partState.abandon(
            mediaSequenceNumber: mediaSequenceNumber
        )
    }

    mutating func addMediaBytes(
        _ byteCount: Int64
    ) throws {
        let (nextBytes, overflow) =
            mediaByteCount.addingReportingOverflow(byteCount)
        let (totalBytes, totalOverflow) =
            nextBytes.addingReportingOverflow(
                partState.stagedPartByteCount
            )
        guard
            !overflow,
            !totalOverflow,
            totalBytes
                <= configuration.limits.maximumTotalMediaBytes
        else {
            throw HLSLiveDVRError.storageFailed
        }
        mediaByteCount = nextBytes
    }

    mutating func append(
        _ segment: HLSLiveSegment,
        fileName: String,
        byteCount: Int64,
        contentSHA256: String,
        nextDuration: TimeInterval
    ) {
        segments.append(
            HLSLiveDVRStoredSegment(
                sequenceNumber: segment.sequenceNumber,
                duration: segment.duration,
                beginsDiscontinuity:
                    segment.beginsDiscontinuity,
                programDateTime: segment.programDateTime,
                fileName: fileName,
                byteCount: byteCount,
                contentSHA256: contentSHA256
            )
        )
        recordedDuration = nextDuration
        lastObservedSequence = segment.sequenceNumber
    }

}
