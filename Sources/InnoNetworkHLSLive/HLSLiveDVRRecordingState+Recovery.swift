import Foundation
import InnoNetworkHLS

extension HLSLiveDVRRecordingState {
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
