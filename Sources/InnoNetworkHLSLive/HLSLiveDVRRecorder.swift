import Foundation
import InnoNetworkHLS

/// Records complete live segments into one bounded local HLS package.
public struct HLSLiveDVRRecorder: Sendable {
    private let liveClient: HLSLivePlaylistClient
    private let resourceWriter: HLSLiveDVRResourceWriter
    private let configuration: HLSLiveDVRConfiguration

    /// Creates a recorder backed by the default live client.
    public init(
        configuration: HLSLiveDVRConfiguration = .safeDefaults()
    ) {
        self.init(
            client: HLSLivePlaylistClient(),
            configuration: configuration
        )
    }

    /// Creates a recorder that reuses a configured live client's session,
    /// request policy, variant selection, and Content Steering behavior.
    public init(
        client: HLSLivePlaylistClient,
        configuration: HLSLiveDVRConfiguration = .safeDefaults()
    ) {
        self.liveClient = client
        self.resourceWriter = HLSLiveDVRResourceWriter(
            client: client.resourceClient,
            configuration: configuration
        )
        self.configuration = configuration
    }

    /// Records until a duration, segment-count, or byte limit is reached.
    ///
    /// Only the atomically committed package becomes visible at
    /// `destinationDirectoryURL`. Cancellation and failures remove ephemeral
    /// staging files.
    public func record(
        from sourceURL: URL,
        to destinationDirectoryURL: URL
    ) async throws -> HLSLiveDVRReceipt {
        try await execute(
            sourceURL: sourceURL,
            destinationDirectoryURL: destinationDirectoryURL,
            onProgress: { _ in }
        )
    }

