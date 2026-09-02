import Foundation
import InnoNetworkHLS

struct HLSLiveDVRRecordingState {
    let configuration: HLSLiveDVRConfiguration
    let workspace: HLSLiveDVRWorkspace

    var container: HLSMediaContainer?
    var initializationState = HLSLiveDVRInitializationRecordingState()
    var segments: [HLSLiveDVRStoredSegment] = []
    var recordedDuration: TimeInterval = 0
    var mediaByteCount: Int64 = 0
    var gapCount = 0
    var lastObservedSequence: Int64?
    var didObserveInitialSnapshot = false
    var nextResourceIndex = 0
    var selectedVariant: HLSVariant?
    var selectedRenditions: [HLSLiveDVRSelectedRendition] = []
    var inBandClosedCaptions: [HLSRendition] = []
    var renditionStates: [HLSLiveDVRRenditionRecordingState] = []
    var dateRanges: [HLSDateRange] = []
    var interstitials: [HLSLiveDVRStoredInterstitial] = []
    var omittedInterstitials: [HLSLiveDVROmittedInterstitial] = []
    var resolvedDateRangeSchedules: [HLSLiveDVRResolvedDateRangeSchedule] = []
    var observedDateRangeScheduleIDs: Set<String> = []
    var partState: HLSLiveDVRPartRecordingState
    var preloadStatistics = HLSLiveDVRPreloadStatistics()
    var retentionStatistics = HLSLiveDVRRetentionStatistics()
    var pendingEvictionFilePaths: Set<String> = []
    var didConfigureRenditions = false
    var initialPathwayID: String?

    var promotedPartCount: Int {
        partState.promotedPartCount
    }

    var interstitialStatistics: HLSLiveDVRInterstitialStatistics {
        HLSLiveDVRInterstitialStatistics(
            retainedEventCount: interstitials.count,
            retainedAssetCount: interstitials.reduce(0) {
                $0 + $1.assetCount
            },
            retainedByteCount: interstitials.reduce(0) {
                $0 + $1.byteCount
            },
            omittedEventCount: omittedInterstitials.count
        )
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
        guard configuration.limits.retentionPolicy == .stopAtLimit else {
            return false
        }
        return segments.count >= configuration.limits.maximumSegmentCount
            || recordedDuration
                >= configuration.limits.maximumDuration
            || mediaByteCount
                >= configuration.limits.maximumTotalMediaBytes
    }

    var progress: HLSLiveDVRProgress {
        HLSLiveDVRProgress(
            segmentCount: segments.count,
            gapCount: gapCount,
            recordedDuration: recordedDuration,
            mediaByteCount: mediaByteCount,
            stagedPartCount: partState.stagedParts.count,
            stagedPartDuration: partState.stagedPartDuration,
            stagedPartByteCount: partState.stagedPartByteCount,
            promotedPartCount: partState.promotedPartCount,
            preloadStatistics: preloadStatistics,
            retentionStatistics: retentionStatistics,
            interstitialStatistics: interstitialStatistics
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
        if configuration.limits.retentionPolicy == .rollingWindow {
            return min(
                Int64(configuration.limits.maximumMediaResourceBytes),
                configuration.limits.maximumTotalMediaBytes
            )
        }
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
            promotion.byteCount
                <= configuration.limits.maximumTotalMediaBytes,
            configuration.limits.retentionPolicy == .rollingWindow
                || nextBytes
                    <= configuration.limits.maximumTotalMediaBytes
        else {
            throw HLSLiveDVRError.storageFailed
        }
        try partState.consumePromotion(promotion)
        mediaByteCount = nextBytes
        try append(
            segment,
            fileName: fileName,
            byteCount: promotion.byteCount,
            contentSHA256: contentSHA256,
            nextDuration: nextDuration
        )
        try applyRollingRetentionAfterPrimarySegment()
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
        let respectsTotalLimit =
            configuration.limits.retentionPolicy == .rollingWindow
            || totalBytes
                <= configuration.limits.maximumTotalMediaBytes
        guard !overflow,
            !totalOverflow,
            byteCount <= configuration.limits.maximumTotalMediaBytes,
            respectsTotalLimit
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
    ) throws {
        guard !segment.isGap else {
            throw HLSLiveDVRError.storageFailed
        }
        let initialization = try storedInitialization(for: segment)
        segments.append(
            HLSLiveDVRStoredSegment(
                sequenceNumber: segment.sequenceNumber,
                duration: segment.duration,
                beginsDiscontinuity:
                    segment.beginsDiscontinuity,
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
        gapCount += 1
        lastObservedSequence = segment.sequenceNumber
        try applyRollingRetentionAfterPrimarySegment()
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

}
