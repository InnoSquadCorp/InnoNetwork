import Foundation

extension HLSLiveDVRRecordingState {
    mutating func applyRollingRetentionAfterPrimarySegment() throws {
        guard configuration.limits.retentionPolicy == .rollingWindow else {
            return
        }
        while primaryExceedsDurationOrCountLimit, segments.count > 1 {
            try evictOldestPrimarySegment()
        }
        try prunePrimaryInitializations()
        try pruneExpiredInterstitials()
        if renditionStates.isEmpty {
            try enforceRollingByteLimit()
        }
    }

    mutating func finalizeRollingPresentation() throws {
        guard configuration.limits.retentionPolicy == .rollingWindow else {
            return
        }
        for index in renditionStates.indices {
            try trimRenditionToOwnLimits(at: index)
        }
        try synchronizeRenditionsToPrimaryWindow()
        try enforceRollingByteLimit()
    }

    private mutating func enforceRollingByteLimit() throws {
        while mediaByteCount
            > configuration.limits.maximumTotalMediaBytes,
            segments.count > 1
        {
            try evictOldestPrimarySegment()
            try prunePrimaryInitializations()
            try synchronizeRenditionsToPrimaryWindow()
        }
        guard
            mediaByteCount
                <= configuration.limits.maximumTotalMediaBytes
        else {
            throw HLSLiveDVRError.storageFailed
        }
    }

    mutating func takePendingEvictionFilePaths() -> [String] {
        let retainedPaths = retainedMediaFilePaths
        let removable = pendingEvictionFilePaths.subtracting(retainedPaths)
        pendingEvictionFilePaths.removeAll()
        return removable.sorted()
    }

    private var primaryExceedsDurationOrCountLimit: Bool {
        segments.count > configuration.limits.maximumSegmentCount
            || recordedDuration
                > configuration.limits.maximumDuration
    }

    private var retainedMediaFilePaths: Set<String> {
        var paths = Set(initializationState.records.map(\.fileName))
        paths.formUnion(
            segments.compactMap { segment in
                segment.isGap ? nil : segment.fileName
            }
        )
        for state in renditionStates {
            let prefix = state.selection.relativeDirectoryPath + "/"
            paths.formUnion(
                state.initializationState.records.map {
                    prefix + $0.fileName
                }
            )
            paths.formUnion(
                state.segments.compactMap { segment in
                    segment.isGap ? nil : prefix + segment.fileName
                }
            )
        }
        paths.formUnion(
            interstitials.flatMap { $0.files.map(\.relativePath) }
        )
        return paths
    }

    private mutating func trimRenditionToOwnLimits(
        at index: Int
    ) throws {
        while renditionStates[index].segments.count
            > configuration.limits.maximumSegmentCount
            || renditionStates[index].recordedDuration
                > configuration.limits.maximumDuration
        {
            guard
                let removed = renditionStates[index]
                    .evictOldestSegment()
            else {
                break
            }
            try registerRenditionEviction(removed, at: index)
        }
        try pruneRenditionInitializations(at: index)
    }

    private mutating func synchronizeRenditionsToPrimaryWindow()
        throws
    {
        guard let primaryStart = segments.first else {
            return
        }
        for index in renditionStates.indices {
            while shouldEvictOldestRenditionSegment(
                at: index,
                primaryStart: primaryStart
            ) {
                guard
                    let removed = renditionStates[index]
                        .evictOldestSegment()
                else {
                    break
                }
                try registerRenditionEviction(removed, at: index)
            }
            try pruneRenditionInitializations(at: index)
        }
    }

    private func shouldEvictOldestRenditionSegment(
        at index: Int,
        primaryStart: HLSLiveDVRStoredSegment
    ) -> Bool {
        let state = renditionStates[index]
        guard state.segments.count > 1,
            let oldest = state.segments.first,
            let next = state.segments.dropFirst().first
        else {
            return false
        }
        if let primaryDate = primaryStart.programDateTime,
            let nextDate = next.programDateTime
        {
            return nextDate
                <= primaryDate.addingTimeInterval(0.5)
        }
        let primaryWindowReachedLimit =
            segments.count
            >= configuration.limits.maximumSegmentCount
            || recordedDuration + 0.5
                >= configuration.limits.maximumDuration
            || mediaByteCount
                > configuration.limits.maximumTotalMediaBytes
        guard primaryWindowReachedLimit else {
            return false
        }
        return state.recordedDuration - oldest.duration + 0.5
            >= recordedDuration
    }

    private mutating func evictOldestPrimarySegment() throws {
        guard segments.count > 1 else {
            return
        }
        let removed = segments.removeFirst()
        recordedDuration = max(0, recordedDuration - removed.duration)
        if removed.isGap {
            gapCount -= 1
        } else {
            try subtractMediaBytes(removed.byteCount)
            pendingEvictionFilePaths.insert(removed.fileName)
        }
        retentionStatistics = try retentionStatistics.adding(
            primarySegmentCount: 1,
            primaryDuration: removed.duration,
            mediaByteCount: removed.byteCount
        )
    }

    private mutating func registerRenditionEviction(
        _ segment: HLSLiveDVRStoredSegment,
        at index: Int
    ) throws {
        guard !segment.isGap else {
            return
        }
        try subtractMediaBytes(segment.byteCount)
        pendingEvictionFilePaths.insert(
            renditionStates[index].selection.relativeDirectoryPath
                + "/" + segment.fileName
        )
        retentionStatistics = try retentionStatistics.adding(
            mediaByteCount: segment.byteCount
        )
    }

    private mutating func prunePrimaryInitializations() throws {
        let removed = initializationState.removeUnreferenced(
            retaining: Set(
                segments.compactMap(
                    \.initializationSourceIdentity
                )
            )
        )
        try registerInitializationEvictions(
            removed,
            storagePrefix: nil
        )
    }

    private mutating func pruneRenditionInitializations(
        at index: Int
    ) throws {
        let removed = renditionStates[index]
            .removeUnreferencedInitializations()
        try registerInitializationEvictions(
            removed,
            storagePrefix:
                renditionStates[index].selection.relativeDirectoryPath
        )
    }

    private mutating func registerInitializationEvictions(
        _ records: [HLSLiveDVRStoredInitialization],
        storagePrefix: String?
    ) throws {
        for record in records {
            try subtractMediaBytes(record.byteCount)
            let path =
                storagePrefix.map {
                    $0 + "/" + record.fileName
                } ?? record.fileName
            pendingEvictionFilePaths.insert(path)
            retentionStatistics = try retentionStatistics.adding(
                mediaByteCount: record.byteCount
            )
        }
    }

    private mutating func subtractMediaBytes(_ byteCount: Int64) throws {
        guard byteCount >= 0, mediaByteCount >= byteCount else {
            throw HLSLiveDVRError.storageFailed
        }
        mediaByteCount -= byteCount
    }
}
