import Foundation
import InnoNetwork

enum HLSOfflinePackageOutcome: Sendable {
    case completed(HLSOfflinePackageReceipt)
    case failed(HLSDownloadError)
    case cancelled
}

struct HLSOfflinePackageOperation: Sendable {
    private let planner: HLSOfflinePackagePlanner
    private let configuration: HLSOfflinePackageConfiguration
    private let diskCapacityChecker: HLSDiskCapacityChecker
    private let client: HLSHTTPClient
    private let clock: any InnoNetworkClock

    init(
        client: HLSHTTPClient,
        configuration: HLSOfflinePackageConfiguration,
        diskCapacityChecker: HLSDiskCapacityChecker,
        clock: any InnoNetworkClock
    ) {
        self.planner = HLSOfflinePackagePlanner(
            client: client,
            variantSelectionPolicy:
                configuration.variantSelectionPolicy,
            renditionPack: configuration.renditionPack,
            contentSteering: configuration.contentSteering
        )
        self.configuration = configuration
        self.diskCapacityChecker = diskCapacityChecker
        self.client = client
        self.clock = clock
    }

    func prepare(
        sourceURL: URL
    ) async throws -> HLSOfflinePackagePreparation {
        try await planner.resolve(sourceURL: sourceURL)
            .preparation(sourceURL: sourceURL)
    }

    func perform(
        sourceURL: URL,
        destinationDirectoryURL: URL,
        continuation:
            AsyncStream<HLSOfflinePackageEvent>.Continuation
    ) async {
        let outcome = await execute(
            sourceURL: sourceURL,
            destinationDirectoryURL: destinationDirectoryURL
        ) { progress in
            continuation.yield(.progress(progress))
        }
        switch outcome {
        case .completed(let receipt):
            continuation.yield(.completed(receipt))
        case .failed(let error):
            continuation.yield(.failed(error))
        case .cancelled:
            continuation.yield(.cancelled)
        }
        continuation.finish()
    }

    func execute(
        sourceURL: URL,
        destinationDirectoryURL: URL,
        onProgress:
            @escaping @Sendable (HLSDownloadProgress) -> Void
    ) async -> HLSOfflinePackageOutcome {
        guard destinationDirectoryURL.isFileURL else {
            return .failed(.invalidDestination)
        }
        let destinationLease: HLSDestinationLease
        do {
            destinationLease = try await HLSDestinationLease.acquire(
                for: destinationDirectoryURL
            )
        } catch let error as HLSDownloadError {
            return .failed(error)
        } catch {
            return .failed(.wrappingTransferFailure(error))
        }

        let outcome = await performClaimedDownload(
            sourceURL: sourceURL,
            destinationDirectoryURL: destinationDirectoryURL,
            onProgress: onProgress
        )
        await destinationLease.release()
        return outcome
    }

