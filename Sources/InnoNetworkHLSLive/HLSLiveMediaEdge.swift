import Foundation

struct HLSLiveMediaEdge: Sendable {
    let mediaSequenceNumber: Int64
    let partBoundaryIndex: Int
    let mediaOffset: TimeInterval

    static func latest(
        in snapshot: HLSLivePlaylistSnapshot
    ) throws -> Self? {
        let completeEdge: Self?
        if let segment = snapshot.segments.last {
            let (nextSequence, overflow) =
                segment.sequenceNumber.addingReportingOverflow(1)
            guard !overflow else {
                throw HLSLiveError.sequenceOverflow
            }
            completeEdge = Self(
                mediaSequenceNumber: nextSequence,
                partBoundaryIndex: 0,
                mediaOffset: 0
            )
        } else {
            completeEdge = nil
        }
        guard let partial = snapshot.partialSegments.last else {
            return completeEdge
        }
        if let completeEdge,
            partial.mediaSequenceNumber
                < completeEdge.mediaSequenceNumber
        {
            return completeEdge
        }
        let (boundaryIndex, overflow) =
            partial.partIndex.addingReportingOverflow(1)
        guard !overflow else {
            throw HLSLiveError.sequenceOverflow
        }
        let mediaOffset = snapshot.partialSegments.reduce(0) {
            result, candidate in
            guard
                candidate.mediaSequenceNumber
                    == partial.mediaSequenceNumber
            else {
                return result
            }
            return result + candidate.duration
        }
        guard mediaOffset.isFinite else {
            throw HLSLiveError.sequenceOverflow
        }
        return Self(
            mediaSequenceNumber: partial.mediaSequenceNumber,
            partBoundaryIndex: boundaryIndex,
            mediaOffset: mediaOffset
        )
    }
}
