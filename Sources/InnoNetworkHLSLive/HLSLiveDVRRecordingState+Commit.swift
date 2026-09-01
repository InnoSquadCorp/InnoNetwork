import Foundation
import InnoNetworkHLS

struct HLSLiveDVRFrozenPlaybackSnapshot: Sendable {
    let recordingState: HLSLiveDVRRecordingState
    let workspace: HLSLiveDVRWorkspace

    func publish(
        to destinationDirectoryURL: URL
    ) async throws -> HLSLiveDVRReceipt {
        try await recordingState.publishPlaybackSnapshot(
            from: workspace.directoryURL,
            to: destinationDirectoryURL
        )
    }

    func discard() {
        try? FileManager.default.removeItem(at: workspace.directoryURL)
    }
}

actor HLSLiveDVRSharedPlaybackSnapshot {
    nonisolated let snapshot: HLSLiveDVRFrozenPlaybackSnapshot
    private var remainingUserCount: Int

    init(
        snapshot: HLSLiveDVRFrozenPlaybackSnapshot,
        userCount: Int
    ) {
        self.snapshot = snapshot
        self.remainingUserCount = userCount
    }

    func release() {
        guard remainingUserCount > 0 else {
            return
        }
        remainingUserCount -= 1
        if remainingUserCount == 0 {
            snapshot.discard()
        }
    }
}

extension HLSLiveDVRRecordingState {
    func commit(
        to destinationDirectoryURL: URL
    ) throws -> HLSLiveDVRReceipt {
        try Task.checkCancellation()
        try validatePackage()
        try writePlaylists(to: workspace.directoryURL)
        try Task.checkCancellation()
        try publishPackage(
            from: workspace.directoryURL,
            to: destinationDirectoryURL
        )
        return try receipt(directoryURL: destinationDirectoryURL)
    }

    func freezePlaybackSnapshot() throws
        -> HLSLiveDVRFrozenPlaybackSnapshot
    {
        try Task.checkCancellation()
        try validatePackage()
        let snapshotWorkspace = try HLSLiveDVRWorkspace.makeTemporary(
            in: workspace.directoryURL.deletingLastPathComponent(),
            name:
                ".live-dvr-playback-snapshot."
                + "\(UUID().uuidString).staging"
        )
        var frozen = false
        defer {
            if !frozen {
                try? FileManager.default.removeItem(
                    at: snapshotWorkspace.directoryURL
                )
            }
        }
        try cloneRetainedMedia(
            from: workspace.directoryURL,
            to: snapshotWorkspace.directoryURL
        )
        try writePlaylists(to: snapshotWorkspace.directoryURL)
        try Task.checkCancellation()
        frozen = true
        return HLSLiveDVRFrozenPlaybackSnapshot(
            recordingState: self,
            workspace: snapshotWorkspace
        )
    }

