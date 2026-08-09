import Foundation

struct HLSResourcePipeline: Sendable {
    private static let assemblyChunkBytes = 64 * 1_024

    private let loader: HLSResourceLoader
    private let maximumConcurrentTransfers: Int

    init(
        loader: HLSResourceLoader,
        maximumConcurrentTransfers: Int
    ) {
        self.loader = loader
        self.maximumConcurrentTransfers = maximumConcurrentTransfers
    }

    func assemble(
        resources: [HLSResourceTransfer],
        startingAt startingResourceIndex: Int = 0,
        into outputFileHandle: FileHandle,
        stagingDirectoryURL: URL,
        budget: HLSDownloadBudget,
        diskCapacityGuard: HLSDiskCapacityGuard,
        didAssembleResource:
            @escaping @Sendable (
                _ nextResourceIndex: Int,
                _ assembledByteCount: Int64
            ) async throws -> Void = { _, _ in }
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: stagingDirectoryURL)
        }

        try await withThrowingTaskGroup(
            of: HLSStagedResource.self
        ) { group in
            var nextResourceIndex = startingResourceIndex
            var nextAssemblyIndex = startingResourceIndex
            var inFlightCount = 0
            var readyResources: [Int: HLSStagedResource] = [:]

            while inFlightCount + readyResources.count
                < maximumConcurrentTransfers,
                nextResourceIndex < resources.count
            {
                let index = nextResourceIndex
                let resource = resources[index]
                group.addTask {
                    try await loader.stage(
                        resource: resource,
                        at: index,
                        in: stagingDirectoryURL,
                        budget: budget,
                        diskCapacityGuard: diskCapacityGuard
                    )
                }
                inFlightCount += 1
                nextResourceIndex += 1
            }

            while nextAssemblyIndex < resources.count {
                guard let stagedResource = try await group.next() else {
                    throw HLSDownloadError.internalTransferFailure(
                        "The HLS resource pipeline ended before assembly completed.",
                        code: 3
                    )
                }
                inFlightCount -= 1
                readyResources[stagedResource.index] = stagedResource

                while let readyResource =
                    readyResources.removeValue(
                        forKey: nextAssemblyIndex
                    )
                {
                    try Task.checkCancellation()
                    try await append(
                        stagedResource: readyResource,
                        to: outputFileHandle,
                        diskCapacityGuard: diskCapacityGuard
                    )
                    let outputOffset = try outputFileHandle.offset()
                    guard outputOffset <= UInt64(Int64.max) else {
                        throw HLSDownloadError.internalTransferFailure(
                            "The assembled HLS output exceeded the supported file offset.",
                            code: 4
                        )
                    }
                    try outputFileHandle.synchronize()
                    try await didAssembleResource(
                        nextAssemblyIndex + 1,
                        Int64(outputOffset)
                    )
                    try? fileManager.removeItem(
                        at: readyResource.fileURL
                    )
                    nextAssemblyIndex += 1
                }

                while inFlightCount + readyResources.count
                    < maximumConcurrentTransfers,
                    nextResourceIndex < resources.count
                {
                    let index = nextResourceIndex
                    let resource = resources[index]
                    group.addTask {
                        try await loader.stage(
                            resource: resource,
                            at: index,
                            in: stagingDirectoryURL,
                            budget: budget,
                            diskCapacityGuard: diskCapacityGuard
                        )
                    }
                    inFlightCount += 1
                    nextResourceIndex += 1
                }
            }
        }
    }

    private func append(
        stagedResource: HLSStagedResource,
        to outputFileHandle: FileHandle,
        diskCapacityGuard: HLSDiskCapacityGuard
    ) async throws {
        let inputFileHandle = try FileHandle(
            forReadingFrom: stagedResource.fileURL
        )
        defer {
            try? inputFileHandle.close()
        }

        while let chunk = try inputFileHandle.read(
            upToCount: Self.assemblyChunkBytes
        ), !chunk.isEmpty {
            try Task.checkCancellation()
            try await diskCapacityGuard.reserve(chunk.count)
            do {
                try outputFileHandle.write(contentsOf: chunk)
            } catch {
                await diskCapacityGuard.release(chunk.count)
                throw error
            }
            await diskCapacityGuard.release(chunk.count)
        }
    }
}
