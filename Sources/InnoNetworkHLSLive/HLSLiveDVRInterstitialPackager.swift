import Foundation
import InnoNetworkHLS

struct HLSLiveDVRInterstitialPackager: Sendable {
    private let client: HLSHTTPClient
    private let configuration: HLSLiveDVRConfiguration
    private let resolver: HLSExternalResourceResolver

    init(
        client: HLSHTTPClient,
        configuration: HLSLiveDVRConfiguration
    ) {
        self.client = client
        self.configuration = configuration
        self.resolver = HLSExternalResourceResolver(
            client: client,
            configuration: HLSExternalResourcePack(
                maximumInterstitialAssetCount:
                    configuration.interstitials.maximumAssetsPerEvent,
                requestTimeout: configuration.limits.requestTimeout
            )
        )
    }

    func update(
        from snapshot: HLSLivePlaylistSnapshot,
        state: inout HLSLiveDVRRecordingState
    ) async throws {
        guard configuration.interstitials.policy == .package else {
            return
        }
        for dateRange in snapshot.dateRanges {
            guard let interstitial = dateRange.interstitial else {
                continue
            }
            guard
                !Self.isAfterObservedWindow(
                    dateRange,
                    snapshot: snapshot
                )
            else {
                continue
            }
            if Self.isBeforeRecordingWindow(
                dateRange,
                snapshot: snapshot,
                state: state
            ) {
                state.discardInterstitialDateRange(id: dateRange.id)
                continue
            }
            let sourceIdentity = Self.sourceIdentity(interstitial.source)
            if let stored = state.interstitials.first(where: {
                $0.id == dateRange.id
            }) {
                guard stored.sourceIdentity == sourceIdentity,
                    let localInterstitial = stored.dateRange.interstitial
                else {
                    throw HLSLiveDVRError.interstitialPackagingFailed
                }
                try state.updateInterstitialDateRange(
                    id: dateRange.id,
                    dateRange: Self.localDateRange(
                        dateRange,
                        source: localInterstitial.source,
                        skipControl: localInterstitial.skipControl
                    )
                )
                continue
            }
            if let omitted = state.omittedInterstitials.first(where: {
                $0.id == dateRange.id
            }) {
                guard omitted.sourceIdentity == sourceIdentity else {
                    try handleFailure(
                        id: dateRange.id,
                        sourceIdentity: sourceIdentity,
                        state: &state
                    )
                    continue
                }
                continue
            }
            let observedEventCount =
                state.interstitials.count
                + state.omittedInterstitials.count
            guard
                observedEventCount
                    < configuration.interstitials.maximumEventCount
            else {
                throw HLSLiveDVRError.interstitialEventLimitExceeded(
                    limit: configuration.interstitials.maximumEventCount
                )
            }
            do {
                let stored = try await package(
                    dateRange: dateRange,
                    interstitial: interstitial,
                    sourceIdentity: sourceIdentity,
                    state: state
                )
                try state.retainInterstitial(stored)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HLSLiveDVRError {
                try handleFailure(
                    id: dateRange.id,
                    sourceIdentity: sourceIdentity,
                    error: error,
                    state: &state
                )
            } catch let error as HLSDownloadError {
                try handleFailure(
                    id: dateRange.id,
                    sourceIdentity: sourceIdentity,
                    error: Self.liveDVRError(for: error),
                    state: &state
                )
            } catch {
                try handleFailure(
                    id: dateRange.id,
                    sourceIdentity: sourceIdentity,
                    state: &state
                )
            }
        }
    }

    private func package(
        dateRange: HLSDateRange,
        interstitial: HLSInterstitial,
        sourceIdentity: String,
        state: HLSLiveDVRRecordingState
    ) async throws -> HLSLiveDVRStoredInterstitial {
        let resolution = try await resolver.resolveInterstitial(interstitial)
        guard !resolution.assets.isEmpty,
            resolution.assets.count
                <= configuration.interstitials.maximumAssetsPerEvent
        else {
            throw HLSLiveDVRError.interstitialPackagingFailed
        }
        let eventName =
            "event-"
            + HLSContentFingerprint.sha256(
                dateRange.id + "\u{1f}" + sourceIdentity
            )
        let eventRelativePath = "interstitials/" + eventName
        let finalEventURL = state.workspace.directoryURL
            .appendingPathComponent(eventRelativePath, isDirectory: true)
        guard !HLSLiveDVRFileSystem.itemExists(at: finalEventURL) else {
            throw HLSLiveDVRError.storageFailed
        }
        let parentURL = finalEventURL.deletingLastPathComponent()
        let stagedEventURL = parentURL.appendingPathComponent(
            ".\(eventName).\(UUID().uuidString).staging",
            isDirectory: true
        )
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: stagedEventURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: stagedEventURL)
            }
        }

        var localAssets: [(path: String, duration: TimeInterval?)] = []
        var stagedByteCount: Int64 = 0
        for (index, asset) in resolution.assets.enumerated() {
            try Task.checkCancellation()
            let remainingBytes = try availableBytes(
                state: state,
                stagedByteCount: stagedByteCount
            )
            let assetName = String(format: "asset-%05d", index)
            let destinationURL = stagedEventURL.appendingPathComponent(
                assetName,
                isDirectory: true
            )
            let downloader = HLSOfflinePackageDownloader(
                client: client,
                configuration: .advanced(
                    storage: HLSOfflinePackageStoragePack(
                        maximumMediaResourceBytes:
                            configuration.interstitials
                            .maximumMediaResourceBytes,
                        maximumTotalDownloadBytes: remainingBytes,
                        diskCapacityPolicy:
                            configuration.limits.diskCapacityPolicy,
                        resumePolicy: .disabled
                    ),
                    variantSelectionPolicy:
                        configuration.interstitials
                        .variantSelectionPolicy,
                    renditions: configuration.interstitials.renditions,
                    transfer: configuration.interstitials.transfer
                )
            )
            let receipt = try await downloader.downloadPackage(
                sourceURL: asset.url,
                destinationDirectoryURL: destinationURL
            )
            let (nextStagedBytes, stagedOverflow) =
                stagedByteCount.addingReportingOverflow(receipt.byteCount)
            let eventByteLimit = try availableBytes(state: state)
            guard !stagedOverflow,
                nextStagedBytes <= eventByteLimit
            else {
                throw HLSLiveDVRError.interstitialStorageLimitReached
            }
            stagedByteCount = nextStagedBytes
            let entryPath = try Self.relativePath(
                of: receipt.entryPlaylistURL,
                in: stagedEventURL
            )
            localAssets.append(
                (
                    entryPath,
                    try asset.duration
                        ?? receipt.primaryPlaybackDuration()
                )
            )
        }

        let lockDirectoryURL = stagedEventURL.appendingPathComponent(
            ".innonetwork-hls-locks",
            isDirectory: true
        )
        if HLSLiveDVRFileSystem.itemExists(at: lockDirectoryURL) {
            do {
                try fileManager.removeItem(at: lockDirectoryURL)
            } catch {
                throw HLSLiveDVRError.storageFailed
            }
        }

        let listName = "assets.json"
        let listURL = stagedEventURL.appendingPathComponent(listName)
        let data = try Self.assetListData(localAssets)
        do {
            try data.write(to: listURL, options: .atomic)
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
        guard
            let localListURL = URL(
                string: eventRelativePath + "/" + listName
            )
        else {
            throw HLSLiveDVRError.storageFailed
        }
        let localSource = HLSInterstitialSource.assetList(localListURL)
        let records: [HLSLiveDVRCheckpoint.FileRecord]
        do {
            records = try Self.fileRecords(
                in: stagedEventURL,
                finalRelativePath: eventRelativePath
            )
        } catch let error as HLSLiveDVRError {
            throw error
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
        let stored = HLSLiveDVRStoredInterstitial(
            id: dateRange.id,
            sourceIdentity: sourceIdentity,
            eventDirectoryPath: eventRelativePath,
            dateRange: Self.localDateRange(
                dateRange,
                source: localSource,
                skipControl: resolution.skipControl
            ),
            assetCount: localAssets.count,
            files: records
        )
        let retainedPlaylistCount = state.interstitials.reduce(0) {
            $0 + $1.playlistCount
        }
        let (nextPlaylistCount, playlistOverflow) =
            retainedPlaylistCount.addingReportingOverflow(
                stored.playlistCount
            )
        guard !playlistOverflow,
            nextPlaylistCount
                <= configuration.interstitials.maximumPlaylistCount
        else {
            throw HLSLiveDVRError.interstitialPlaylistLimitExceeded(
                limit: configuration.interstitials.maximumPlaylistCount
            )
        }
        let retainedBytes = state.interstitialStatistics.retainedByteCount
        let (nextBytes, overflow) = retainedBytes.addingReportingOverflow(
            stored.byteCount
        )
        let finalAvailableBytes = try availableBytes(state: state)
        guard !overflow,
            nextBytes <= configuration.interstitials.maximumTotalBytes,
            stored.byteCount <= finalAvailableBytes
        else {
            throw HLSLiveDVRError.interstitialStorageLimitReached
        }
        do {
            try fileManager.moveItem(
                at: stagedEventURL,
                to: finalEventURL
            )
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
        committed = true
        return stored
    }

    private func availableBytes(
        state: HLSLiveDVRRecordingState,
        stagedByteCount: Int64 = 0
    ) throws -> Int64 {
        let interstitialRemaining = max(
            0,
            configuration.interstitials.maximumTotalBytes
                - state.interstitialStatistics.retainedByteCount
        )
        let recordingRemaining: Int64
        let primaryReserve = min(
            Int64(configuration.limits.maximumMediaResourceBytes),
            configuration.limits.maximumTotalMediaBytes
        )
        let stagedPartBytes = state.partState.stagedPartByteCount
        if configuration.limits.retentionPolicy == .rollingWindow {
            recordingRemaining = max(
                0,
                configuration.limits.maximumTotalMediaBytes
                    - state.interstitialStatistics.retainedByteCount
                    - stagedPartBytes
                    - primaryReserve
            )
        } else {
            recordingRemaining = max(
                0,
                configuration.limits.maximumTotalMediaBytes
                    - state.mediaByteCount
                    - stagedPartBytes
                    - primaryReserve
            )
        }
        let available =
            min(interstitialRemaining, recordingRemaining)
            - stagedByteCount
        guard available > 0 else {
            throw HLSLiveDVRError.interstitialStorageLimitReached
        }
        return available
    }

    private func handleFailure(
        id: String,
        sourceIdentity: String,
        error: HLSLiveDVRError? = nil,
        state: inout HLSLiveDVRRecordingState
    ) throws {
        let resolvedError =
            error ?? HLSLiveDVRError.interstitialPackagingFailed
        switch configuration.interstitials.failurePolicy {
        case .failRecording:
            throw resolvedError
        case .omitEvent:
            guard Self.isOmittable(resolvedError) else {
                throw resolvedError
            }
            state.omitInterstitial(
                id: id,
                sourceIdentity: sourceIdentity
            )
        }
    }

    private static func isOmittable(_ error: HLSLiveDVRError) -> Bool {
        switch error {
        case .interstitialPackagingFailed,
            .interstitialPlaylistLimitExceeded,
            .interstitialStorageLimitReached,
            .mediaResourceTooLarge,
            .invalidByteRangeResponse,
            .invalidMediaResponseStatus,
            .invalidEncryptionKey,
            .invalidEncryptionKeyResponseStatus,
            .decryptionFailed,
            .transferFailed:
            return true
        default:
            return false
        }
    }

    private static func liveDVRError(
        for error: HLSDownloadError
    ) -> HLSLiveDVRError {
        switch error {
        case .invalidMediaResponseStatus(let statusCode):
            return .invalidMediaResponseStatus(statusCode)
        case .invalidByteRangeResponse:
            return .invalidByteRangeResponse
        case .mediaResourceTooLarge:
            return .mediaResourceTooLarge
        case .totalDownloadTooLarge:
            return .interstitialStorageLimitReached
        case .diskCapacityUnavailable:
            return .diskCapacityUnavailable
        case .insufficientDiskCapacity(let required, let available):
            return .insufficientDiskCapacity(
                required: required,
                available: available
            )
        case .destinationAlreadyExists, .destinationInUse,
            .invalidDestination:
            return .storageFailed
        case .transferFailed:
            return .transferFailed
        case .invalidAES128Key:
            return .invalidEncryptionKey
        case .invalidAES128KeyResponseStatus(let statusCode):
            return .invalidEncryptionKeyResponseStatus(statusCode)
        case .aes128DecryptionFailed:
            return .decryptionFailed
        default:
            return .interstitialPackagingFailed
        }
    }

    private static func sourceIdentity(
        _ source: HLSInterstitialSource
    ) -> String {
        switch source {
        case .asset(let url):
            return "asset:"
                + HLSLiveDVRRecoveryIdentity
                .sourceURLSHA256(url)
        case .assetList(let url):
            return "assetList:"
                + HLSLiveDVRRecoveryIdentity
                .sourceURLSHA256(url)
        }
    }

    private static func isBeforeRecordingWindow(
        _ dateRange: HLSDateRange,
        snapshot: HLSLivePlaylistSnapshot,
        state: HLSLiveDVRRecordingState
    ) -> Bool {
        let end =
            dateRange.endDate
            ?? dateRange.duration.map {
                dateRange.startDate.addingTimeInterval($0)
            }
        guard let end else {
            return false
        }
        if let retainedStart = state.segments.first?.programDateTime {
            return end <= retainedStart
        }
        switch configurationStartBoundary(
            state.configuration.startPosition,
            snapshot: snapshot
        ) {
        case .some(let boundary):
            return end <= boundary
        case nil:
            return false
        }
    }

    private static func isAfterObservedWindow(
        _ dateRange: HLSDateRange,
        snapshot: HLSLivePlaylistSnapshot
    ) -> Bool {
        guard let last = snapshot.segments.last,
            let lastStart = last.programDateTime
        else {
            return false
        }
        let observedEnd = lastStart.addingTimeInterval(last.duration)
        guard observedEnd.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        return dateRange.startDate >= observedEnd
    }

    private static func configurationStartBoundary(
        _ position: HLSLiveDVRStartPosition,
        snapshot: HLSLivePlaylistSnapshot
    ) -> Date? {
        switch position {
        case .currentWindow:
            return snapshot.segments.first?.programDateTime
        case .nextCompletedSegment:
            guard let last = snapshot.segments.last,
                let start = last.programDateTime
            else {
                return nil
            }
            return start.addingTimeInterval(last.duration)
        }
    }

    private static func localDateRange(
        _ dateRange: HLSDateRange,
        source: HLSInterstitialSource,
        skipControl: HLSInterstitialSkipControl?
    ) -> HLSDateRange {
        let original = dateRange.interstitial
        return HLSDateRange(
            id: dateRange.id,
            className: dateRange.className,
            startDate: dateRange.startDate,
            endDate: dateRange.endDate,
            duration: dateRange.duration,
            plannedDuration: dateRange.plannedDuration,
            cues: dateRange.cues,
            endsOnNext: dateRange.endsOnNext,
            interstitial: original.map {
                HLSInterstitial(
                    source: source,
                    resumeOffset: $0.resumeOffset,
                    playoutLimit: $0.playoutLimit,
                    contentVariability: $0.contentVariability,
                    timelineOccupancy: $0.timelineOccupancy,
                    timelineStyle: $0.timelineStyle,
                    navigationRestrictions: $0.navigationRestrictions,
                    skipControl: skipControl
                )
            }
        )
    }

    private static func assetListData(
        _ assets: [(path: String, duration: TimeInterval?)]
    ) throws -> Data {
        let encodedAssets: [[String: Any]] = try assets.map { asset in
            guard let duration = asset.duration,
                duration.isFinite,
                duration >= 0
            else {
                throw HLSLiveDVRError.interstitialPackagingFailed
            }
            return [
                "URI": asset.path,
                "DURATION": duration,
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: ["ASSETS": encodedAssets],
            options: [.sortedKeys]
        )
    }

    private static func fileRecords(
        in directoryURL: URL,
        finalRelativePath: String
    ) throws -> [HLSLiveDVRCheckpoint.FileRecord] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: Array(keys)
            )
        else {
            throw HLSLiveDVRError.storageFailed
        }
        var records: [HLSLiveDVRCheckpoint.FileRecord] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw HLSLiveDVRError.storageFailed
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true,
                let size = values.fileSize,
                size > 0
            else {
                throw HLSLiveDVRError.storageFailed
            }
            let suffix = try relativePath(of: url, in: directoryURL)
            records.append(
                HLSLiveDVRCheckpoint.FileRecord(
                    relativePath: finalRelativePath + "/" + suffix,
                    byteCount: Int64(size),
                    contentSHA256: try HLSContentFingerprint.sha256(
                        contentsOf: url
                    )
                )
            )
        }
        guard !records.isEmpty else {
            throw HLSLiveDVRError.interstitialPackagingFailed
        }
        return records.sorted { $0.relativePath < $1.relativePath }
    }

    private static func relativePath(
        of url: URL,
        in directoryURL: URL
    ) throws -> String {
        let root = directoryURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else {
            throw HLSLiveDVRError.storageFailed
        }
        let relativePath = String(path.dropFirst(prefix.count))
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
            components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
            })
        else {
            throw HLSLiveDVRError.storageFailed
        }
        return relativePath
    }
}