    fileprivate func publishPlaybackSnapshot(
        from frozenDirectoryURL: URL,
        to destinationDirectoryURL: URL
    ) async throws -> HLSLiveDVRReceipt {
        try Task.checkCancellation()
        guard
            !HLSLiveDVRFileSystem.itemExists(
                at: destinationDirectoryURL
            )
        else {
            throw HLSLiveDVRError.destinationAlreadyExists
        }
        let snapshotWorkspace = try HLSLiveDVRWorkspace.make(
            for: destinationDirectoryURL
        )
        var published = false
        defer {
            if !published {
                try? FileManager.default.removeItem(
                    at: snapshotWorkspace.directoryURL
                )
            }
        }
        let capacityGuard = HLSDiskCapacityGuard(
            directoryURL: snapshotWorkspace.directoryURL,
            policy: configuration.limits.diskCapacityPolicy
        )
        do {
            try await capacityGuard.validate(
                additionalRequiredCapacity: mediaByteCount
            )
        } catch HLSDownloadError.diskCapacityUnavailable {
            throw HLSLiveDVRError.diskCapacityUnavailable
        } catch HLSDownloadError.insufficientDiskCapacity(
            let required,
            let available
        ) {
            throw HLSLiveDVRError.insufficientDiskCapacity(
                required: required,
                available: available
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
        try cloneRetainedMedia(
            from: frozenDirectoryURL,
            to: snapshotWorkspace.directoryURL
        )
        try writePlaylists(to: snapshotWorkspace.directoryURL)
        try Task.checkCancellation()
        try publishPackage(
            from: snapshotWorkspace.directoryURL,
            to: destinationDirectoryURL
        )
        published = true
        return try receipt(directoryURL: destinationDirectoryURL)
    }

    private func validatePackage() throws {
        guard container != nil,
            !segments.isEmpty,
            renditionStates.count == selectedRenditions.count
        else {
            throw HLSLiveDVRError.noSegmentsRecorded
        }
        try validateRenditionCoverage()
    }

    private func writePlaylists(
        to packageDirectoryURL: URL
    ) throws {
        guard let container else {
            throw HLSLiveDVRError.noSegmentsRecorded
        }
        let playlist: String
        do {
            playlist = try HLSLiveDVRPlaylistWriter.make(
                container: container,
                segments: segments,
                dateRanges: try packageDateRanges()
            )
        } catch let error as HLSLiveDVRError {
            throw error
        } catch {
            throw HLSLiveDVRError.storageFailed
        }

        do {
            try Data(playlist.utf8).write(
                to: packageDirectoryURL.appendingPathComponent(
                    "index.m3u8"
                ),
                options: .atomic
            )
            for renditionState in renditionStates {
                guard let renditionContainer = renditionState.container else {
                    throw HLSLiveDVRError.unsupportedFeature(
                        .incompleteExternalRendition
                    )
                }
                let renditionPlaylist = try HLSLiveDVRPlaylistWriter.make(
                    container: renditionContainer,
                    segments: renditionState.segments
                )
                let playlistURL =
                    packageDirectoryURL
                    .appendingPathComponent(
                        renditionState.selection.track
                            .relativePlaylistPath
                    )
                try FileManager.default.createDirectory(
                    at: playlistURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(renditionPlaylist.utf8).write(
                    to: playlistURL,
                    options: .atomic
                )
            }
            if !selectedRenditions.isEmpty
                || !inBandClosedCaptions.isEmpty
            {
                let master = try HLSLiveDVRPlaylistWriter.makeMaster(
                    variant: selectedVariant,
                    renditions: selectedRenditions,
                    inBandClosedCaptions: inBandClosedCaptions
                )
                try Data(master.utf8).write(
                    to:
                        packageDirectoryURL
                        .appendingPathComponent("master.m3u8"),
                    options: .atomic
                )
            }
        } catch {
            if let error = error as? HLSLiveDVRError {
                throw error
            }
            throw HLSLiveDVRError.storageFailed
        }
    }

    private func cloneRetainedMedia(
        from sourceDirectoryURL: URL,
        to destinationDirectoryURL: URL
    ) throws {
        let fileManager = FileManager.default
        for relativePath in retainedMediaRelativePaths {
            try Task.checkCancellation()
            let sourceURL = try packageURL(
                for: relativePath,
                in: sourceDirectoryURL
            )
            let destinationURL = try packageURL(
                for: relativePath,
                in: destinationDirectoryURL
            )
            let values = try sourceURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isRegularFile == true,
                values.isSymbolicLink != true
            else {
                throw HLSLiveDVRError.storageFailed
            }
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try fileManager.linkItem(
                    at: sourceURL,
                    to: destinationURL
                )
            } catch {
                try fileManager.copyItem(
                    at: sourceURL,
                    to: destinationURL
                )
            }
        }
    }

    private var retainedMediaRelativePaths: [String] {
        var paths = Set(initializationState.records.map(\.fileName))
        paths.formUnion(
            segments.compactMap { segment in
                segment.isGap ? nil : segment.fileName
            }
        )
        for renditionState in renditionStates {
            let prefix =
                renditionState.selection.relativeDirectoryPath + "/"
            paths.formUnion(
                renditionState.initializationState.records.map {
                    prefix + $0.fileName
                }
            )
            paths.formUnion(
                renditionState.segments.compactMap { segment in
                    segment.isGap ? nil : prefix + segment.fileName
                }
            )
        }
        return paths.sorted()
    }

    private func packageURL(
        for relativePath: String,
        in directoryURL: URL
    ) throws -> URL {
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
        var url = directoryURL.standardizedFileURL
        for component in components {
            url.appendPathComponent(String(component))
        }
        url = url.standardizedFileURL
        let rootPath = directoryURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard url.path.hasPrefix(prefix) else {
            throw HLSLiveDVRError.storageFailed
        }
        return url
    }

    private func publishPackage(
        from stagedDirectoryURL: URL,
        to destinationDirectoryURL: URL
    ) throws {
        let fileManager = FileManager.default
        guard
            !HLSLiveDVRFileSystem.itemExists(
                at: destinationDirectoryURL
            )
        else {
            throw HLSLiveDVRError.destinationAlreadyExists
        }
        do {
            try fileManager.moveItem(
                at: stagedDirectoryURL,
                to: destinationDirectoryURL
            )
        } catch {
            if HLSLiveDVRFileSystem.itemExists(
                at: destinationDirectoryURL
            ) {
                throw HLSLiveDVRError.destinationAlreadyExists
            }
            throw HLSLiveDVRError.storageFailed
        }
    }

    private func receipt(
        directoryURL: URL
    ) throws -> HLSLiveDVRReceipt {
        guard let first = segments.first,
            let last = segments.last
        else {
            throw HLSLiveDVRError.noSegmentsRecorded
        }
        let hasMaster =
            !selectedRenditions.isEmpty
            || !inBandClosedCaptions.isEmpty
        let primaryTrack = HLSLiveDVRTrack(
            kind: .primary,
            name: nil,
            language: nil,
            stableID: selectedVariant?.stableID,
            relativePlaylistPath: "index.m3u8"
        )
        return HLSLiveDVRReceipt(
            directoryURL: directoryURL,
            playlistURL:
                directoryURL.appendingPathComponent(
                    "index.m3u8"
                ),
            entryPlaylistURL:
                directoryURL.appendingPathComponent(
                    hasMaster ? "master.m3u8" : "index.m3u8"
                ),
            tracks: [primaryTrack] + selectedRenditions.map(\.track),
            segmentCount: segments.count,
            gapCount: gapCount,
            recordedDuration: recordedDuration,
            mediaByteCount: mediaByteCount,
            promotedPartCount: promotedPartCount,
            preloadStatistics: preloadStatistics,
            retentionStatistics: retentionStatistics,
            firstMediaSequence: first.sequenceNumber,
            lastMediaSequence: last.sequenceNumber
        )
    }

    private func validateRenditionCoverage() throws {
        guard !renditionStates.isEmpty else {
            return
        }
        guard let primaryStart = segments.first,
            let primaryEnd = segments.last
        else {
            throw HLSLiveDVRError.noSegmentsRecorded
        }
        for renditionState in renditionStates {
            guard
                let renditionStart = renditionState.segments.first,
                let renditionEnd = renditionState.segments.last
            else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .incompleteExternalRendition
                )
            }
            if let primaryStartDate = primaryStart.programDateTime,
                let primaryEndDate = primaryEnd.programDateTime,
                let renditionStartDate = renditionStart.programDateTime,
                let renditionEndDate = renditionEnd.programDateTime
            {
                let primaryEndBoundary =
                    primaryEndDate
                    .addingTimeInterval(primaryEnd.duration)
                let renditionEndBoundary =
                    renditionEndDate
                    .addingTimeInterval(renditionEnd.duration)
                guard
                    renditionStartDate
                        <= primaryStartDate.addingTimeInterval(0.5),
                    renditionEndBoundary
                        >= primaryEndBoundary.addingTimeInterval(-0.5)
                else {
                    throw HLSLiveDVRError.unsupportedFeature(
                        .incompleteExternalRendition
                    )
                }
            } else {
                guard
                    renditionState.recordedDuration + 0.5
                        >= recordedDuration
                else {
                    throw HLSLiveDVRError.unsupportedFeature(
                        .incompleteExternalRendition
                    )
                }
            }
        }
    }

    private func packageDateRanges() throws -> [HLSDateRange] {
        guard !dateRanges.isEmpty else {
            return []
        }
        guard
            let first = segments.first,
            let last = segments.last,
            let startDate = first.programDateTime,
            let lastStartDate = last.programDateTime
        else {
            throw HLSLiveDVRError.unsupportedFeature(
                .unrepresentableTimelineMetadata
            )
        }
        let endDate = lastStartDate.addingTimeInterval(last.duration)
        return dateRanges.filter { dateRange in
            guard dateRange.startDate < endDate else {
                return false
            }
            let rangeEnd =
                dateRange.endDate
                ?? dateRange.duration.map {
                    dateRange.startDate.addingTimeInterval($0)
                }
            guard let rangeEnd else {
                return true
            }
            return rangeEnd > startDate
        }
    }
}
