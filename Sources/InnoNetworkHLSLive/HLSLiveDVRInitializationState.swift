import Foundation

struct HLSLiveDVRStoredInitialization: Equatable, Sendable {
    let sourceIdentity: String
    let fileName: String
    let byteCount: Int64
    let contentSHA256: String
}

struct HLSLiveDVRInitializationRecordingState: Sendable {
    private(set) var records: [HLSLiveDVRStoredInitialization]

    init(records: [HLSLiveDVRStoredInitialization] = []) {
        self.records = records
    }

    func retained(
        for source: HLSLiveInitializationSegment
    ) -> HLSLiveDVRStoredInitialization? {
        let identity =
            HLSLiveDVRRecoveryIdentity
            .initializationSegmentIdentity(source)
        return records.first {
            $0.sourceIdentity == identity
        }
    }

    func retained(
        sourceIdentity: String
    ) -> HLSLiveDVRStoredInitialization? {
        records.first {
            $0.sourceIdentity == sourceIdentity
        }
    }

    mutating func retain(
        _ source: HLSLiveInitializationSegment,
        fileName: String,
        byteCount: Int64,
        contentSHA256: String
    ) throws {
        let sourceIdentity =
            HLSLiveDVRRecoveryIdentity
            .initializationSegmentIdentity(source)
        guard retained(sourceIdentity: sourceIdentity) == nil,
            byteCount > 0,
            !fileName.isEmpty,
            contentSHA256.count == 64
        else {
            throw HLSLiveDVRError.storageFailed
        }
        records.append(
            HLSLiveDVRStoredInitialization(
                sourceIdentity: sourceIdentity,
                fileName: fileName,
                byteCount: byteCount,
                contentSHA256: contentSHA256
            )
        )
    }

    mutating func removeLast(
        matching source: HLSLiveInitializationSegment
    ) -> HLSLiveDVRStoredInitialization? {
        let sourceIdentity =
            HLSLiveDVRRecoveryIdentity
            .initializationSegmentIdentity(source)
        guard records.last?.sourceIdentity == sourceIdentity else {
            return nil
        }
        return records.removeLast()
    }

    mutating func removeUnreferenced(
        retaining sourceIdentities: Set<String>
    ) -> [HLSLiveDVRStoredInitialization] {
        let removed = records.filter {
            !sourceIdentities.contains($0.sourceIdentity)
        }
        records.removeAll {
            !sourceIdentities.contains($0.sourceIdentity)
        }
        return removed
    }
}
