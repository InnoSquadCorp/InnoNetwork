import Foundation
import InnoNetworkHLS

enum HLSLivePlaylistMerger {
    static func makeSnapshot(
        from document: HLSLiveResolvedDocument,
        previous: HLSLivePlaylistSnapshot?,
        generation: Int,
        selectedVariant: HLSVariant? = nil,
        availableRenditions: [HLSRendition] = [],
        pathwayID: String? = nil
    ) throws -> HLSLivePlaylistSnapshot {
        guard document.playlist.kind == .media else {
            throw HLSLiveError.mediaPlaylistRequired
        }
        let deltaUpdate =
            document.playlist.lowLatency?.deltaUpdate
        let segments: [HLSLiveSegment]
        let dateRanges: [HLSDateRange]
        if let deltaUpdate {
            guard let previous else {
                throw HLSLiveError.deltaBaseUnavailable
            }
            segments = try mergeSegments(
                document: document,
                skippedSegmentCount:
                    deltaUpdate.skippedSegmentCount,
                previous: previous
            )
            dateRanges = mergeDateRanges(
                response: document.playlist.dateRanges,
                removedIDs:
                    deltaUpdate.recentlyRemovedDateRangeIDs,
                previous: previous.dateRanges
            )
        } else {
            segments = document.segments.map(HLSLiveSegment.init(record:))
            dateRanges = document.playlist.dateRanges
        }

        return HLSLivePlaylistSnapshot(
            playlist: document.playlist,
            segments: segments,
            partialSegments: document.partialSegments.map(
                HLSLivePartialSegment.init(record:)
            ),
            dateRanges: dateRanges,
            selectedVariant: selectedVariant,
            availableRenditions: availableRenditions,
            pathwayID: pathwayID,
            generation: generation,
            isDeltaUpdate: deltaUpdate != nil,
            isEnded: document.hasEndList,
            initializationSegments:
                document.initializationSegments.map(
                    HLSLiveInitializationSegment.init(record:)
                ),
            encryptionMethod: document.encryptionMethod
        )
    }

    private static func mergeSegments(
        document: HLSLiveResolvedDocument,
        skippedSegmentCount: Int,
        previous: HLSLivePlaylistSnapshot
    ) throws -> [HLSLiveSegment] {
        guard let skippedCount64 = Int64(exactly: skippedSegmentCount) else {
            throw HLSLiveError.deltaBaseUnavailable
        }
        var previousBySequence: [Int64: HLSLiveSegment] = [:]
        for segment in previous.segments {
            guard previousBySequence[segment.sequenceNumber] == nil else {
                throw HLSLiveError.deltaBaseUnavailable
            }
            previousBySequence[segment.sequenceNumber] = segment
        }
        var prefix: [HLSLiveSegment] = []
        prefix.reserveCapacity(skippedSegmentCount)
        for offset in 0..<skippedCount64 {
            let (sequenceNumber, overflow) =
                document.declaredMediaSequence
                .addingReportingOverflow(offset)
            guard
                !overflow
            else {
                throw HLSLiveError.sequenceOverflow
            }
            guard let segment = previousBySequence[sequenceNumber] else {
                throw HLSLiveError.deltaBaseUnavailable
            }
            prefix.append(segment)
        }

        let listed = document.segments.map(HLSLiveSegment.init(record:))
        let (expectedFirstListedSequence, overflow) =
            document.declaredMediaSequence
            .addingReportingOverflow(skippedCount64)
        guard
            !overflow
        else {
            throw HLSLiveError.sequenceOverflow
        }
        guard
            listed.first?.sequenceNumber == expectedFirstListedSequence
                || listed.isEmpty
        else {
            throw HLSLiveError.deltaBaseUnavailable
        }
        return prefix + listed
    }

    private static func mergeDateRanges(
        response: [HLSDateRange],
        removedIDs: [String],
        previous: [HLSDateRange]
    ) -> [HLSDateRange] {
        let removed = Set(removedIDs)
        var result = previous.filter { !removed.contains($0.id) }
        for dateRange in response {
            if let index = result.firstIndex(where: {
                $0.id == dateRange.id
            }) {
                result[index] = dateRange
            } else {
                result.append(dateRange)
            }
        }
        return result
    }
}
