import Foundation
import InnoNetworkHLS

struct HLSLiveDVRRecordingState {
    let configuration: HLSLiveDVRConfiguration
    let workspace: HLSLiveDVRWorkspace

    private(set) var container: HLSMediaContainer?
    private(set) var initializationSegment: HLSLiveInitializationSegment?
    private(set) var initializationFileName: String?
    private(set) var initializationByteCount: Int64?
    private(set) var initializationContentSHA256: String?
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
        byteCount: Int64,
        contentSHA256: String
    ) throws {
        guard renditionStates.indices.contains(index) else {
            throw HLSLiveDVRError.storageFailed
        }
        try addMediaBytes(byteCount)
        renditionStates[index].initializationFileName = fileName
        renditionStates[index].initializationByteCount = byteCount
        renditionStates[index].initializationContentSHA256 = contentSHA256
        nextResourceIndex += 1
    }

    mutating func retainRendition(
        _ segment: HLSLiveSegment,
        at index: Int,
        fileName: String,
        byteCount: Int64,
        contentSHA256: String
    ) throws {
        guard renditionStates.indices.contains(index) else {
            throw HLSLiveDVRError.storageFailed
        }
        try addMediaBytes(byteCount)
        try renditionStates[index].retain(
            segment,
            fileName: fileName,
            byteCount: byteCount,
            contentSHA256: contentSHA256
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

    func checkpoint(
        sourceURL: URL
    ) throws -> HLSLiveDVRCheckpoint {
        guard
            let primary = checkpointTrack(
                container: container,
                initializationSegment: initializationSegment,
                initializationFileName: initializationFileName,
                initializationByteCount: initializationByteCount,
                initializationContentSHA256:
                    initializationContentSHA256,
                segments: segments
            ), !segments.isEmpty
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        let renditionCheckpoints = try renditionStates.map { state in
            guard let track = state.checkpointTrack else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            return HLSLiveDVRCheckpoint.Rendition(
                identity:
                    state.selection.rendition
                    .liveDVRCheckpointIdentity,
                track: track
            )
        }
        return HLSLiveDVRCheckpoint(
            schemaVersion: HLSLiveDVRCheckpoint.schemaVersion,
            sourceURLSHA256:
                HLSLiveDVRRecoveryIdentity.sourceURLSHA256(
                    sourceURL
                ),
            variantIdentity:
                selectedVariant?.liveDVRCheckpointIdentity,
            primary: primary,
            renditions: renditionCheckpoints,
            inBandClosedCaptionIdentities:
                inBandClosedCaptions.map(\.liveDVRCheckpointIdentity),
            dateRanges: dateRanges.map(
                HLSLiveDVRCheckpoint.DateRange.init
            ),
            promotedPartCount: promotedPartCount
        )
    }

    mutating func restore(
        _ checkpoint: HLSLiveDVRCheckpoint,
        in snapshot: HLSLivePlaylistSnapshot
    ) throws {
        guard checkpoint.promotedPartCount >= 0,
            checkpoint.primary.segments.count
                <= configuration.limits.maximumSegmentCount,
            checkpoint.dateRanges.count <= 10_000,
            checkpoint.variantIdentity
                == snapshot.selectedVariant?
                .liveDVRCheckpointIdentity,
            let primaryContainer = checkpoint.primary.mediaContainer
        else {
            throw HLSLiveDVRError.recoveryMismatch
        }
        let selection = try HLSLiveDVRRenditionSelector.select(
            from: snapshot,
            pack: configuration.renditions
        )
        guard selection.external.count == checkpoint.renditions.count,
            zip(selection.external, checkpoint.renditions)
                .allSatisfy({ selected, persisted in
                    selected.rendition.liveDVRCheckpointIdentity
                        == persisted.identity
                }),
            selection.inBandClosedCaptions.map(
                \.liveDVRCheckpointIdentity
            ) == checkpoint.inBandClosedCaptionIdentities
        else {
            throw HLSLiveDVRError.recoveryMismatch
        }

        let restoredSegments = checkpoint.primary.segments.map(
            \.storedSegment
        )
        let restoredDuration = try Self.validatedDuration(
            restoredSegments
        )
        guard !restoredSegments.isEmpty,
            restoredDuration <= configuration.limits.maximumDuration
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        switch primaryContainer {
        case .mpegTransportStream:
            guard checkpoint.primary.initialization == nil,
                checkpoint.primary.initializationPlaylistPath == nil,
                checkpoint.primary.initializationSourceIdentity == nil
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            guard snapshot.initializationSegments.isEmpty else {
                throw HLSLiveDVRError.recoveryMismatch
            }
        case .fragmentedMP4:
            guard checkpoint.primary.initialization != nil,
                checkpoint.primary.initializationPlaylistPath != nil,
                let expectedIdentity =
                    checkpoint.primary.initializationSourceIdentity
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            guard snapshot.initializationSegments.count == 1,
                let currentInitialization =
                    snapshot.initializationSegments.first,
                HLSLiveDVRRecoveryIdentity
                    .initializationSegmentIdentity(
                        currentInitialization
                    ) == expectedIdentity
            else {
                throw HLSLiveDVRError.recoveryMismatch
            }
        }
        let restoredRenditionStates = try zip(
            selection.external,
            checkpoint.renditions
        ).map { selected, persisted in
            try Self.validateTrackPaths(
                persisted.track,
                storagePrefix: selected.relativeDirectoryPath
            )
            return try HLSLiveDVRRenditionRecordingState(
                selection: selected,
                checkpoint: persisted.track,
                limits: configuration.limits
            )
        }
        let restoredDateRanges = try checkpoint.dateRanges.map { record in
            guard let model = record.model else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            return model
        }
        let restoredMediaBytes = try Self.validatedMediaByteCount(
            checkpoint.files,
            limit: configuration.limits.maximumTotalMediaBytes
        )
        try Self.validateTrackPaths(
            checkpoint.primary,
            storagePrefix: nil
        )

        container = primaryContainer
        initializationSegment = snapshot.initializationSegments.first
        initializationFileName =
            checkpoint.primary.initializationPlaylistPath
        initializationByteCount =
            checkpoint.primary.initialization?.byteCount
        initializationContentSHA256 =
            checkpoint.primary.initialization?.contentSHA256
        segments = restoredSegments
        recordedDuration = restoredDuration
        mediaByteCount = restoredMediaBytes
        lastObservedSequence = restoredSegments.last?.sequenceNumber
        didObserveInitialSnapshot = true
        nextResourceIndex = checkpoint.files.count
        selectedVariant = snapshot.selectedVariant
        selectedRenditions = selection.external
        inBandClosedCaptions = selection.inBandClosedCaptions
        renditionStates = restoredRenditionStates
        dateRanges = restoredDateRanges
        partState = HLSLiveDVRPartRecordingState(
            pack: configuration.parts,
            promotedPartCount: checkpoint.promotedPartCount
        )
        didConfigureRenditions = true
        initialPathwayID = snapshot.pathwayID
    }

    private func checkpointTrack(
        container: HLSMediaContainer?,
        initializationSegment: HLSLiveInitializationSegment?,
        initializationFileName: String?,
        initializationByteCount: Int64?,
        initializationContentSHA256: String?,
        segments: [HLSLiveDVRStoredSegment]
    ) -> HLSLiveDVRCheckpoint.Track? {
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
                ),
            initializationPlaylistPath: initializationFileName,
            initialization: initialization,
            segments: segments.map {
                HLSLiveDVRCheckpoint.Segment($0)
            }
        )
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

    private static func validatedMediaByteCount(
        _ files: [HLSLiveDVRCheckpoint.FileRecord],
        limit: Int64
    ) throws -> Int64 {
        var byteCount: Int64 = 0
        for file in files {
            let (next, overflow) = byteCount.addingReportingOverflow(
                file.byteCount
            )
            guard !overflow, next <= limit else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            byteCount = next
        }
        return byteCount
    }

    private static func validateTrackPaths(
        _ track: HLSLiveDVRCheckpoint.Track,
        storagePrefix: String?
    ) throws {
        let initializationIsValid: Bool
        switch (
            track.initializationPlaylistPath,
            track.initialization
        ) {
        case (nil, nil):
            initializationIsValid = true
        case (let playlistPath?, let file?):
            initializationIsValid =
                storagePath(
                    for: playlistPath,
                    prefix: storagePrefix
                ) == file.relativePath
        default:
            initializationIsValid = false
        }
        guard initializationIsValid,
            track.segments.allSatisfy({ segment in
                storagePath(
                    for: segment.playlistPath,
                    prefix: storagePrefix
                ) == segment.file.relativePath
            })
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
    }

    private static func storagePath(
        for playlistPath: String,
        prefix: String?
    ) -> String? {
        let components = playlistPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
            components[0] == "resources",
            !components[1].isEmpty,
            components[1] != ".",
            components[1] != "..",
            !components[1].contains("\n"),
            !components[1].contains("\r")
        else {
            return nil
        }
        guard let prefix else {
            return playlistPath
        }
        return prefix + "/" + playlistPath
    }
}
