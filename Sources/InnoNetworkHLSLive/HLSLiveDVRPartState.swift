import Foundation

struct HLSLiveDVRPartCandidate: Sendable {
    let part: HLSLivePartialSegment

    var key: HLSLiveDVRPartKey {
        HLSLiveDVRPartKey(
            mediaSequenceNumber: part.mediaSequenceNumber,
            partIndex: part.partIndex
        )
    }
}

struct HLSLiveDVRStagedPart: Equatable, Sendable {
    let key: HLSLiveDVRPartKey
    let duration: TimeInterval
    let isIndependent: Bool
    let initializationSourceIdentity: String?
    let relativeFilePath: String
    let byteCount: Int64
}

struct HLSLiveDVRPartPromotion: Sendable {
    let parts: [HLSLiveDVRStagedPart]

    var byteCount: Int64 {
        parts.reduce(0) { $0 + $1.byteCount }
    }
}

struct HLSLiveDVRPartUpdate: Sendable {
    let candidates: [HLSLiveDVRPartCandidate]
    let discardedFilePaths: [String]
}

struct HLSLiveDVRPartRecordingState {
    private let pack: HLSLiveDVRPartPack
    private(set) var stagedParts: [HLSLiveDVRStagedPart] = []
    private(set) var promotedPartCount = 0
    private var abandonedSequence: Int64?

    init(
        pack: HLSLiveDVRPartPack,
        promotedPartCount: Int = 0
    ) {
        self.pack = pack
        self.promotedPartCount = promotedPartCount
    }

    var stagedPartDuration: TimeInterval {
        stagedParts.reduce(0) { $0 + $1.duration }
    }

    var stagedPartByteCount: Int64 {
        stagedParts.reduce(0) { $0 + $1.byteCount }
    }

    mutating func update(
        from snapshot: HLSLivePlaylistSnapshot
    ) -> HLSLiveDVRPartUpdate {
        guard pack.policy == .independent,
            snapshot.encryptionMethod == nil
        else {
            return HLSLiveDVRPartUpdate(
                candidates: [],
                discardedFilePaths: discardAll()
            )
        }

        let completedSequences = Set(
            snapshot.segments.map(\.sequenceNumber)
        )
        if snapshot.isEnded, stagedParts.isEmpty {
            return HLSLiveDVRPartUpdate(
                candidates: [],
                discardedFilePaths: []
            )
        }

        let stagedSequence = stagedParts.first?.key.mediaSequenceNumber
        let isStagedSequenceCompleted =
            stagedSequence.map { sequence in
                completedSequences.contains(sequence)
            } ?? false
        let targetSequence =
            isStagedSequenceCompleted
            ? stagedSequence
            : nextIncompleteSequence(in: snapshot)
        var discardedFilePaths: [String] = []
        if let stagedSequence = stagedParts.first?.key.mediaSequenceNumber,
            let targetSequence,
            stagedSequence != targetSequence
        {
            discardedFilePaths = discardAll()
        }
        guard let targetSequence else {
            return HLSLiveDVRPartUpdate(
                candidates: [],
                discardedFilePaths: discardedFilePaths
            )
        }
        if abandonedSequence != targetSequence {
            abandonedSequence = nil
        }
        guard abandonedSequence == nil else {
            return HLSLiveDVRPartUpdate(
                candidates: [],
                discardedFilePaths: discardedFilePaths
            )
        }

        let advertised = snapshot.partialSegments
            .filter {
                $0.mediaSequenceNumber == targetSequence
            }
            .sorted { $0.partIndex < $1.partIndex }
        if advertised.isEmpty, isStagedSequenceCompleted {
            return HLSLiveDVRPartUpdate(
                candidates: [],
                discardedFilePaths: discardedFilePaths
            )
        }
        guard !advertised.isEmpty,
            advertised.allSatisfy({ !$0.isGap })
        else {
            discardedFilePaths.append(contentsOf: discardAll())
            return HLSLiveDVRPartUpdate(
                candidates: [],
                discardedFilePaths: discardedFilePaths
            )
        }

        if !stagedPartsMatch(advertised) {
            discardedFilePaths.append(contentsOf: discardAll())
        }
        let nextIndex = stagedParts.count
        if nextIndex == 0 {
            guard advertised.first?.partIndex == 0,
                advertised.first?.isIndependent == true
            else {
                return HLSLiveDVRPartUpdate(
                    candidates: [],
                    discardedFilePaths: discardedFilePaths
                )
            }
        }
        let availableCount = max(
            0,
            pack.maximumStagedPartCount - stagedParts.count
        )
        let candidates = advertised.filter {
            $0.partIndex >= nextIndex
        }
        .prefix(availableCount)
        guard
            candidates.enumerated().allSatisfy({ offset, part in
                part.partIndex == nextIndex + offset
            })
        else {
            return HLSLiveDVRPartUpdate(
                candidates: [],
                discardedFilePaths: discardedFilePaths
            )
        }
        return HLSLiveDVRPartUpdate(
            candidates: candidates.map(HLSLiveDVRPartCandidate.init(part:)),
            discardedFilePaths: discardedFilePaths
        )
    }

    func availableByteCount(
        totalRetainedByteCount: Int64,
        maximumTotalByteCount: Int64
    ) -> Int64 {
        let stagedRemaining = max(
            0,
            pack.maximumStagedPartBytes - stagedPartByteCount
        )
        let totalRemaining = max(
            0,
            maximumTotalByteCount - totalRetainedByteCount
                - stagedPartByteCount
        )
        return min(stagedRemaining, totalRemaining)
    }

