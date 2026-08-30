import Foundation
import InnoNetwork

enum HLSDownloadOutcome: Sendable {
    case completed(HLSDownloadReceipt)
    case failed(HLSDownloadError)
    case cancelled
}

struct HLSDownloadOperation: Sendable {
    private let planner: HLSDownloadPlanner
    private let configuration: HLSDownloadConfiguration
    private let diskCapacityChecker: HLSDiskCapacityChecker
    private let client: HLSHTTPClient
    private let clock: any InnoNetworkClock

    init(
        client: HLSHTTPClient,
        configuration: HLSDownloadConfiguration,
        diskCapacityChecker: HLSDiskCapacityChecker,
        clock: any InnoNetworkClock
    ) {
        self.planner = HLSDownloadPlanner(
            client: client,
            selectionPolicy: configuration.variantSelectionPolicy,
            contentSteering: configuration.contentSteering,
            maximumTransferBytes:
                configuration.maximumMediaResourceBytes,
            clock: clock
        )
        self.configuration = configuration
        self.diskCapacityChecker = diskCapacityChecker
        self.client = client
        self.clock = clock
    }

    func prepare(
        sourceURL: URL
    ) async throws -> HLSDownloadPreparation {
        try await planner.resolve(sourceURL: sourceURL)
            .preparation(sourceURL: sourceURL)
    }

    func perform(
        sourceURL: URL,
        destinationURL: URL,
        continuation: AsyncStream<HLSDownloadEvent>.Continuation
    ) async {
        let outcome = await execute(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        ) { progress in
            continuation.yield(.progress(progress))
        }
        switch outcome {
        case .completed(let receipt):
            continuation.yield(.completed(receipt.destinationURL))
        case .failed(let error):
            continuation.yield(.failed(error))
        case .cancelled:
            continuation.yield(.cancelled)
        }
        continuation.finish()
    }

    func execute(
        sourceURL: URL,
        destinationURL: URL,
        onProgress: @escaping @Sendable (HLSDownloadProgress) -> Void
    ) async -> HLSDownloadOutcome {
        guard destinationURL.isFileURL else {
            return .failed(.invalidDestination)
        }

        let destinationLease: HLSDestinationLease
        do {
            destinationLease = try await HLSDestinationLease.acquire(
                for: destinationURL
            )
        } catch let error as HLSDownloadError {
            return .failed(error)
        } catch {
            return .failed(.wrappingTransferFailure(error))
        }

        let outcome = await performClaimedDownload(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            onProgress: onProgress
        )
        await destinationLease.release()
        return outcome
    }

    private func performClaimedDownload(
        sourceURL: URL,
        destinationURL: URL,
        onProgress: @escaping @Sendable (HLSDownloadProgress) -> Void
    ) async -> HLSDownloadOutcome {
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            return .failed(.destinationAlreadyExists)
        }

