import Foundation
import InnoNetworkHLS

struct HLSLiveDVRRecordingState {
    let configuration: HLSLiveDVRConfiguration
    let workspace: HLSLiveDVRWorkspace

    private(set) var container: HLSMediaContainer?
    private(set) var initializationSegment: HLSLiveInitializationSegment?
    private(set) var initializationFileName: String?
    private(set) var segments: [HLSLiveDVRStoredSegment] = []
    private(set) var recordedDuration: TimeInterval = 0
    private(set) var mediaByteCount: Int64 = 0
    private(set) var lastObservedSequence: Int64?
    private(set) var didObserveInitialSnapshot = false
    private(set) var nextResourceIndex = 0
    private(set) var selectedVariant: HLSVariant?
    private(set) var selectedRenditions: [HLSLiveDVRSelectedRendition] = []
    private(set) var inBandClosedCaptions: [HLSRendition] = []
    private(set) var renditionStates: [HLSLiveDVRRenditionRecordingState] = []
    private(set) var dateRanges: [HLSDateRange] = []
    private var partState: HLSLiveDVRPartRecordingState
    private var didConfigureRenditions = false
    private var initialPathwayID: String?

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
            promotedPartCount: partState.promotedPartCount
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
        promotion: HLSLiveDVRPartPromotion
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

    mutating func renditionRequests(
        in snapshot: HLSLivePlaylistSnapshot
    ) throws -> [HLSLiveDVRRenditionRequest] {
        try selectedRenditions.enumerated().map { index, selection in
            let rendition = try selection.source(
                in: snapshot,
                initialPathwayID: initialPathwayID
            )
            guard let url = rendition.url else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .incompleteExternalRendition
                )
            }
            return HLSLiveDVRRenditionRequest(
                index: index,
                url: url,
                multivariantVariables:
                    snapshot.multivariantVariables,
                generation: snapshot.generation
            )
        }
    }

    mutating func validateRendition(
        _ snapshot: HLSLivePlaylistSnapshot,
        at index: Int
    ) throws {
        guard renditionStates.indices.contains(index) else {
            throw HLSLiveDVRError.storageFailed
        }
        try validateTimeline(snapshot, isPrimary: false)
        try renditionStates[index].validatePresentation(snapshot)
    }

    mutating func renditionCandidates(
        in snapshot: HLSLivePlaylistSnapshot,
        at index: Int
    ) throws -> [HLSLiveSegment] {
        guard renditionStates.indices.contains(index) else {
            throw HLSLiveDVRError.storageFailed
        }
        return try renditionStates[index].candidates(
            in: snapshot,
            startPosition: configuration.startPosition
        )
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
        byteCount: Int64
    ) throws {
        try addMediaBytes(byteCount)
        initializationFileName = fileName
        nextResourceIndex += 1
    }

    mutating func retain(
        _ segment: HLSLiveSegment,
        fileName: String,
        byteCount: Int64
    ) throws {
        let nextDuration = recordedDuration + segment.duration
        guard nextDuration.isFinite else {
            throw HLSLiveDVRError.storageFailed
        }
        try addMediaBytes(byteCount)
        append(
            segment,
            fileName: fileName,
            nextDuration: nextDuration
        )
        nextResourceIndex += 1
    }

    func canRetainRendition(
        _ segment: HLSLiveSegment,
        at index: Int
    ) -> Bool {
        guard renditionStates.indices.contains(index) else {
            return false
        }
        return renditionStates[index].canRetain(
            segment,
            limits: configuration.limits
        )
    }

    func validateRenditionSegment(
        _ segment: HLSLiveSegment,
        at index: Int
    ) throws {
        guard renditionStates.indices.contains(index) else {
            throw HLSLiveDVRError.storageFailed
        }
        try renditionStates[index].validate(segment)
    }

    func renditionContainer(
        at index: Int
    ) throws -> HLSMediaContainer {
        guard
            renditionStates.indices.contains(index),
            let container = renditionStates[index].container
        else {
            throw HLSLiveDVRError.unsupportedFeature(
                .unknownMediaContainer
            )
        }
        return container
    }

    func renditionInitializationSegment(
        at index: Int
    ) -> HLSLiveInitializationSegment? {
        guard renditionStates.indices.contains(index) else {
            return nil
        }
        return renditionStates[index].initializationSegment
    }

    func renditionInitializationFileName(
        at index: Int
    ) -> String? {
        guard renditionStates.indices.contains(index) else {
            return nil
        }
        return renditionStates[index].initializationFileName
    }

    func renditionSegmentCount(at index: Int) -> Int {
        guard renditionStates.indices.contains(index) else {
            return 0
        }
        return renditionStates[index].segments.count
    }

    func renditionDirectoryPath(
        at index: Int
    ) throws -> String {
        guard selectedRenditions.indices.contains(index) else {
            throw HLSLiveDVRError.storageFailed
        }
        return selectedRenditions[index].relativeDirectoryPath
    }

    mutating func retainRenditionInitialization(
        at index: Int,
        fileName: String,
        byteCount: Int64
    ) throws {
        guard renditionStates.indices.contains(index) else {
            throw HLSLiveDVRError.storageFailed
        }
        try addMediaBytes(byteCount)
        renditionStates[index].initializationFileName = fileName
        nextResourceIndex += 1
    }

    mutating func retainRendition(
        _ segment: HLSLiveSegment,
        at index: Int,
        fileName: String,
        byteCount: Int64
    ) throws {
        guard renditionStates.indices.contains(index) else {
            throw HLSLiveDVRError.storageFailed
        }
        try addMediaBytes(byteCount)
        try renditionStates[index].retain(
            segment,
            fileName: fileName
        )
        nextResourceIndex += 1
    }

    private mutating func addMediaBytes(
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

    private mutating func append(
        _ segment: HLSLiveSegment,
        fileName: String,
        nextDuration: TimeInterval
    ) {
        segments.append(
            HLSLiveDVRStoredSegment(
                sequenceNumber: segment.sequenceNumber,
                duration: segment.duration,
                beginsDiscontinuity:
                    segment.beginsDiscontinuity,
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

    private func validateTimeline(
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