    mutating func retain(
        _ candidate: HLSLiveDVRPartCandidate,
        relativeFilePath: String,
        byteCount: Int64,
        totalRetainedByteCount: Int64,
        maximumTotalByteCount: Int64
    ) throws {
        guard byteCount > 0,
            stagedParts.count < pack.maximumStagedPartCount,
            byteCount
                <= availableByteCount(
                    totalRetainedByteCount: totalRetainedByteCount,
                    maximumTotalByteCount: maximumTotalByteCount
                )
        else {
            throw HLSLiveDVRError.mediaResourceTooLarge
        }
        if let last = stagedParts.last {
            let (expectedIndex, overflow) =
                last.key.partIndex.addingReportingOverflow(1)
            guard !overflow,
                last.key.mediaSequenceNumber
                    == candidate.part.mediaSequenceNumber,
                candidate.part.partIndex == expectedIndex
            else {
                throw HLSLiveDVRError.liveWindowAdvanced
            }
        } else {
            guard candidate.part.partIndex == 0,
                candidate.part.isIndependent
            else {
                throw HLSLiveDVRError.liveWindowAdvanced
            }
        }
        stagedParts.append(
            HLSLiveDVRStagedPart(
                key: candidate.key,
                duration: candidate.part.duration,
                isIndependent: candidate.part.isIndependent,
                initializationSourceIdentity:
                    candidate.part.initializationSegment.map(
                        HLSLiveDVRRecoveryIdentity
                            .initializationSegmentIdentity
                    ),
                relativeFilePath: relativeFilePath,
                byteCount: byteCount
            )
        )
    }

    func promotion(
        for segment: HLSLiveSegment
    ) -> HLSLiveDVRPartPromotion? {
        let initializationSourceIdentity =
            segment.initializationSegment.map(
                HLSLiveDVRRecoveryIdentity
                    .initializationSegmentIdentity
            )
        guard segment.encryption == nil,
            let first = stagedParts.first,
            first.key.mediaSequenceNumber == segment.sequenceNumber,
            first.key.partIndex == 0,
            first.isIndependent,
            stagedParts.enumerated().allSatisfy({ offset, part in
                part.key.mediaSequenceNumber == segment.sequenceNumber
                    && part.key.partIndex == offset
                    && part.initializationSourceIdentity
                        == initializationSourceIdentity
            })
        else {
            return nil
        }
        let duration = stagedPartDuration
        let tolerance = max(0.05, segment.duration * 0.01)
        guard duration.isFinite,
            abs(duration - segment.duration) <= tolerance
        else {
            return nil
        }
        return HLSLiveDVRPartPromotion(parts: stagedParts)
    }

    mutating func consumePromotion(
        _ promotion: HLSLiveDVRPartPromotion
    ) throws {
        guard promotion.parts == stagedParts else {
            throw HLSLiveDVRError.storageFailed
        }
        let (nextCount, overflow) =
            promotedPartCount.addingReportingOverflow(
                promotion.parts.count
            )
        guard !overflow else {
            throw HLSLiveDVRError.storageFailed
        }
        promotedPartCount = nextCount
        stagedParts.removeAll(keepingCapacity: true)
    }

    mutating func discard(
        mediaSequenceNumber: Int64
    ) -> [String] {
        guard
            stagedParts.first?.key.mediaSequenceNumber
                == mediaSequenceNumber
        else {
            return []
        }
        return discardAll()
    }

    mutating func abandon(
        mediaSequenceNumber: Int64
    ) -> [String] {
        abandonedSequence = mediaSequenceNumber
        return discardAll()
    }

    mutating func discardAll() -> [String] {
        let paths = stagedParts.map(\.relativeFilePath)
        stagedParts.removeAll(keepingCapacity: true)
        return paths
    }

    private func nextIncompleteSequence(
        in snapshot: HLSLivePlaylistSnapshot
    ) -> Int64? {
        if let completed = snapshot.segments.last?.sequenceNumber {
            let (next, overflow) = completed.addingReportingOverflow(1)
            return overflow ? nil : next
        }
        return snapshot.partialSegments
            .map(\.mediaSequenceNumber)
            .min()
    }

    private func stagedPartsMatch(
        _ advertised: [HLSLivePartialSegment]
    ) -> Bool {
        guard !stagedParts.isEmpty else {
            return true
        }
        var advertisedByIndex: [Int: HLSLivePartialSegment] = [:]
        for part in advertised {
            guard advertisedByIndex[part.partIndex] == nil else {
                return false
            }
            advertisedByIndex[part.partIndex] = part
        }
        return stagedParts.allSatisfy { staged in
            guard let part = advertisedByIndex[staged.key.partIndex] else {
                return true
            }
            return part.mediaSequenceNumber
                == staged.key.mediaSequenceNumber
                && part.duration == staged.duration
                && part.isIndependent == staged.isIndependent
                && part.initializationSegment.map(
                    HLSLiveDVRRecoveryIdentity
                        .initializationSegmentIdentity
                ) == staged.initializationSourceIdentity
                && !part.isGap
        }
    }
}

struct HLSLiveDVRPartKey: Equatable, Hashable, Sendable {
    let mediaSequenceNumber: Int64
    let partIndex: Int
}
