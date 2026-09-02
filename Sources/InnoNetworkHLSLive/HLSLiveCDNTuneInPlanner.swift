import Foundation

struct HLSLiveCDNTuneInPlan: Sendable {
    private let firstEdge: HLSLiveMediaEdge
    private let firstMeasuredAt: Date
    private let goalDuration: TimeInterval
    private let targetDuration: TimeInterval
    private let partTargetDuration: TimeInterval

    init?(first snapshot: HLSLivePlaylistSnapshot) {
        guard
            !snapshot.isEnded,
            snapshot.playlist.lowLatency?
                .serverControl?.canBlockReload == true,
            let partTargetDuration = snapshot.playlist.lowLatency?
                .partialSegmentTargetDuration,
            partTargetDuration.isFinite,
            partTargetDuration > 0,
            let targetDuration = snapshot.playlist.targetDuration.map(
                TimeInterval.init
            ),
            targetDuration.isFinite,
            targetDuration > 0,
            let freshness = snapshot.httpFreshness,
            let reportedAge = freshness.reportedAge,
            reportedAge
                >= partTargetDuration.rounded(.down),
            let firstEdge = try? HLSLiveMediaEdge.latest(in: snapshot)
        else {
            return nil
        }
        self.firstEdge = firstEdge
        self.firstMeasuredAt = freshness.measuredAt
        self.goalDuration =
            reportedAge + (partTargetDuration < 1 ? 1 : 0)
        self.targetDuration = targetDuration
        self.partTargetDuration = partTargetDuration
    }

    func nextRequest(
        after snapshot: HLSLivePlaylistSnapshot,
        measuredAt: Date
    ) throws -> HLSLiveReloadRequest? {
        guard
            !snapshot.isEnded,
            let reportedAge = snapshot.httpFreshness?.reportedAge,
            reportedAge
                >= partTargetDuration.rounded(.down),
            let currentEdge = try HLSLiveMediaEdge.latest(in: snapshot)
        else {
            return nil
        }
        let elapsed = max(
            0,
            measuredAt.timeIntervalSince(firstMeasuredAt)
        )
        guard elapsed.isFinite else {
            return nil
        }
        let currentGoal = goalDuration + elapsed
        guard currentGoal.isFinite else {
            return nil
        }
        let advancement = try firstEdge.advancement(
            to: currentEdge,
            currentSegments: snapshot.segments,
            targetDuration: targetDuration
        )
        guard advancement < currentGoal else {
            return nil
        }
        let remainingDuration = currentGoal - advancement
        let position = try currentEdge.position(
            advancingBy: remainingDuration,
            targetDuration: targetDuration,
            partTargetDuration: partTargetDuration
        )
        return try HLSLiveReloadRequestBuilder.cdnTuneInRequest(
            from: snapshot.playlist.sourceURL,
            mediaSequenceNumber: position.mediaSequenceNumber,
            partIndex: position.partIndex
        )
    }
}

extension HLSLiveMediaEdge {
    func advancement(
        to current: HLSLiveMediaEdge,
        currentSegments: [HLSLiveSegment],
        targetDuration: TimeInterval
    ) throws -> TimeInterval {
        let (sequenceDelta, sequenceOverflow) =
            current.mediaSequenceNumber
            .subtractingReportingOverflow(mediaSequenceNumber)
        guard !sequenceOverflow else {
            throw HLSLiveError.sequenceOverflow
        }
        var duration =
            TimeInterval(sequenceDelta) * targetDuration
            - mediaOffset
            + current.mediaOffset
        if sequenceDelta == 0 {
            duration = current.mediaOffset - mediaOffset
        } else if sequenceDelta > 0 {
            for segment in currentSegments
            where segment.sequenceNumber >= mediaSequenceNumber
                && segment.sequenceNumber
                    < current.mediaSequenceNumber
            {
                duration += segment.duration - targetDuration
            }
        }
        guard duration.isFinite else {
            throw HLSLiveError.sequenceOverflow
        }
        return duration
    }

    func position(
        advancingBy duration: TimeInterval,
        targetDuration: TimeInterval,
        partTargetDuration: TimeInterval
    ) throws -> (mediaSequenceNumber: Int64, partIndex: Int) {
        let rawPartsPerSegment =
            (targetDuration / partTargetDuration).rounded(.up)
        let rawAdditionalPartCount =
            (duration / partTargetDuration).rounded(.up)
        guard
            rawPartsPerSegment.isFinite,
            rawPartsPerSegment >= 1,
            rawPartsPerSegment < TimeInterval(Int.max),
            rawAdditionalPartCount.isFinite,
            rawAdditionalPartCount >= 1,
            rawAdditionalPartCount < TimeInterval(Int.max)
        else {
            throw HLSLiveError.sequenceOverflow
        }
        let partsPerSegment = Int(rawPartsPerSegment)
        let additionalPartCount = Int(rawAdditionalPartCount)
        let (lastPartOffset, countOverflow) =
            additionalPartCount.subtractingReportingOverflow(1)
        let (absolutePartIndex, indexOverflow) =
            partBoundaryIndex.addingReportingOverflow(lastPartOffset)
        guard !countOverflow, !indexOverflow else {
            throw HLSLiveError.sequenceOverflow
        }
        let sequenceOffset = absolutePartIndex / partsPerSegment
        guard let sequenceOffset64 = Int64(exactly: sequenceOffset) else {
            throw HLSLiveError.sequenceOverflow
        }
        let (targetSequence, sequenceOverflow) =
            mediaSequenceNumber.addingReportingOverflow(sequenceOffset64)
        guard !sequenceOverflow else {
            throw HLSLiveError.sequenceOverflow
        }
        return (
            mediaSequenceNumber: targetSequence,
            partIndex: absolutePartIndex % partsPerSegment
        )
    }
}
