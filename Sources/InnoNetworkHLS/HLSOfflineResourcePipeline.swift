import Foundation

struct HLSOfflineResourcePipeline: Sendable {
    private struct PersistedResource: Sendable {
        let localIndex: Int
        let staged: HLSStagedResource
    }

    private let loader: HLSResourceLoader
    private let maximumConcurrentTransfers: Int

    init(
        loader: HLSResourceLoader,
        maximumConcurrentTransfers: Int
    ) {
        self.loader = loader
        self.maximumConcurrentTransfers = maximumConcurrentTransfers
    }

    func persist(
        resources: [HLSResourceTransfer],
        resourceFileNames: [String],
        resourceIndexOffset: Int,
        trackRelativeDirectoryPath: String,
        trackDirectoryURL: URL,
        stagingDirectoryURL: URL,
        budget: HLSDownloadBudget,
        diskCapacityGuard: HLSDiskCapacityGuard,
        retainedResourceByteCounts: [Int: Int64] = [:],
        didPersistResource:
            @escaping @Sendable (
                _ globalIndex: Int,
                _ relativePath: String,
                _ fileURL: URL
            ) async throws -> Void = { _, _, _ in }
    ) async throws {
        guard resources.count == resourceFileNames.count else {
            throw HLSDownloadError.invalidPlaylist
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: trackDirectoryURL.appendingPathComponent(
                "resources",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: stagingDirectoryURL)
        }

        for (globalIndex, byteCount) in retainedResourceByteCounts
        where globalIndex >= resourceIndexOffset
            && globalIndex < resourceIndexOffset + resources.count
        {
            try await budget.registerRetainedBytes(
                byteCount,
                forResourceAt: globalIndex
            )
        }
        let pendingLocalIndices = resources.indices.filter {
            !retainedResourceByteCounts.keys.contains(
                resourceIndexOffset + $0
            )
        }

        try await withThrowingTaskGroup(
            of: PersistedResource.self
        ) { group in
            var nextPendingIndex = 0
            var inFlightCount = 0

            func addNext() {
                let localIndex = pendingLocalIndices[nextPendingIndex]
                let resource = resources[localIndex]
                let globalIndex = resourceIndexOffset + localIndex
                group.addTask {
                    PersistedResource(
                        localIndex: localIndex,
                        staged: try await loader.stage(
                            resource: resource,
                            at: globalIndex,
                            in: stagingDirectoryURL,
                            budget: budget,
                            diskCapacityGuard: diskCapacityGuard
                        )
                    )
                }
                nextPendingIndex += 1
                inFlightCount += 1
            }

            while inFlightCount < maximumConcurrentTransfers,
                nextPendingIndex < pendingLocalIndices.count
            {
                addNext()
            }

            while let persisted = try await group.next() {
                inFlightCount -= 1
                try Task.checkCancellation()
                let targetURL = trackDirectoryURL.appendingPathComponent(
                    resourceFileNames[persisted.localIndex]
                )
                try fileManager.moveItem(
                    at: persisted.staged.fileURL,
                    to: targetURL
                )
                let globalIndex =
                    resourceIndexOffset + persisted.localIndex
                try await didPersistResource(
                    globalIndex,
                    trackRelativeDirectoryPath + "/"
                        + resourceFileNames[persisted.localIndex],
                    targetURL
                )
                if nextPendingIndex < pendingLocalIndices.count {
                    addNext()
                }
            }
        }
    }
}