        var workspace: HLSDownloadWorkspace?
        var resumeStore: HLSResumeStore?
        var didComplete = false
        let outcome: HLSDownloadOutcome
        do {
            let destinationDirectory =
                destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            try diskCapacityChecker.validate(
                directoryURL: destinationDirectory,
                policy: configuration.diskCapacityPolicy
            )
            let diskCapacityGuard = HLSDiskCapacityGuard(
                checker: diskCapacityChecker,
                directoryURL: destinationDirectory,
                policy: configuration.diskCapacityPolicy
            )

            let plan = try await planner.resolve(sourceURL: sourceURL)
            let resourcePlan = plan.resourcePlan
            let aes128KeySet = try await HLSAES128KeyResolver(
                client: client,
                retryPolicy: configuration.retryPolicy,
                clock: clock
            ).resolve(resources: resourcePlan.transfers)
            let contentSteeringRecovery =
                makeContentSteeringRecovery(for: plan)
            let resourcePipeline = HLSResourcePipeline(
                loader: HLSResourceLoader(
                    client: client,
                    maximumMediaResourceBytes:
                        configuration.maximumMediaResourceBytes,
                    retryPolicy: configuration.retryPolicy,
                    clock: clock,
                    aes128KeySet: aes128KeySet,
                    pathwayID: plan.pathwayID,
                    contentSteeringSession:
                        plan.contentSteeringSession,
                    contentSteeringRecovery: contentSteeringRecovery
                ),
                maximumConcurrentTransfers:
                    configuration.maximumConcurrentResourceTransfers
            )
            let preparedWorkspace: HLSDownloadWorkspace
            switch configuration.resumePolicy {
            case .automatic:
                let store = HLSResumeStore(
                    destinationURL: destinationURL
                )
                resumeStore = store
                preparedWorkspace = try store.prepare(
                    sourceURL: sourceURL,
                    mediaPlaylistIdentity: plan.mediaPlaylistIdentity,
                    resources: resourcePlan.transfers,
                    aes128KeySet: aes128KeySet,
                    maximumTotalBytes:
                        configuration.maximumTotalDownloadBytes
                )
            case .disabled:
                try HLSResumeStore(
                    destinationURL: destinationURL
                ).cleanup()
                preparedWorkspace = try Self.makeEphemeralWorkspace(
                    destinationURL: destinationURL
                )
            }
            workspace = preparedWorkspace
            let activeResumeStore = resumeStore

            let fileHandle = try FileHandle(
                forWritingTo: preparedWorkspace.partialURL
            )
            defer {
                try? fileHandle.close()
            }
            try fileHandle.seekToEnd()

            onProgress(
                HLSDownloadProgress(
                    bytesWritten: 0,
                    totalBytesWritten:
                        preparedWorkspace.assembledByteCount,
                    totalBytesExpectedToWrite: nil
                )
            )
            let budget = HLSDownloadBudget(
                maximumTotalBytes:
                    configuration.maximumTotalDownloadBytes,
                resourceCount: resourcePlan.transfers.count,
                initialBytesWritten:
                    preparedWorkspace.assembledByteCount
            ) { progress in
                onProgress(progress)
            }
            try await resourcePipeline.assemble(
                resources: resourcePlan.transfers,
                startingAt: preparedWorkspace.nextResourceIndex,
                into: fileHandle,
                stagingDirectoryURL:
                    preparedWorkspace.stagingDirectoryURL,
                budget: budget,
                diskCapacityGuard: diskCapacityGuard
            ) { nextResourceIndex, assembledByteCount in
                try activeResumeStore?.save(
                    resourceCount: resourcePlan.transfers.count,
                    nextResourceIndex: nextResourceIndex,
                    assembledByteCount: assembledByteCount
                )
            }
            await budget.finish()

            try Task.checkCancellation()
            try fileHandle.synchronize()
            try fileHandle.close()
            let fileSize =
                try preparedWorkspace.partialURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize
            guard let fileSize, fileSize > 0 else {
                throw HLSDownloadError.emptyOutput
            }

            try Task.checkCancellation()
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                throw HLSDownloadError.destinationAlreadyExists
            }
            do {
                try fileManager.moveItem(
                    at: preparedWorkspace.partialURL,
                    to: destinationURL
                )
            } catch {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    throw HLSDownloadError.destinationAlreadyExists
                }
                throw error
            }
            didComplete = true
            try? resumeStore?.cleanup()
            outcome = .completed(
                HLSDownloadReceipt(
                    destinationURL: destinationURL,
                    byteCount: Int64(fileSize),
                    mediaContainer: plan.mediaContainer,
                    selectedVariant: plan.selectedVariant,
                    resumedResourceTransferCount:
                        preparedWorkspace.nextResourceIndex
                )
            )
        } catch is CancellationError {
            outcome = .cancelled
        } catch let error as HLSDownloadError {
            outcome = .failed(error)
        } catch {
            outcome = .failed(.wrappingTransferFailure(error))
        }

        if let workspace {
            try? fileManager.removeItem(
                at: workspace.stagingDirectoryURL
            )
            if configuration.resumePolicy == .disabled || didComplete {
                try? fileManager.removeItem(at: workspace.partialURL)
            }
        }
        return outcome
    }

    private func makeContentSteeringRecovery(
        for plan: HLSResolvedDownloadPlan
    ) -> HLSContentSteeringRecovery? {
        guard
            configuration.contentSteering.allowsTransferFailover,
            let primaryVariant = plan.selectedVariant,
            primaryVariant.stableID != nil,
            plan.pathwayCandidates.count > 1
        else {
            return nil
        }
        return HLSContentSteeringRecovery(
            client: client,
            clock: clock,
            retryPolicy: configuration.retryPolicy,
            maximumTransferBytes:
                configuration.maximumMediaResourceBytes,
            primaryVariant: primaryVariant,
            primaryContainer: plan.mediaContainer,
            primaryTransfers: plan.resourcePlan.transfers,
            candidates: plan.pathwayCandidates,
            contentSteeringSession: plan.contentSteeringSession
        )
    }

    private static func makeEphemeralWorkspace(
        destinationURL: URL
    ) throws -> HLSDownloadWorkspace {
        let parentURL = destinationURL.deletingLastPathComponent()
        let partialURL = parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent)."
                + "\(UUID().uuidString).part"
        )
        let stagingDirectoryURL = parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent)."
                + "\(UUID().uuidString).hls-staging",
            isDirectory: true
        )
        guard
            FileManager.default.createFile(
                atPath: partialURL.path,
                contents: nil
            )
        else {
            throw HLSDownloadError.internalTransferFailure(
                "The partial output file could not be created.",
                code: 1
            )
        }
        return HLSDownloadWorkspace(
            partialURL: partialURL,
            stagingDirectoryURL: stagingDirectoryURL,
            nextResourceIndex: 0,
            assembledByteCount: 0
        )
    }

}
