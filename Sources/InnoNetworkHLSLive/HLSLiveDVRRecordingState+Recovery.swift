import Foundation
import InnoNetworkHLS

extension HLSLiveDVRRecordingState {
    func checkpoint(
        sourceURL: URL
    ) throws -> HLSLiveDVRCheckpoint {
        guard
            let primary = checkpointTrack(
                container: container,
                initializationState: initializationState,
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

        let restoredInitializations = try Self.validatedInitializations(
            checkpoint.primary,
            container: primaryContainer
        )
        let legacyInitialization =
            checkpoint.primary.initializations == nil
            ? checkpoint.primary.resolvedInitializations.first
            : nil
        let restoredSegments = try checkpoint.primary.segments.map {
            try $0.storedSegment(
                defaultInitialization: legacyInitialization
            )
        }
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
            guard
                restoredSegments.allSatisfy({
                    $0.initializationSourceIdentity == nil
                        && $0.initializationFileName == nil
                })
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            guard snapshot.initializationSegments.isEmpty else {
                throw HLSLiveDVRError.recoveryMismatch
            }
        case .fragmentedMP4:
            guard !restoredInitializations.isEmpty,
                restoredSegments.allSatisfy({ segment in
                    guard
                        let sourceIdentity =
                            segment.initializationSourceIdentity,
                        let fileName = segment.initializationFileName
                    else {
                        return false
                    }
                    return restoredInitializations.contains {
                        $0.sourceIdentity == sourceIdentity
                            && $0.fileName == fileName
                    }
                })
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            guard
                Self.matchesOverlappingInitializations(
                    restoredSegments,
                    snapshot: snapshot
                )
            else {
                throw HLSLiveDVRError.recoveryMismatch
            }
        }
        guard
            Self.matchesOverlappingGaps(
                restoredSegments,
                snapshot: snapshot
            )
        else {
            throw HLSLiveDVRError.recoveryMismatch
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
        initializationState = HLSLiveDVRInitializationRecordingState(
            records: restoredInitializations
        )
        segments = restoredSegments
        recordedDuration = restoredDuration
        mediaByteCount = restoredMediaBytes
        gapCount = restoredSegments.count(where: \.isGap)
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
        initializationState: HLSLiveDVRInitializationRecordingState,
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
        let initializations = initializationState.records.map {
            HLSLiveDVRCheckpoint.Initialization($0)
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
            segments: segments.map {
                HLSLiveDVRCheckpoint.Segment($0)
            }
        )
    }

    static func validatedInitializations(
        _ track: HLSLiveDVRCheckpoint.Track,
        container: HLSMediaContainer
    ) throws -> [HLSLiveDVRStoredInitialization] {
        let initializations = track.resolvedInitializations.map(
            \.storedInitialization
        )
        let identities = Set(initializations.map(\.sourceIdentity))
        let paths = Set(initializations.map(\.fileName))
        guard identities.count == initializations.count,
            paths.count == initializations.count,
            initializations.allSatisfy({
                $0.sourceIdentity.count == 64
                    && $0.sourceIdentity.allSatisfy(\.isHexDigit)
            })
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        switch container {
        case .mpegTransportStream:
            guard initializations.isEmpty else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
        case .fragmentedMP4:
            guard !initializations.isEmpty else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
        }
        return initializations
    }

    static func matchesOverlappingInitializations(
        _ restoredSegments: [HLSLiveDVRStoredSegment],
        snapshot: HLSLivePlaylistSnapshot
    ) -> Bool {
        let restoredBySequence = Dictionary(
            uniqueKeysWithValues: restoredSegments.map {
                ($0.sequenceNumber, $0)
            }
        )
        return snapshot.segments.allSatisfy { segment in
            guard
                let restored = restoredBySequence[
                    segment.sequenceNumber
                ]
            else {
                return true
            }
            return segment.initializationSegment.map(
                HLSLiveDVRRecoveryIdentity
                    .initializationSegmentIdentity
            ) == restored.initializationSourceIdentity
        }
    }

    static func matchesOverlappingGaps(
        _ restoredSegments: [HLSLiveDVRStoredSegment],
        snapshot: HLSLivePlaylistSnapshot
    ) -> Bool {
        let restoredBySequence = Dictionary(
            uniqueKeysWithValues: restoredSegments.map {
                ($0.sequenceNumber, $0)
            }
        )
        return snapshot.segments.allSatisfy { segment in
            guard
                let restored = restoredBySequence[
                    segment.sequenceNumber
                ]
            else {
                return true
            }
            return segment.isGap == restored.isGap
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
        let initializations = track.resolvedInitializations
        let initializationPairs = Set(
            initializations.map {
                $0.sourceIdentity + "\u{0}" + $0.playlistPath
            }
        )
        let initializationsAreValid =
            initializationPairs.count == initializations.count
            && initializations.allSatisfy { initialization in
                storagePath(
                    for: initialization.playlistPath,
                    prefix: storagePrefix
                ) == initialization.file.relativePath
            }
        let segmentPlaylistPaths = track.segments.map(\.playlistPath)
        let segmentPlaylistPathsAreUnique =
            Set(segmentPlaylistPaths).count
            == segmentPlaylistPaths.count
        let firstInitialization = initializations.first
        let legacyFileIsValid: Bool
        switch (track.initialization, firstInitialization?.file) {
        case (nil, nil):
            legacyFileIsValid = true
        case (let legacy?, let first?):
            legacyFileIsValid =
                legacy.relativePath == first.relativePath
                && legacy.byteCount == first.byteCount
                && legacy.contentSHA256 == first.contentSHA256
        default:
            legacyFileIsValid = false
        }
        let legacyInitializationIsValid =
            track.initializationPlaylistPath
            == firstInitialization?.playlistPath
            && track.initializationSourceIdentity
                == firstInitialization?.sourceIdentity
            && legacyFileIsValid
        guard initializationsAreValid,
            legacyInitializationIsValid,
            segmentPlaylistPathsAreUnique,
            track.segments.allSatisfy({ segment in
                let mediaPathIsValid =
                    switch (segment.isGap ?? false, segment.file) {
                    case (false, let file?):
                        storagePath(
                            for: segment.playlistPath,
                            prefix: storagePrefix
                        ) == file.relativePath
                    case (true, nil):
                        storagePath(
                            for: segment.playlistPath,
                            prefix: storagePrefix
                        ) != nil
                    default:
                        false
                    }
                let initializationIsValid: Bool
                switch (
                    segment.initializationSourceIdentity,
                    segment.initializationPlaylistPath
                ) {
                case (nil, nil):
                    initializationIsValid =
                        track.initializations == nil
                        || initializations.isEmpty
                case (let identity?, let path?):
                    initializationIsValid =
                        initializationPairs.contains(
                            identity + "\u{0}" + path
                        )
                default:
                    initializationIsValid = false
                }
                return mediaPathIsValid && initializationIsValid
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
