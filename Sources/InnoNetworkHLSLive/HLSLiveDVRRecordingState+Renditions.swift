import Foundation
import InnoNetworkHLS

extension HLSLiveDVRRecordingState {
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

}
