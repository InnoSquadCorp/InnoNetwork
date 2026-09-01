import Foundation
import InnoNetworkHLS

private enum HLSLiveDVRRecordingMode: Sendable {
    case fresh
    case resume
}

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

    /// Records until the source ends or the configured retention policy
    /// finishes the recording at a duration, segment-count, or byte limit.
    ///
    /// Only the atomically committed package becomes visible at
    /// `destinationDirectoryURL`. The default removes staging after
    /// interruption; opt-in recovery preserves only its last durable complete-
    /// segment checkpoint.
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

    /// Starts a bounded recording with explicit stop, commit, and discard
    /// control.
    ///
    /// Retain the returned handle for the recording lifetime. Progress and
    /// the terminal receipt are available from ``HLSLiveDVRRecording/events``.
    public func startRecording(
        from sourceURL: URL,
        to destinationDirectoryURL: URL
    ) -> HLSLiveDVRRecording {
        makeRecording(
            from: sourceURL,
            to: destinationDirectoryURL,
            mode: .fresh
        )
    }

    /// Resumes an opt-in recording from its last complete-segment checkpoint.
    ///
    /// The caller supplies a fresh source URL. Query and fragment values are
    /// excluded from source identity so an expired signed URL can be replaced.
    public func resumeRecording(
        from sourceURL: URL,
        to destinationDirectoryURL: URL
    ) -> HLSLiveDVRRecording {
        makeRecording(
            from: sourceURL,
            to: destinationDirectoryURL,
            mode: .resume
        )
    }

    /// Resumes an opt-in recording and waits for its atomic commit.
    ///
    /// The caller supplies a fresh source URL. Query and fragment values are
    /// excluded from source identity so an expired signed URL can be replaced.
    public func resume(
        from sourceURL: URL,
        to destinationDirectoryURL: URL
    ) async throws -> HLSLiveDVRReceipt {
        try await execute(
            sourceURL: sourceURL,
            destinationDirectoryURL: destinationDirectoryURL,
            mode: .resume,
            onProgress: { _ in }
        )
    }

    /// Removes an owned recovery checkpoint without touching a committed
    /// destination.
    public func discardRecovery(
        for destinationDirectoryURL: URL
    ) async throws {
        guard destinationDirectoryURL.isFileURL else {
            throw HLSLiveDVRError.invalidDestination
        }
        let lease: HLSDestinationLease
        do {
            lease = try await HLSDestinationLease.acquire(
                for: destinationDirectoryURL
            )
        } catch HLSDownloadError.destinationInUse {
            throw HLSLiveDVRError.destinationInUse
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
        do {
            try HLSLiveDVRCheckpointStore(
                destinationURL: destinationDirectoryURL
            ).cleanup()
            await lease.release()
        } catch {
            await lease.release()
            throw error
        }
    }

    private func makeRecording(
        from sourceURL: URL,
        to destinationDirectoryURL: URL,
        mode: HLSLiveDVRRecordingMode
    ) -> HLSLiveDVRRecording {
        let (stream, continuation) =
            AsyncThrowingStream<
                HLSLiveDVREvent,
                Error
            >.makeStream(
                bufferingPolicy: .bufferingNewest(64)
            )
        let control = HLSLiveDVRRecordingControl()
        let recorder = self
        let task = Task<HLSLiveDVRReceipt, Error> {
            do {
                let receipt = try await recorder.execute(
                    sourceURL: sourceURL,
                    destinationDirectoryURL:
                        destinationDirectoryURL,
                    control: control,
                    mode: mode
                ) {
                    continuation.yield(.progress($0))
                }
                await control.finishPlaybackSnapshotRequests()
                continuation.yield(.completed(receipt))
                continuation.finish()
                return receipt
            } catch is CancellationError {
                await control.finishPlaybackSnapshotRequests()
                continuation.finish()
                throw CancellationError()
            } catch {
                await control.finishPlaybackSnapshotRequests()
                continuation.finish(throwing: error)
                throw error
            }
        }
        return HLSLiveDVRRecording(
            events: stream,
            control: control,
            task: task
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
        control: HLSLiveDVRRecordingControl? = nil,
        mode: HLSLiveDVRRecordingMode = .fresh,
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
                control: control,
                mode: mode,
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
        control: HLSLiveDVRRecordingControl?,
        mode: HLSLiveDVRRecordingMode,
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

        let checkpointStore: HLSLiveDVRCheckpointStore?
        var pendingCheckpoint: HLSLiveDVRCheckpoint?
        let workspace: HLSLiveDVRWorkspace
        switch (configuration.recovery.policy, mode) {
        case (.disabled, .fresh):
            checkpointStore = nil
            pendingCheckpoint = nil
            workspace = try HLSLiveDVRWorkspace.make(
                for: destinationDirectoryURL
            )
        case (.disabled, .resume):
            throw HLSLiveDVRError.recoveryDisabled
        case (.resumable, .fresh):
            let store = HLSLiveDVRCheckpointStore(
                destinationURL: destinationDirectoryURL
            )
            checkpointStore = store
            pendingCheckpoint = nil
            workspace = try store.prepareFresh()
        case (.resumable, .resume):
            let store = HLSLiveDVRCheckpointStore(
                destinationURL: destinationDirectoryURL
            )
            let recovery = try store.resume(sourceURL: sourceURL)
            checkpointStore = store
            pendingCheckpoint = recovery.1
            workspace = recovery.0
        }
        var committed = false
        var preservesRecovery = pendingCheckpoint != nil
        var checkpointedFilePaths = Set(
            pendingCheckpoint?.files.map(\.relativePath) ?? []
        )
        defer {
            if !committed {
                if let checkpointStore {
                    if !preservesRecovery {
                        try? checkpointStore.cleanup()
                    }
                } else {
                    try? fileManager.removeItem(
                        at: workspace.directoryURL
                    )
                }
            }
        }

        var state = HLSLiveDVRRecordingState(
            configuration: configuration,
            workspace: workspace
        )
        let usesRollingRetention =
            configuration.limits.retentionPolicy == .rollingWindow
        let resourceContext = resourceWriter.makeContext(
            workspace: workspace
        )
        let preloadCoordinator = resourceWriter.makePreloadCoordinator(
            workspace: workspace,
            context: resourceContext
        )
        let interstitialPackager = HLSLiveDVRInterstitialPackager(
            client: liveClient.resourceClient,
            configuration: configuration
        )
        let snapshots:
            AsyncThrowingStream<
                HLSLivePlaylistSnapshot,
                Error
            >
        var snapshotRelayTask: Task<Void, Never>?
        if let control {
            let (stream, continuation) =
                AsyncThrowingStream<
                    HLSLivePlaylistSnapshot,
                    Error
                >.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
            let client = liveClient
            let task = Task {
                do {
                    for try await snapshot in client.snapshots(
                        from: sourceURL
                    ) {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            await control.installSnapshotRelayTask(task)
            snapshots = stream
            snapshotRelayTask = task
        } else {
            snapshots = liveClient.snapshots(from: sourceURL)
        }
        defer {
            snapshotRelayTask?.cancel()
        }
        do {
            recordingLoop: for try await snapshot in snapshots {
                if let control,
                    await control.shouldStopAndCommit
                {
                    break recordingLoop
                }
                if let checkpoint = pendingCheckpoint {
                    try state.restore(checkpoint, in: snapshot)
                    pendingCheckpoint = nil
                }
                try state.validatePresentation(snapshot)
                try await interstitialPackager.update(
                    from: snapshot,
                    state: &state
                )
                await preloadCoordinator?.update(from: snapshot)
                if let statistics = await preloadCoordinator?
                    .statisticsSnapshot()
                {
                    state.preloadStatistics = statistics
                }
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
                    preloadCoordinator: preloadCoordinator,
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
                    let availableRenditionCandidates =
                        try state
                        .renditionCandidates(
                            in: renditionSnapshot,
                            at: request.index
                        )
                    let renditionCandidates =
                        rollingRenditionCandidates(
                            availableRenditionCandidates,
                            primaryCandidates: candidates,
                            usesRollingRetention: usesRollingRetention
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
                                    for: segment,
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
                var didRetainPrimarySegment = false
                for segment in candidates {
                    guard state.canRetain(segment) else {
                        if usesRollingRetention {
                            throw HLSLiveDVRError.storageFailed
                        }
                        break recordingLoop
                    }
                    try state.validate(segment)
                    guard
                        try await resourceWriter
                            .retainInitializationIfNeeded(
                                for: segment,
                                state: &state,
                                context: resourceContext,
                                preloadCoordinator:
                                    preloadCoordinator
                            )
                    else {
                        if usesRollingRetention {
                            throw HLSLiveDVRError.storageFailed
                        }
                        break recordingLoop
                    }
                    let didRetain = try await resourceWriter.retain(
                        segment,
                        state: &state,
                        context: resourceContext
                    )
                    guard didRetain else {
                        try resourceWriter
                            .discardUnreferencedInitialization(
                                for: segment,
                                state: &state
                            )
                        if usesRollingRetention {
                            throw HLSLiveDVRError.storageFailed
                        }
                        break recordingLoop
                    }
                    didRetainPrimarySegment = true
                    if let statistics = await preloadCoordinator?
                        .statisticsSnapshot()
                    {
                        state.preloadStatistics = statistics
                    }
                    if !usesRollingRetention {
                        try persistRetainedBoundary(
                            sourceURL: sourceURL,
                            checkpointStore: checkpointStore,
                            checkpointedFilePaths:
                                &checkpointedFilePaths,
                            preservesRecovery: &preservesRecovery,
                            state: &state
                        )
                        await fulfillPlaybackSnapshotRequests(
                            control: control,
                            state: state
                        )
                    }
                    if !usesRollingRetention {
                        onProgress(state.progress)
                        if let control,
                            await control.shouldStopAndCommit
                        {
                            break recordingLoop
                        }
                        if state.reachedLimit {
                            break recordingLoop
                        }
                    }
                }
                if usesRollingRetention, didRetainPrimarySegment {
                    try state.finalizeRollingPresentation()
                    try persistRetainedBoundary(
                        sourceURL: sourceURL,
                        checkpointStore: checkpointStore,
                        checkpointedFilePaths: &checkpointedFilePaths,
                        preservesRecovery: &preservesRecovery,
                        state: &state
                    )
                    await fulfillPlaybackSnapshotRequests(
                        control: control,
                        state: state
                    )
                    onProgress(state.progress)
                    if let control,
                        await control.shouldStopAndCommit
                    {
                        break recordingLoop
                    }
                }
                if snapshot.isEnded {
                    break
                }
            }
        } catch is CancellationError {
            _ = await preloadCoordinator?.cancelAll()
            if let control,
                await control.shouldCancelAndDiscard
            {
                preservesRecovery = false
            }
            throw CancellationError()
        } catch let error as HLSLiveDVRError {
            _ = await preloadCoordinator?.cancelAll()
            throw error
        } catch let error as HLSDownloadError {
            _ = await preloadCoordinator?.cancelAll()
            switch error {
            case .separateAudioRenditionUnsupported:
                throw HLSLiveDVRError.unsupportedFeature(
                    .externalRendition
                )
            default:
                throw HLSLiveDVRError.transferFailed
            }
        } catch {
            _ = await preloadCoordinator?.cancelAll()
            throw HLSLiveDVRError.transferFailed
        }

        if let statistics = await preloadCoordinator?.cancelAll() {
            state.preloadStatistics = statistics
        }
        if let control,
            await control.shouldCancelAndDiscard
        {
            preservesRecovery = false
            throw CancellationError()
        }
        try Task.checkCancellation()
        try resourceWriter.discardAllStagedParts(state: &state)
        try resourceWriter.discard(
            state.takePendingEvictionFilePaths(),
            workspace: state.workspace
        )
        let receipt = try state.commit(
            to: destinationDirectoryURL
        )
        committed = true
        try? checkpointStore?.cleanup()
        return receipt
    }

    private func fulfillPlaybackSnapshotRequests(
        control: HLSLiveDVRRecordingControl?,
        state: HLSLiveDVRRecordingState
    ) async {
        guard let control else {
            return
        }
        let requests = await control.takePlaybackSnapshotRequests()
        var processableRequests: [HLSLiveDVRPlaybackSnapshotRequest] = []
        for request in requests {
            if await request.shouldProcess {
                processableRequests.append(request)
            } else {
                await control.completePlaybackSnapshotRequest(request)
            }
        }
        guard !processableRequests.isEmpty else {
            return
        }
        let sharedSnapshot: HLSLiveDVRSharedPlaybackSnapshot
        do {
            sharedSnapshot = HLSLiveDVRSharedPlaybackSnapshot(
                snapshot: try state.freezePlaybackSnapshot(),
                userCount: processableRequests.count
            )
        } catch let error as HLSLiveDVRError {
            for request in processableRequests {
                await request.fail(error)
                await control.completePlaybackSnapshotRequest(request)
            }
            return
        } catch {
            for request in processableRequests {
                await request.fail(.storageFailed)
                await control.completePlaybackSnapshotRequest(request)
            }
            return
        }
        for request in processableRequests {
            let task = Task<HLSLiveDVRReceipt, Error> {
                do {
                    let receipt = try await capturePlaybackSnapshot(
                        to: request.destinationDirectoryURL,
                        snapshot: sharedSnapshot.snapshot
                    )
                    await sharedSnapshot.release()
                    return receipt
                } catch {
                    await sharedSnapshot.release()
                    throw error
                }
            }
            guard await request.installOperationTask(task) else {
                Task {
                    _ = try? await task.value
                    await control.completePlaybackSnapshotRequest(request)
                }
                continue
            }
            Task {
                do {
                    await request.succeed(try await task.value)
                } catch is CancellationError {
                    await request.cancel()
                } catch let error as HLSLiveDVRError {
                    await request.fail(error)
                } catch {
                    await request.fail(.storageFailed)
                }
                await control.completePlaybackSnapshotRequest(request)
            }
        }
    }

    private func capturePlaybackSnapshot(
        to destinationDirectoryURL: URL,
        snapshot: HLSLiveDVRFrozenPlaybackSnapshot
    ) async throws -> HLSLiveDVRReceipt {
        let lease: HLSDestinationLease
        do {
            lease = try await HLSDestinationLease.acquire(
                for: destinationDirectoryURL
            )
        } catch HLSDownloadError.destinationInUse {
            throw HLSLiveDVRError.destinationInUse
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
        do {
            let receipt = try await snapshot.publish(
                to: destinationDirectoryURL
            )
            await lease.release()
            return receipt
        } catch {
            await lease.release()
            throw error
        }
    }

    private func persistRetainedBoundary(
        sourceURL: URL,
        checkpointStore: HLSLiveDVRCheckpointStore?,
        checkpointedFilePaths: inout Set<String>,
        preservesRecovery: inout Bool,
        state: inout HLSLiveDVRRecordingState
    ) throws {
        if let checkpointStore {
            try resourceWriter.discardAllStagedParts(state: &state)
            let checkpoint = try state.checkpoint(sourceURL: sourceURL)
            let newFiles = checkpoint.files.filter {
                !checkpointedFilePaths.contains($0.relativePath)
            }
            try checkpointStore.save(
                checkpoint,
                synchronizing: newFiles
            )
            checkpointedFilePaths = Set(
                checkpoint.files.map(\.relativePath)
            )
            preservesRecovery = true
        }
        try resourceWriter.discard(
            state.takePendingEvictionFilePaths(),
            workspace: state.workspace
        )
    }

    private func rollingRenditionCandidates(
        _ candidates: [HLSLiveSegment],
        primaryCandidates: [HLSLiveSegment],
        usesRollingRetention: Bool
    ) -> [HLSLiveSegment] {
        guard usesRollingRetention else {
            return candidates
        }
        guard let lastPrimary = primaryCandidates.last else {
            return []
        }
        if let primaryStart = lastPrimary.programDateTime {
            let primaryEnd = primaryStart.addingTimeInterval(
                lastPrimary.duration
            )
            let datedPrefix = candidates.prefix { candidate in
                guard let candidateStart = candidate.programDateTime else {
                    return false
                }
                return candidateStart
                    < primaryEnd.addingTimeInterval(0.5)
            }
            if candidates.contains(where: {
                $0.programDateTime != nil
            }) {
                return Array(datedPrefix)
            }
        }
        let primarySequences = Set(
            primaryCandidates.map(\.sequenceNumber)
        )
        if candidates.contains(where: {
            primarySequences.contains($0.sequenceNumber)
        }) {
            return candidates.filter {
                $0.sequenceNumber <= lastPrimary.sequenceNumber
            }
        }
        return candidates
    }

    private func stageParts(
        _ update: HLSLiveDVRPartUpdate,
        state: inout HLSLiveDVRRecordingState,
        context: HLSLiveDVRResourceContext,
        preloadCoordinator: HLSLiveDVRPreloadCoordinator?,
        onProgress:
            @escaping @Sendable (HLSLiveDVRProgress) -> Void
    ) async throws {
        try resourceWriter.discard(
            update.discardedFilePaths,
            workspace: state.workspace
        )
        for candidate in update.candidates {
            do {
                let didStage = try await resourceWriter.stage(
                    candidate,
                    state: &state,
                    context: context,
                    preloadCoordinator: preloadCoordinator
                )
                if let statistics = await preloadCoordinator?
                    .statisticsSnapshot()
                {
                    state.preloadStatistics = statistics
                }
                guard didStage else {
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
                if let statistics = await preloadCoordinator?
                    .statisticsSnapshot()
                {
                    state.preloadStatistics = statistics
                }
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