    /// Starts a bounded, independently cancellable recording event stream.
    ///
    /// A slow consumer may miss older progress snapshots, but the newest
    /// progress and terminal receipt remain buffered.
    public func events(
        from sourceURL: URL,
        to destinationDirectoryURL: URL
    ) -> AsyncThrowingStream<HLSLiveDVREvent, Error> {
        let (stream, continuation) =
            AsyncThrowingStream<
                HLSLiveDVREvent,
                Error
            >.makeStream(
                bufferingPolicy: .bufferingNewest(64)
            )
        let recorder = self
        let task = Task {
            do {
                let receipt = try await recorder.execute(
                    sourceURL: sourceURL,
                    destinationDirectoryURL:
                        destinationDirectoryURL
                ) {
                    continuation.yield(.progress($0))
                }
                continuation.yield(.completed(receipt))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    private func execute(
        sourceURL: URL,
        destinationDirectoryURL: URL,
        onProgress:
            @escaping @Sendable (HLSLiveDVRProgress) -> Void
    ) async throws -> HLSLiveDVRReceipt {
        guard destinationDirectoryURL.isFileURL else {
            throw HLSLiveDVRError.invalidDestination
        }

        let lease: HLSDestinationLease
        do {
            lease = try await HLSDestinationLease.acquire(
                for: destinationDirectoryURL
            )
        } catch let error as HLSDownloadError {
            switch error {
            case .destinationInUse:
                throw HLSLiveDVRError.destinationInUse
            default:
                throw HLSLiveDVRError.storageFailed
            }
        } catch {
            throw HLSLiveDVRError.storageFailed
        }

        do {
            let receipt = try await performRecording(
                from: sourceURL,
                to: destinationDirectoryURL,
                onProgress: onProgress
            )
            await lease.release()
            return receipt
        } catch {
            await lease.release()
            throw error
        }
    }

    private func performRecording(
        from sourceURL: URL,
        to destinationDirectoryURL: URL,
        onProgress:
            @escaping @Sendable (HLSLiveDVRProgress) -> Void
    ) async throws -> HLSLiveDVRReceipt {
        let fileManager = FileManager.default
        guard
            !HLSLiveDVRFileSystem.itemExists(
                at: destinationDirectoryURL
            )
        else {
            throw HLSLiveDVRError.destinationAlreadyExists
        }

        let workspace = try HLSLiveDVRWorkspace.make(
            for: destinationDirectoryURL
        )
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(
                    at: workspace.directoryURL
                )
            }
        }

        var state = HLSLiveDVRRecordingState(
            configuration: configuration,
            workspace: workspace
        )
        let resourceContext = resourceWriter.makeContext(
            workspace: workspace
        )
        do {
            recordingLoop: for try await snapshot in liveClient.snapshots(from: sourceURL) {
                try state.validatePresentation(snapshot)
                let candidates = try state.candidates(
                    in: snapshot
                )
                let partUpdate = state.updateStagedParts(
                    from: snapshot
                )
                try await stageParts(
                    partUpdate,
                    state: &state,
                    context: resourceContext,
                    onProgress: onProgress
                )
                let renditionRequests = try state.renditionRequests(
                    in: snapshot
                )
                var renditionSnapshots: [(HLSLiveDVRRenditionRequest, HLSLivePlaylistSnapshot)] = []
                for request in renditionRequests {
                    let renditionSnapshot =
                        try await liveClient
                        .renditionSnapshot(
                            from: request.url,
                            multivariantVariables:
                                request.multivariantVariables,
                            generation: request.generation
                        )
                    try state.validateRendition(
                        renditionSnapshot,
                        at: request.index
                    )
                    renditionSnapshots.append(
                        (request, renditionSnapshot)
                    )
                }
                for (request, renditionSnapshot) in renditionSnapshots {
                    let renditionCandidates =
                        try state
                        .renditionCandidates(
                            in: renditionSnapshot,
                            at: request.index
                        )
                    for segment in renditionCandidates {
                        guard
                            state.canRetainRendition(
                                segment,
                                at: request.index
                            )
                        else {
                            throw HLSLiveDVRError.unsupportedFeature(
                                .incompleteExternalRendition
                            )
                        }
                        try state.validateRenditionSegment(
                            segment,
                            at: request.index
                        )
                        guard
                            try await resourceWriter
                                .retainRenditionInitializationIfNeeded(
                                    at: request.index,
                                    state: &state,
                                    context: resourceContext
                                ),
                            try await resourceWriter.retainRendition(
                                segment,
                                at: request.index,
                                state: &state,
                                context: resourceContext
                            )
                        else {
                            throw HLSLiveDVRError.unsupportedFeature(
                                .incompleteExternalRendition
                            )
                        }
                    }
                }
                for segment in candidates {
                    guard state.canRetain(segment) else {
                        break recordingLoop
                    }
                    try state.validate(segment)
                    guard
                        try await resourceWriter
                            .retainInitializationIfNeeded(
                                state: &state,
                                context: resourceContext
                            )
                    else {
                        break recordingLoop
                    }
                    guard
                        try await resourceWriter.retain(
                            segment,
                            state: &state,
                            context: resourceContext
                        )
                    else {
                        break recordingLoop
                    }
                    onProgress(state.progress)
                    if state.reachedLimit {
                        break recordingLoop
                    }
                }
                if snapshot.isEnded {
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HLSLiveDVRError {
            throw error
        } catch let error as HLSDownloadError {
            switch error {
            case .separateAudioRenditionUnsupported:
                throw HLSLiveDVRError.unsupportedFeature(
                    .externalRendition
                )
            default:
                throw HLSLiveDVRError.transferFailed
            }
        } catch {
            throw HLSLiveDVRError.transferFailed
        }

        try Task.checkCancellation()
        try resourceWriter.discardAllStagedParts(state: &state)
        let receipt = try state.commit(
            to: destinationDirectoryURL
        )
        committed = true
        return receipt
    }

    private func stageParts(
        _ update: HLSLiveDVRPartUpdate,
        state: inout HLSLiveDVRRecordingState,
        context: HLSLiveDVRResourceContext,
        onProgress:
            @escaping @Sendable (HLSLiveDVRProgress) -> Void
    ) async throws {
        try resourceWriter.discard(
            update.discardedFilePaths,
            workspace: state.workspace
        )
        for candidate in update.candidates {
            do {
                guard
                    try await resourceWriter.stage(
                        candidate,
                        state: &state,
                        context: context
                    )
                else {
                    try resourceWriter.abandonStagedParts(
                        mediaSequenceNumber:
                            candidate.part.mediaSequenceNumber,
                        state: &state
                    )
                    return
                }
                onProgress(state.progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try resourceWriter.abandonStagedParts(
                    mediaSequenceNumber:
                        candidate.part.mediaSequenceNumber,
                    state: &state
                )
                return
            }
        }
    }
}
