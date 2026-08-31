import Foundation
import InnoNetworkHLS

extension HLSLiveDVRRecordingState {
    mutating func validatePresentation(
        _ snapshot: HLSLivePlaylistSnapshot
    ) throws {
        if !didConfigureRenditions {
            let selection = try HLSLiveDVRRenditionSelector.select(
                from: snapshot,
                pack: configuration.renditions
            )
            selectedVariant = snapshot.selectedVariant
            selectedRenditions = selection.external
            inBandClosedCaptions = selection.inBandClosedCaptions
            renditionStates = selection.external.map {
                HLSLiveDVRRenditionRecordingState(selection: $0)
            }
            initialPathwayID = snapshot.pathwayID
            didConfigureRenditions = true
        } else {
            inBandClosedCaptions =
                HLSLiveDVRRenditionSelector.retainedClosedCaptions(
                    inBandClosedCaptions,
                    in: snapshot,
                    initialPathwayID: initialPathwayID
                )
        }
        try validateTimeline(snapshot, isPrimary: true)
        mergeDateRanges(snapshot.dateRanges)

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
            throw HLSLiveDVRError.unsupportedFeature(
                .encryptedMedia
            )
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
        in snapshot: HLSLivePlaylistSnapshot
    ) throws -> [HLSLiveSegment] {
        try validateSequence(snapshot.segments)
        if !didObserveInitialSnapshot {
            didObserveInitialSnapshot = true
            if configuration.startPosition
                == .nextCompletedSegment
            {
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
                guard
                    !overflow,
                    first.sequenceNumber == expected
                else {
                    throw HLSLiveDVRError.liveWindowAdvanced
                }
            }
        } else {
            candidates = snapshot.segments
        }
        return candidates
    }

    func canRetain(_ segment: HLSLiveSegment) -> Bool {
        guard
            segments.count
                < configuration.limits.maximumSegmentCount
        else {
            return false
        }
        let nextDuration = recordedDuration + segment.duration
        return nextDuration.isFinite
            && nextDuration
                <= configuration.limits.maximumDuration
    }

    func validate(_ segment: HLSLiveSegment) throws {
        guard segment.duration.isFinite, segment.duration > 0 else {
            throw HLSLiveDVRError.transferFailed
        }
        guard !segment.isGap else {
            throw HLSLiveDVRError.unsupportedFeature(.gap)
        }
    }

    mutating func retainInitialization(
        fileName: String,
        byteCount: Int64,
        contentSHA256: String
    ) throws {
        try addMediaBytes(byteCount)
        initializationFileName = fileName
        initializationByteCount = byteCount
        initializationContentSHA256 = contentSHA256
        nextResourceIndex += 1
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
        try addMediaBytes(byteCount)
        append(
            segment,
            fileName: fileName,
            byteCount: byteCount,
            contentSHA256: contentSHA256,
            nextDuration: nextDuration
        )
        nextResourceIndex += 1
    }

    private func validateSequence(
        _ segments: [HLSLiveSegment]
    ) throws {
        var previous: Int64?
        for segment in segments {
            if let previous {
                let (expected, overflow) =
                    previous.addingReportingOverflow(1)
                guard
                    !overflow,
                    segment.sequenceNumber == expected
                else {
                    throw HLSLiveDVRError.liveWindowAdvanced
                }
            }
            previous = segment.sequenceNumber
        }
    }

    func validateTimeline(
        _ snapshot: HLSLivePlaylistSnapshot,
        isPrimary: Bool
    ) throws {
        if snapshot.dateRanges.contains(where: {
            $0.interstitial != nil
                || $0.externalResource != nil
                || $0.preload != nil
        }) {
            throw HLSLiveDVRError.unsupportedFeature(
                .externalTimelineResource
            )
        }
        if snapshot.dateRanges.contains(where: {
            !$0.extensionAttributeNames.isEmpty
        }) {
            throw HLSLiveDVRError.unsupportedFeature(
                .unrepresentableTimelineMetadata
            )
        }
        if !isPrimary, !snapshot.dateRanges.isEmpty {
            throw HLSLiveDVRError.unsupportedFeature(
                .unrepresentableTimelineMetadata
            )
        }
    }

    private mutating func mergeDateRanges(
        _ updates: [HLSDateRange]
    ) {
        for update in updates {
            if let index = dateRanges.firstIndex(where: {
                $0.id == update.id
            }) {
                dateRanges[index] = update
            } else {
                dateRanges.append(update)
            }
        }
    }

}
