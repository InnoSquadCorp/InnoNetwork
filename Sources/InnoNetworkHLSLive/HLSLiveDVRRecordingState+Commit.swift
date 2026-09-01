import Foundation
import InnoNetworkHLS

extension HLSLiveDVRRecordingState {
    func commit(
        to destinationDirectoryURL: URL
    ) throws -> HLSLiveDVRReceipt {
        try Task.checkCancellation()
        guard
            let container,
            let first = segments.first,
            let last = segments.last,
            renditionStates.count == selectedRenditions.count
        else {
            throw HLSLiveDVRError.noSegmentsRecorded
        }
        try validateRenditionCoverage()
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

        let stagedPlaylistURL =
            workspace.directoryURL.appendingPathComponent(
                "index.m3u8"
            )
        do {
            try Data(playlist.utf8).write(
                to: stagedPlaylistURL,
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
                let playlistURL = workspace.directoryURL
                    .appendingPathComponent(
                        renditionState.selection.track
                            .relativePlaylistPath
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
                    to: workspace.directoryURL
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

        try Task.checkCancellation()
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
                at: workspace.directoryURL,
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
            directoryURL: destinationDirectoryURL,
            playlistURL:
                destinationDirectoryURL.appendingPathComponent(
                    "index.m3u8"
                ),
            entryPlaylistURL:
                destinationDirectoryURL.appendingPathComponent(
                    hasMaster ? "master.m3u8" : "index.m3u8"
                ),
            tracks: [primaryTrack] + selectedRenditions.map(\.track),
            segmentCount: segments.count,
            recordedDuration: recordedDuration,
            mediaByteCount: mediaByteCount,
            promotedPartCount: promotedPartCount,
            preloadStatistics: preloadStatistics,
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