    private func performClaimedDownload(
        sourceURL: URL,
        destinationDirectoryURL: URL,
        onProgress:
            @escaping @Sendable (HLSDownloadProgress) -> Void
    ) async -> HLSOfflinePackageOutcome {
        let fileManager = FileManager.default
        guard
            !fileManager.fileExists(
                atPath: destinationDirectoryURL.path
            )
        else {
            try? HLSOfflinePackageResumeStore(
                destinationURL: destinationDirectoryURL
            ).cleanup()
            return .failed(.destinationAlreadyExists)
        }

        let parentURL =
            destinationDirectoryURL.deletingLastPathComponent()
        var workspace: HLSOfflinePackageWorkspace?
        var resumeStore: HLSOfflinePackageResumeStore?
        var didCommit = false
        defer {
            if let workspace {
                try? fileManager.removeItem(
                    at: workspace.stagingDirectoryURL
                )
                if configuration.resumePolicy == .disabled, !didCommit {
                    try? fileManager.removeItem(at: workspace.packageURL)
                }
            }
        }

        do {
            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
            try diskCapacityChecker.validate(
                directoryURL: parentURL,
                policy: configuration.diskCapacityPolicy
            )
            let diskCapacityGuard = HLSDiskCapacityGuard(
                checker: diskCapacityChecker,
                directoryURL: parentURL,
                policy: configuration.diskCapacityPolicy
            )
            let plan = try await planner.resolve(
                sourceURL: sourceURL
            )
            let transfersByTrack = plan.tracks.map { track in
                track.resources.map {
                    HLSResourceTransfer(
                        url: $0.url,
                        byteRange: $0.byteRange,
                        encryption: $0.encryption
                    )
                }
            }
            let aes128KeySet = try await HLSAES128KeyResolver(
                client: client,
                retryPolicy: configuration.retryPolicy,
                clock: clock
            ).resolve(resources: transfersByTrack.flatMap { $0 })
            let store = HLSOfflinePackageResumeStore(
                destinationURL: destinationDirectoryURL
            )
            let preparedWorkspace: HLSOfflinePackageWorkspace
            switch configuration.resumePolicy {
            case .automatic:
                resumeStore = store
                preparedWorkspace = try store.prepare(
                    sourceURL: sourceURL,
                    plan: plan,
                    aes128KeySet: aes128KeySet,
                    maximumTotalBytes:
                        configuration.maximumTotalDownloadBytes
                )
            case .disabled:
                try store.cleanup()
                preparedWorkspace = try Self.makeEphemeralWorkspace(
                    destinationDirectoryURL: destinationDirectoryURL
                )
            }
            workspace = preparedWorkspace
            let resumedResourceTransferCount =
                preparedWorkspace.retainedResources.count
            let checkpointWriter = resumeStore.map {
                HLSOfflinePackageCheckpointWriter(
                    store: $0
                )
            }
            let resourcePipeline = HLSOfflineResourcePipeline(
                loader: HLSResourceLoader(
                    client: client,
                    maximumMediaResourceBytes:
                        configuration.maximumMediaResourceBytes,
                    retryPolicy: configuration.retryPolicy,
                    clock: clock,
                    aes128KeySet: aes128KeySet
                ),
                maximumConcurrentTransfers:
                    configuration.maximumConcurrentResourceTransfers
            )
            let budget = HLSDownloadBudget(
                maximumTotalBytes:
                    configuration.maximumTotalDownloadBytes,
                resourceCount: plan.resourceCount,
                initialBytesWritten:
                    preparedWorkspace.retainedByteCount
            ) { progress in
                onProgress(progress)
            }
            onProgress(
                HLSDownloadProgress(
                    bytesWritten: 0,
                    totalBytesWritten:
                        preparedWorkspace.retainedByteCount,
                    totalBytesExpectedToWrite: nil
                )
            )

            var resourceIndexOffset = 0
            for (track, transfers) in zip(
                plan.tracks,
                transfersByTrack
            ) {
                try Task.checkCancellation()
                let trackDirectoryURL =
                    preparedWorkspace.packageURL.appendingPathComponent(
                        track.relativeDirectoryPath,
                        isDirectory: true
                    )
                let resourceFileNames =
                    HLSOfflineMediaPlaylistWriter
                    .resourceFileNames(for: track.resources)
                try await resourcePipeline.persist(
                    resources: transfers,
                    resourceFileNames: resourceFileNames,
                    resourceIndexOffset: resourceIndexOffset,
                    trackRelativeDirectoryPath:
                        track.relativeDirectoryPath,
                    trackDirectoryURL: trackDirectoryURL,
                    stagingDirectoryURL:
                        preparedWorkspace.stagingDirectoryURL
                        .appendingPathComponent(
                            ".staging-\(resourceIndexOffset)",
                            isDirectory: true
                        ),
                    budget: budget,
                    diskCapacityGuard: diskCapacityGuard,
                    retainedResourceByteCounts:
                        preparedWorkspace
                        .retainedResourceByteCounts
                ) { globalIndex, relativePath, fileURL in
                    try await checkpointWriter?.record(
                        index: globalIndex,
                        relativePath: relativePath,
                        fileURL: fileURL
                    )
                }
                let localPlaylist =
                    try HLSOfflineMediaPlaylistWriter.rewrite(
                        contents: track.document.contents,
                        resources: track.resources,
                        resourceFileNames: resourceFileNames
                    )
                try Data(localPlaylist.utf8).write(
                    to: trackDirectoryURL.appendingPathComponent(
                        "index.m3u8"
                    ),
                    options: .atomic
                )
                resourceIndexOffset += track.resources.count
            }
            await budget.finish()

            let entryPlaylistName = "index.m3u8"
            let masterPlaylist =
                try HLSPackageMasterPlaylistWriter.make(plan: plan)
            try Data(masterPlaylist.utf8).write(
                to: preparedWorkspace.packageURL.appendingPathComponent(
                    entryPlaylistName
                ),
                options: .atomic
            )
            try writeManifest(
                plan: plan,
                entryPlaylistName: entryPlaylistName,
                workspaceURL: preparedWorkspace.packageURL,
                resumedResourceTransferCount:
                    resumedResourceTransferCount
            )
            try Task.checkCancellation()

            let byteCount = try Self.packageByteCount(
                at: preparedWorkspace.packageURL
            )
            guard byteCount > 0 else {
                throw HLSDownloadError.emptyOutput
            }
            guard
                !fileManager.fileExists(
                    atPath: destinationDirectoryURL.path
                )
            else {
                throw HLSDownloadError.destinationAlreadyExists
            }
            do {
                try fileManager.moveItem(
                    at: preparedWorkspace.packageURL,
                    to: destinationDirectoryURL
                )
            } catch {
                if fileManager.fileExists(
                    atPath: destinationDirectoryURL.path
                ) {
                    throw HLSDownloadError.destinationAlreadyExists
                }
                throw error
            }
            didCommit = true
            try? resumeStore?.cleanup()
            return .completed(
                HLSOfflinePackageReceipt(
                    directoryURL: destinationDirectoryURL,
                    entryPlaylistURL:
                        destinationDirectoryURL
                        .appendingPathComponent(entryPlaylistName),
                    tracks: plan.tracks.map(\.descriptor),
                    byteCount: byteCount,
                    selectedVariant: plan.selectedVariant,
                    selectedIFrameVariant:
                        plan.selectedIFrameVariant,
                    resumedResourceTransferCount:
                        resumedResourceTransferCount
                )
            )
        } catch is CancellationError {
            return .cancelled
        } catch let error as HLSDownloadError {
            return .failed(error)
        } catch {
            return .failed(.wrappingTransferFailure(error))
        }
    }

