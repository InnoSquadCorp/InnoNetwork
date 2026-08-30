import Darwin
import Foundation
import InnoNetworkHLS

/// Records complete live segments into one bounded local HLS package.
public struct HLSLiveDVRRecorder: Sendable {
    private let liveClient: HLSLivePlaylistClient
    private let resourceLoader: HLSLiveDVRResourceLoader
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
        self.resourceLoader = HLSLiveDVRResourceLoader(
            client: client.resourceClient,
            requestTimeout:
                configuration.limits.requestTimeout
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

        let workspace = try makeWorkspace(
            destinationDirectoryURL: destinationDirectoryURL
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
        let resourceContext = HLSLiveDVRResourceContext(
            keyCache: HLSAES128KeyCache(
                client: liveClient.resourceClient
            ),
            diskCapacityGuard: HLSDiskCapacityGuard(
                directoryURL: workspace.directoryURL,
                policy: configuration.limits.diskCapacityPolicy
            )
        )
        do {
            recordingLoop: for try await snapshot in liveClient.snapshots(from: sourceURL) {
                try state.validatePresentation(snapshot)
                let candidates = try state.candidates(
                    in: snapshot
                )
                for segment in candidates {
                    guard state.canRetain(segment) else {
                        break recordingLoop
                    }
                    try state.validate(segment)
                    guard
                        try await retainInitializationIfNeeded(
                            state: &state,
                            resourceContext: resourceContext
                        )
                    else {
                        break recordingLoop
                    }
                    guard
                        try await retain(
                            segment,
                            state: &state,
                            resourceContext: resourceContext
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
        let receipt = try state.commit(
            to: destinationDirectoryURL
        )
        committed = true
        return receipt
    }

    private func retainInitializationIfNeeded(
        state: inout HLSLiveDVRRecordingState,
        resourceContext: HLSLiveDVRResourceContext
    ) async throws -> Bool {
        guard
            state.container == .fragmentedMP4,
            state.initializationFileName == nil
        else {
            return true
        }
        guard let initialization = state.initializationSegment else {
            throw HLSLiveDVRError.unsupportedFeature(
                .missingInitializationSegment
            )
        }
        let fallbackExtension = "mp4"
        let path =
            "resources/initialization."
            + HLSLiveDVRPlaylistWriter.fileExtension(
                for: initialization.url,
                fallback: fallbackExtension
            )
        let destinationURL =
            state.workspace.directoryURL
            .appendingPathComponent(path)
        let result = try await load(
            sourceURL: initialization.url,
            byteRange: initialization.byteRange,
            encryption: initialization.encryption,
            resourceIndex: state.nextResourceIndex,
            destinationURL: destinationURL,
            state: state,
            resourceContext: resourceContext
        )
        switch result {
        case .retained(let byteCount):
            try state.retainInitialization(
                fileName: path,
                byteCount: byteCount
            )
            return true
        case .totalLimitReached:
            return false
        }
    }

    private func retain(
        _ segment: HLSLiveSegment,
        state: inout HLSLiveDVRRecordingState,
        resourceContext: HLSLiveDVRResourceContext
    ) async throws -> Bool {
        let fallbackExtension: String
        switch state.container {
        case .mpegTransportStream:
            fallbackExtension = "ts"
        case .fragmentedMP4:
            fallbackExtension = "m4s"
        case nil:
            throw HLSLiveDVRError.unsupportedFeature(
                .unknownMediaContainer
            )
        }
        let path = String(
            format:
                "resources/%05d.%@",
            state.segments.count,
            HLSLiveDVRPlaylistWriter.fileExtension(
                for: segment.url,
                fallback: fallbackExtension
            )
        )
        let destinationURL =
            state.workspace.directoryURL
            .appendingPathComponent(path)
        let result = try await load(
            sourceURL: segment.url,
            byteRange: segment.byteRange,
            encryption: segment.encryption,
            resourceIndex: state.nextResourceIndex,
            destinationURL: destinationURL,
            state: state,
            resourceContext: resourceContext
        )
        switch result {
        case .retained(let byteCount):
            try state.retain(
                segment,
                fileName: path,
                byteCount: byteCount
            )
            return true
        case .totalLimitReached:
            return false
        }
    }

    private func load(
        sourceURL: URL,
        byteRange: HLSByteRange?,
        encryption: HLSLiveAES128Encryption?,
        resourceIndex: Int,
        destinationURL: URL,
        state: HLSLiveDVRRecordingState,
        resourceContext: HLSLiveDVRResourceContext
    ) async throws -> HLSLiveDVRLoadResult {
        let remainingBytes =
            configuration.limits.maximumTotalMediaBytes
            - state.mediaByteCount
        guard remainingBytes > 0 else {
            return .totalLimitReached
        }
        let maximumRetainedBytes64 = min(
            Int64(configuration.limits.maximumMediaResourceBytes),
            remainingBytes,
            Int64(Int.max)
        )
        guard maximumRetainedBytes64 > 0 else {
            return .totalLimitReached
        }
        let paddingAllowance: Int64 = encryption == nil ? 0 : 16
        let (totalBoundedTransferBytes, transferOverflow) =
            maximumRetainedBytes64.addingReportingOverflow(
                paddingAllowance
            )
        let maximumBytes64 = min(
            Int64(configuration.limits.maximumMediaResourceBytes),
            transferOverflow ? .max : totalBoundedTransferBytes,
            Int64(Int.max)
        )
        do {
            return .retained(
                try await resourceLoader.load(
                    from: sourceURL,
                    byteRange: byteRange,
                    encryption: encryption,
                    resourceIndex: resourceIndex,
                    maximumBytes: Int(maximumBytes64),
                    maximumRetainedBytes:
                        Int(maximumRetainedBytes64),
                    keyCache: resourceContext.keyCache,
                    diskCapacityGuard:
                        resourceContext.diskCapacityGuard,
                    destinationURL: destinationURL
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HLSLiveDVRResourceLoadError {
            switch error {
            case .bodyLimitExceeded:
                if maximumBytes64
                    < Int64(
                        configuration.limits.maximumMediaResourceBytes
                    )
                {
                    return .totalLimitReached
                }
                throw HLSLiveDVRError.mediaResourceTooLarge
            case .retainedLimitExceeded:
                return .totalLimitReached
            case .invalidByteRangeResponse:
                throw HLSLiveDVRError.invalidByteRangeResponse
            case .invalidResponseStatus(let statusCode):
                throw
                    HLSLiveDVRError
                    .invalidMediaResponseStatus(statusCode)
            case .emptyResponse, .transferFailed:
                throw HLSLiveDVRError.transferFailed
            }
        } catch let error as HLSLiveDVRError {
            throw error
        } catch let error as HLSDownloadError {
            switch error {
            case .invalidAES128Key:
                throw HLSLiveDVRError.invalidEncryptionKey
            case .invalidAES128KeyResponseStatus(let statusCode):
                throw
                    HLSLiveDVRError
                    .invalidEncryptionKeyResponseStatus(statusCode)
            case .aes128DecryptionFailed:
                throw HLSLiveDVRError.decryptionFailed
            case .diskCapacityUnavailable:
                throw HLSLiveDVRError.diskCapacityUnavailable
            case .insufficientDiskCapacity(let required, let available):
                throw HLSLiveDVRError.insufficientDiskCapacity(
                    required: required,
                    available: available
                )
            default:
                throw HLSLiveDVRError.transferFailed
            }
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
    }

    private func makeWorkspace(
        destinationDirectoryURL: URL
    ) throws -> HLSLiveDVRWorkspace {
        let fileManager = FileManager.default
        let parentURL =
            destinationDirectoryURL.deletingLastPathComponent()
        let directoryURL = parentURL.appendingPathComponent(
            ".\(destinationDirectoryURL.lastPathComponent)."
                + "\(UUID().uuidString).live-dvr-staging",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at:
                    directoryURL.appendingPathComponent(
                        "resources",
                        isDirectory: true
                    ),
                withIntermediateDirectories: true
            )
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
        return HLSLiveDVRWorkspace(
            directoryURL: directoryURL
        )
    }
}

private enum HLSLiveDVRLoadResult {
    case retained(Int64)
    case totalLimitReached
}

private struct HLSLiveDVRWorkspace: Sendable {
    let directoryURL: URL
}

private struct HLSLiveDVRResourceContext: Sendable {
    let keyCache: HLSAES128KeyCache
    let diskCapacityGuard: HLSDiskCapacityGuard
}

private struct HLSLiveDVRRecordingState {
    let configuration: HLSLiveDVRConfiguration
    let workspace: HLSLiveDVRWorkspace

    private(set) var container: HLSMediaContainer?
    private(set) var initializationSegment: HLSLiveInitializationSegment?
    private(set) var initializationFileName: String?
    private(set) var segments: [HLSLiveDVRStoredSegment] = []
    private(set) var recordedDuration: TimeInterval = 0
    private(set) var mediaByteCount: Int64 = 0
    private(set) var lastObservedSequence: Int64?
    private(set) var didObserveInitialSnapshot = false
    private(set) var nextResourceIndex = 0

    var reachedLimit: Bool {
        segments.count >= configuration.limits.maximumSegmentCount
            || recordedDuration
                >= configuration.limits.maximumDuration
            || mediaByteCount
                >= configuration.limits.maximumTotalMediaBytes
    }

    var progress: HLSLiveDVRProgress {
        HLSLiveDVRProgress(
            segmentCount: segments.count,
            recordedDuration: recordedDuration,
            mediaByteCount: mediaByteCount
        )
    }

    mutating func validatePresentation(
        _ snapshot: HLSLivePlaylistSnapshot
    ) throws {
        guard let snapshotContainer = snapshot.playlist.mediaContainer else {
            throw HLSLiveDVRError.unsupportedFeature(
                .unknownMediaContainer
            )
        }
        if let container, container != snapshotContainer {
            throw HLSLiveDVRError.unsupportedFeature(
                .changingInitializationSegment
            )
        }
        container = snapshotContainer

        if let encryptionMethod = snapshot.encryptionMethod,
            encryptionMethod != "AES-128"
        {
            throw HLSLiveDVRError.unsupportedFeature(
                .encryptedMedia
            )
        }

        if let selectedVariant = snapshot.selectedVariant,
            selectedVariant.audioGroupID != nil
                || selectedVariant.videoGroupID != nil
                || selectedVariant.subtitleGroupID != nil
        {
            throw HLSLiveDVRError.unsupportedFeature(
                .externalRendition
            )
        }
        if snapshot.dateRanges.contains(where: {
            $0.interstitial != nil
                || $0.externalResource != nil
                || $0.preload != nil
        }) {
            throw HLSLiveDVRError.unsupportedFeature(
                .externalTimelineResource
            )
        }

        guard snapshot.initializationSegments.count <= 1 else {
            throw HLSLiveDVRError.unsupportedFeature(
                .changingInitializationSegment
            )
        }
        let candidate = snapshot.initializationSegments.first
        switch snapshotContainer {
        case .mpegTransportStream:
            guard candidate == nil else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .changingInitializationSegment
                )
            }
        case .fragmentedMP4:
            guard let candidate else {
                throw HLSLiveDVRError.unsupportedFeature(
                    .missingInitializationSegment
                )
            }
            if let initializationSegment,
                initializationSegment != candidate
            {
                throw HLSLiveDVRError.unsupportedFeature(
                    .changingInitializationSegment
                )
            }
            initializationSegment = candidate
        }
    }

    mutating func candidates(
        in snapshot: HLSLivePlaylistSnapshot
    ) throws -> [HLSLiveSegment] {
        try validateSequence(snapshot.segments)
        if !didObserveInitialSnapshot {
            didObserveInitialSnapshot = true
            if configuration.startPosition
                == .nextCompletedSegment
            {
                lastObservedSequence =
                    snapshot.segments.last?.sequenceNumber
                return []
            }
        }

        let candidates: [HLSLiveSegment]
        if let lastObservedSequence {
            candidates = snapshot.segments.filter {
                $0.sequenceNumber > lastObservedSequence
            }
            if let first = candidates.first {
                let (expected, overflow) =
                    lastObservedSequence.addingReportingOverflow(1)
                guard
                    !overflow,
                    first.sequenceNumber == expected
                else {
                    throw HLSLiveDVRError.liveWindowAdvanced
                }
            }
        } else {
            candidates = snapshot.segments
        }
        return candidates
    }

    func canRetain(_ segment: HLSLiveSegment) -> Bool {
        guard
            segments.count
                < configuration.limits.maximumSegmentCount
        else {
            return false
        }
        let nextDuration = recordedDuration + segment.duration
        return nextDuration.isFinite
            && nextDuration
                <= configuration.limits.maximumDuration
    }

    func validate(_ segment: HLSLiveSegment) throws {
        guard segment.duration.isFinite, segment.duration > 0 else {
            throw HLSLiveDVRError.transferFailed
        }
        guard !segment.isGap else {
            throw HLSLiveDVRError.unsupportedFeature(.gap)
        }
    }

    mutating func retainInitialization(
        fileName: String,
        byteCount: Int64
    ) throws {
        try addMediaBytes(byteCount)
        initializationFileName = fileName
        nextResourceIndex += 1
    }

    mutating func retain(
        _ segment: HLSLiveSegment,
        fileName: String,
        byteCount: Int64
    ) throws {
        let nextDuration = recordedDuration + segment.duration
        guard nextDuration.isFinite else {
            throw HLSLiveDVRError.storageFailed
        }
        try addMediaBytes(byteCount)
        segments.append(
            HLSLiveDVRStoredSegment(
                sequenceNumber: segment.sequenceNumber,
                duration: segment.duration,
                beginsDiscontinuity:
                    segment.beginsDiscontinuity,
                fileName: fileName
            )
        )
        recordedDuration = nextDuration
        lastObservedSequence = segment.sequenceNumber
        nextResourceIndex += 1
    }

    func commit(
        to destinationDirectoryURL: URL
    ) throws -> HLSLiveDVRReceipt {
        try Task.checkCancellation()
        guard
            let container,
            let first = segments.first,
            let last = segments.last
        else {
            throw HLSLiveDVRError.noSegmentsRecorded
        }
        let playlist: String
        do {
            playlist = try HLSLiveDVRPlaylistWriter.make(
                container: container,
                initializationFileName:
                    initializationFileName,
                segments: segments
            )
        } catch let error as HLSLiveDVRError {
            throw error
        } catch {
            throw HLSLiveDVRError.storageFailed
        }

        let stagedPlaylistURL =
            workspace.directoryURL.appendingPathComponent(
                "index.m3u8"
            )
        do {
            try Data(playlist.utf8).write(
                to: stagedPlaylistURL,
                options: .atomic
            )
        } catch {
            throw HLSLiveDVRError.storageFailed
        }

        try Task.checkCancellation()
        let fileManager = FileManager.default
        guard
            !HLSLiveDVRFileSystem.itemExists(
                at: destinationDirectoryURL
            )
        else {
            throw HLSLiveDVRError.destinationAlreadyExists
        }
        do {
            try fileManager.moveItem(
                at: workspace.directoryURL,
                to: destinationDirectoryURL
            )
        } catch {
            if HLSLiveDVRFileSystem.itemExists(
                at: destinationDirectoryURL
            ) {
                throw HLSLiveDVRError.destinationAlreadyExists
            }
            throw HLSLiveDVRError.storageFailed
        }

        return HLSLiveDVRReceipt(
            directoryURL: destinationDirectoryURL,
            playlistURL:
                destinationDirectoryURL.appendingPathComponent(
                    "index.m3u8"
                ),
            segmentCount: segments.count,
            recordedDuration: recordedDuration,
            mediaByteCount: mediaByteCount,
            firstMediaSequence: first.sequenceNumber,
            lastMediaSequence: last.sequenceNumber
        )
    }

    private mutating func addMediaBytes(
        _ byteCount: Int64
    ) throws {
        let (nextBytes, overflow) =
            mediaByteCount.addingReportingOverflow(byteCount)
        guard
            !overflow,
            nextBytes
                <= configuration.limits.maximumTotalMediaBytes
        else {
            throw HLSLiveDVRError.storageFailed
        }
        mediaByteCount = nextBytes
    }

    private func validateSequence(
        _ segments: [HLSLiveSegment]
    ) throws {
        var previous: Int64?
        for segment in segments {
            if let previous {
                let (expected, overflow) =
                    previous.addingReportingOverflow(1)
                guard
                    !overflow,
                    segment.sequenceNumber == expected
                else {
                    throw HLSLiveDVRError.liveWindowAdvanced
                }
            }
            previous = segment.sequenceNumber
        }
    }
}

private enum HLSLiveDVRFileSystem {
    static func itemExists(at url: URL) -> Bool {
        var information = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return false
            }
            return lstat(path, &information) == 0
        }
    }
}
