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
        var checkpoint = HLSLiveDVRCheckpoint(
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
            dateRanges: try checkpointDateRanges().map(
                HLSLiveDVRCheckpoint.DateRange.init
            ),
            promotedPartCount: promotedPartCount
        )
        checkpoint.retentionPolicy =
            switch configuration.limits.retentionPolicy {
            case .stopAtLimit:
                "stopAtLimit"
            case .rollingWindow:
                "rollingWindow"
            }
        checkpoint.retentionStatistics =
            HLSLiveDVRCheckpoint.RetentionStatistics(
                retentionStatistics
            )
        checkpoint.interstitialPolicy =
            switch configuration.interstitials.policy {
            case .disabled:
                "disabled"
            case .package:
                "package"
            }
        checkpoint.interstitials = interstitials.map(
            HLSLiveDVRCheckpoint.Interstitial.init
        )
        checkpoint.omittedInterstitials = omittedInterstitials.map(
            HLSLiveDVRCheckpoint.OmittedInterstitial.init
        )
        return checkpoint
    }

    mutating func restore(
        _ checkpoint: HLSLiveDVRCheckpoint,
        in snapshot: HLSLivePlaylistSnapshot
    ) throws {
        let restoredRetentionPolicy: HLSLiveDVRRetentionPolicy
        switch checkpoint.retentionPolicy ?? "stopAtLimit" {
        case "stopAtLimit":
            restoredRetentionPolicy = .stopAtLimit
        case "rollingWindow":
            restoredRetentionPolicy = .rollingWindow
        default:
            throw HLSLiveDVRError.recoveryCorrupted
        }
        guard
            restoredRetentionPolicy
                == configuration.limits.retentionPolicy
        else {
            throw HLSLiveDVRError.recoveryMismatch
        }
        let restoredInterstitialPolicy: HLSLiveDVRInterstitialPolicy
        switch checkpoint.interstitialPolicy ?? "disabled" {
        case "disabled":
            restoredInterstitialPolicy = .disabled
        case "package":
            restoredInterstitialPolicy = .package
        default:
            throw HLSLiveDVRError.recoveryCorrupted
        }
        guard
            restoredInterstitialPolicy
                == configuration.interstitials.policy
        else {
            throw HLSLiveDVRError.recoveryMismatch
        }
        let restoredRetentionStatistics: HLSLiveDVRRetentionStatistics
        if let persisted = checkpoint.retentionStatistics {
            guard let model = persisted.model else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            restoredRetentionStatistics = model
        } else {
            restoredRetentionStatistics = HLSLiveDVRRetentionStatistics()
        }
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
        let restoredInterstitials = try Self.validatedInterstitials(
            checkpoint.interstitials ?? [],
            dateRanges: restoredDateRanges,
            configuration: configuration,
            workspaceDirectoryURL: workspace.directoryURL
        )
        let restoredOmittedInterstitials = try Self.validatedOmissions(
            checkpoint.omittedInterstitials ?? [],
            interstitials: restoredInterstitials,
            maximumEventCount:
                configuration.interstitials.maximumEventCount
        )
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
        interstitials = restoredInterstitials
        omittedInterstitials = restoredOmittedInterstitials
        partState = HLSLiveDVRPartRecordingState(
            pack: configuration.parts,
            promotedPartCount: checkpoint.promotedPartCount
        )
        retentionStatistics = restoredRetentionStatistics
        pendingEvictionFilePaths = []
        didConfigureRenditions = true
        initialPathwayID = snapshot.pathwayID
    }

    private func checkpointDateRanges() throws -> [HLSDateRange] {
        guard !dateRanges.isEmpty else {
            return []
        }
        guard let first = segments.first,
            let last = segments.last,
            let startDate = first.programDateTime,
            let lastStartDate = last.programDateTime
        else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        let endDate = lastStartDate.addingTimeInterval(last.duration)
        guard endDate.timeIntervalSinceReferenceDate.isFinite else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        let omittedIDs = Set(omittedInterstitials.map(\.id))
        return try dateRanges.compactMap { dateRange in
            guard !omittedIDs.contains(dateRange.id) else {
                return nil
            }
            guard dateRange.startDate < endDate else {
                return nil
            }
            let rangeEnd =
                dateRange.endDate
                ?? dateRange.duration.map {
                    dateRange.startDate.addingTimeInterval($0)
                }
            if let rangeEnd, rangeEnd <= startDate {
                return nil
            }
            guard dateRange.interstitial != nil else {
                return dateRange
            }
            guard
                let stored = interstitials.first(where: {
                    $0.id == dateRange.id
                })
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            return stored.dateRange
        }
    }

    private static func validatedInterstitials(
        _ records: [HLSLiveDVRCheckpoint.Interstitial],
        dateRanges: [HLSDateRange],
        configuration: HLSLiveDVRConfiguration,
        workspaceDirectoryURL: URL
    ) throws -> [HLSLiveDVRStoredInterstitial] {
        guard records.count <= configuration.interstitials.maximumEventCount
        else {
            throw HLSLiveDVRError.recoveryMismatch
        }
        var ids: Set<String> = []
        var paths: Set<String> = []
        var totalBytes: Int64 = 0
        var stored: [HLSLiveDVRStoredInterstitial] = []
        for record in records {
            guard ids.insert(record.id).inserted,
                Self.validInterstitialSourceIdentity(record.sourceIdentity),
                record.assetCount > 0,
                record.assetCount
                    <= configuration.interstitials.maximumAssetsPerEvent,
                Self.validInterstitialDirectory(record.eventDirectoryPath),
                let dateRange = dateRanges.first(where: {
                    $0.id == record.id && $0.interstitial != nil
                }),
                try Self.interstitialFilesAreValid(
                    record.files,
                    eventDirectoryPath: record.eventDirectoryPath,
                    occupiedPaths: &paths
                ),
                Self.interstitialSourceIsValid(
                    dateRange.interstitial?.source,
                    isContainedIn: record.eventDirectoryPath,
                    files: record.files,
                    expectedAssetCount: record.assetCount,
                    maximumAssetCount:
                        configuration.interstitials.maximumAssetsPerEvent,
                    workspaceDirectoryURL: workspaceDirectoryURL
                )
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            let byteCount = try validatedMediaByteCount(
                record.files,
                limit: configuration.interstitials.maximumTotalBytes
            )
            let (nextBytes, overflow) = totalBytes.addingReportingOverflow(
                byteCount
            )
            guard !overflow,
                nextBytes <= configuration.interstitials.maximumTotalBytes
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            totalBytes = nextBytes
            stored.append(
                HLSLiveDVRStoredInterstitial(
                    id: record.id,
                    sourceIdentity: record.sourceIdentity,
                    eventDirectoryPath: record.eventDirectoryPath,
                    dateRange: dateRange,
                    assetCount: record.assetCount,
                    files: record.files
                )
            )
        }
        return stored
    }

    private static func validatedOmissions(
        _ records: [HLSLiveDVRCheckpoint.OmittedInterstitial],
        interstitials: [HLSLiveDVRStoredInterstitial],
        maximumEventCount: Int
    ) throws -> [HLSLiveDVROmittedInterstitial] {
        guard records.count + interstitials.count <= maximumEventCount else {
            throw HLSLiveDVRError.recoveryMismatch
        }
        var ids = Set(interstitials.map(\.id))
        return try records.map { record in
            guard ids.insert(record.id).inserted,
                validInterstitialSourceIdentity(record.sourceIdentity)
            else {
                throw HLSLiveDVRError.recoveryCorrupted
            }
            return HLSLiveDVROmittedInterstitial(
                id: record.id,
                sourceIdentity: record.sourceIdentity
            )
        }
    }

    private static func validInterstitialSourceIdentity(
        _ identity: String
    ) -> Bool {
        let prefix: String
        if identity.hasPrefix("asset:") {
            prefix = "asset:"
        } else if identity.hasPrefix("assetList:") {
            prefix = "assetList:"
        } else {
            return false
        }
        let digest = identity.dropFirst(prefix.count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }

    private static func validInterstitialDirectory(_ path: String) -> Bool {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
            components[0] == "interstitials",
            components[1].hasPrefix("event-")
        else {
            return false
        }
        let digest = components[1].dropFirst("event-".count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }

    private static func interstitialFilesAreValid(
        _ files: [HLSLiveDVRCheckpoint.FileRecord],
        eventDirectoryPath: String,
        occupiedPaths: inout Set<String>
    ) throws -> Bool {
        guard !files.isEmpty else {
            return false
        }
        let prefix = eventDirectoryPath + "/"
        for file in files {
            guard file.relativePath.hasPrefix(prefix),
                occupiedPaths.insert(file.relativePath).inserted,
                file.byteCount > 0,
                file.contentSHA256.count == 64,
                file.contentSHA256.allSatisfy(\.isHexDigit)
            else {
                return false
            }
        }
        return true
    }

    private static func interstitialSourceIsValid(
        _ source: HLSInterstitialSource?,
        isContainedIn eventDirectoryPath: String,
        files: [HLSLiveDVRCheckpoint.FileRecord],
        expectedAssetCount: Int,
        maximumAssetCount: Int,
        workspaceDirectoryURL: URL
    ) -> Bool {
        let url: URL
        switch source {
        case .assetList(let sourceURL):
            url = sourceURL
        case .asset, nil:
            return false
        }
        let path = url.relativeString
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let eventComponents = eventDirectoryPath.split(separator: "/")
        guard components.count >= 3,
            Array(components.prefix(2)) == eventComponents,
            components.allSatisfy({ encoded in
                guard
                    let decoded = String(encoded).removingPercentEncoding
                else {
                    return false
                }
                return !decoded.isEmpty
                    && decoded != "."
                    && decoded != ".."
                    && !decoded.contains("/")
                    && !decoded.contains("\\")
                    && !decoded.unicodeScalars.contains(where: {
                        CharacterSet.controlCharacters.contains($0)
                    })
            }),
            let file = files.first(where: { $0.relativePath == path }),
            file.byteCount > 0,
            file.byteCount <= 2 * 1_024 * 1_024
        else {
            return false
        }
        let directoryURL = workspaceDirectoryURL.standardizedFileURL
        let sourceURL = directoryURL.appendingPathComponent(path)
            .standardizedFileURL
        let prefix =
            directoryURL.path.hasSuffix("/")
            ? directoryURL.path : directoryURL.path + "/"
        guard sourceURL.path.hasPrefix(prefix),
            let values = try? sourceURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            ),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            values.fileSize == Int(file.byteCount),
            let data = try? Data(contentsOf: sourceURL),
            data.count == Int(file.byteCount),
            let references =
                try? HLSInterstitialAssetListDecoder
                .decodeLocalAssetReferences(
                    data,
                    maximumAssetCount: maximumAssetCount
                )
        else {
            return false
        }
        return references.count == expectedAssetCount
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