    private func writeManifest(
        plan: HLSOfflinePackagePlan,
        entryPlaylistName: String,
        workspaceURL: URL,
        resumedResourceTransferCount: Int
    ) throws {
        let scan = try HLSOfflinePackageIntegrity.scan(
            directoryURL: workspaceURL,
            hashingFiles: true
        )
        let manifest = HLSOfflinePackageManifest(
            entryPlaylistPath: entryPlaylistName,
            tracks: plan.tracks.map(\.descriptor),
            selectedVariant: plan.selectedVariant,
            selectedIFrameVariant: plan.selectedIFrameVariant,
            resumedResourceTransferCount:
                resumedResourceTransferCount,
            files: scan.records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: workspaceURL.appendingPathComponent(
                "manifest.json"
            ),
            options: .atomic
        )
    }

    private static func makeEphemeralWorkspace(
        destinationDirectoryURL: URL
    ) throws -> HLSOfflinePackageWorkspace {
        let parentURL =
            destinationDirectoryURL.deletingLastPathComponent()
        let packageURL = parentURL.appendingPathComponent(
            ".\(destinationDirectoryURL.lastPathComponent)."
                + "\(UUID().uuidString).hls-package",
            isDirectory: true
        )
        let stagingDirectoryURL = parentURL.appendingPathComponent(
            ".\(destinationDirectoryURL.lastPathComponent)."
                + "\(UUID().uuidString).hls-package-staging",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: false
        )
        return HLSOfflinePackageWorkspace(
            packageURL: packageURL,
            stagingDirectoryURL: stagingDirectoryURL,
            retainedResources: []
        )
    }

    private static func packageByteCount(
        at directoryURL: URL
    ) throws -> Int64 {
        try HLSOfflinePackageIntegrity.scan(
            directoryURL: directoryURL,
            hashingFiles: false
        ).byteCount
    }
}
