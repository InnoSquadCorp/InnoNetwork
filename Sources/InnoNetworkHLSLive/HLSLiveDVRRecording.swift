import Foundation

enum HLSLiveDVRRecordingIntent: Sendable {
    case stopAndCommit
    case cancelAndDiscard
}

actor HLSLiveDVRRecordingControl {
    private static let maximumOutstandingPlaybackSnapshotCount = 8

    private var intent: HLSLiveDVRRecordingIntent?
    private var snapshotRelayTask: Task<Void, Never>?
    private var playbackSnapshotRequests: [HLSLiveDVRPlaybackSnapshotRequest] = []
    private var outstandingPlaybackSnapshotRequestIDs: Set<ObjectIdentifier> = []
    private var didFinish = false

    func request(
        _ requestedIntent: HLSLiveDVRRecordingIntent
    ) -> HLSLiveDVRRecordingIntent {
        if let intent {
            return intent
        }
        intent = requestedIntent
        snapshotRelayTask?.cancel()
        return requestedIntent
    }

    func installSnapshotRelayTask(
        _ task: Task<Void, Never>
    ) {
        snapshotRelayTask = task
        if intent != nil {
            task.cancel()
        }
    }

    var shouldStopAndCommit: Bool {
        intent == .stopAndCommit
    }

    var shouldCancelAndDiscard: Bool {
        intent == .cancelAndDiscard
    }

    func registerPlaybackSnapshotRequest(
        _ request: HLSLiveDVRPlaybackSnapshotRequest
    ) async throws {
        guard await request.shouldProcess else {
            throw CancellationError()
        }
        guard !didFinish else {
            throw HLSLiveDVRError.playbackSnapshotUnavailable
        }
        guard
            outstandingPlaybackSnapshotRequestIDs.count
                < Self.maximumOutstandingPlaybackSnapshotCount
        else {
            throw HLSLiveDVRError.playbackSnapshotRequestLimitExceeded(
                limit: Self.maximumOutstandingPlaybackSnapshotCount
            )
        }
        playbackSnapshotRequests.append(request)
        outstandingPlaybackSnapshotRequestIDs.insert(
            ObjectIdentifier(request)
        )
    }

    func cancelPlaybackSnapshotRequest(
        _ request: HLSLiveDVRPlaybackSnapshotRequest
    ) {
        let wasPending = playbackSnapshotRequests.contains { candidate in
            candidate === request
        }
        playbackSnapshotRequests.removeAll { candidate in
            candidate === request
        }
        if wasPending {
            outstandingPlaybackSnapshotRequestIDs.remove(
                ObjectIdentifier(request)
            )
        }
    }

    func completePlaybackSnapshotRequest(
        _ request: HLSLiveDVRPlaybackSnapshotRequest
    ) {
        outstandingPlaybackSnapshotRequestIDs.remove(
            ObjectIdentifier(request)
        )
    }

    func takePlaybackSnapshotRequests()
        -> [HLSLiveDVRPlaybackSnapshotRequest]
    {
        defer {
            playbackSnapshotRequests.removeAll(keepingCapacity: true)
        }
        return playbackSnapshotRequests
    }

    func finishPlaybackSnapshotRequests() async {
        guard !didFinish else {
            return
        }
        didFinish = true
        let requests = takePlaybackSnapshotRequests()
        for request in requests {
            await request.fail(.playbackSnapshotUnavailable)
            completePlaybackSnapshotRequest(request)
        }
    }
}

actor HLSLiveDVRPlaybackSnapshotRequest {
    private enum Resolution {
        case receipt(HLSLiveDVRReceipt)
        case failure(HLSLiveDVRError)
        case cancelled
    }

    let destinationDirectoryURL: URL
    private var resolution: Resolution?
    private var continuation: CheckedContinuation<HLSLiveDVRReceipt, any Error>?
    private var operationTask: Task<HLSLiveDVRReceipt, Error>?

    init(destinationDirectoryURL: URL) {
        self.destinationDirectoryURL = destinationDirectoryURL
    }

    var shouldProcess: Bool {
        resolution == nil
    }

    func installOperationTask(
        _ task: Task<HLSLiveDVRReceipt, Error>
    ) -> Bool {
        guard resolution == nil else {
            task.cancel()
            return false
        }
        operationTask = task
        return true
    }

    func value() async throws -> HLSLiveDVRReceipt {
        if let resolution {
            return try Self.value(from: resolution)
        }
        return try await withCheckedThrowingContinuation {
            continuation = $0
        }
    }

    func succeed(_ receipt: HLSLiveDVRReceipt) {
        resolve(.receipt(receipt))
    }

    func fail(_ error: HLSLiveDVRError) {
        resolve(.failure(error))
    }

    func cancel() async {
        guard resolution == nil else {
            return
        }
        guard let operationTask else {
            resolve(.cancelled)
            return
        }
        operationTask.cancel()
        do {
            resolve(.receipt(try await operationTask.value))
        } catch is CancellationError {
            resolve(.cancelled)
        } catch let error as HLSLiveDVRError {
            resolve(.failure(error))
        } catch {
            resolve(.failure(.storageFailed))
        }
    }

    private func resolve(_ resolution: Resolution) {
        guard self.resolution == nil else {
            return
        }
        self.resolution = resolution
        operationTask = nil
        guard let continuation else {
            return
        }
        self.continuation = nil
        Self.resume(continuation, with: resolution)
    }

    private static func value(
        from resolution: Resolution
    ) throws -> HLSLiveDVRReceipt {
        switch resolution {
        case .receipt(let receipt):
            return receipt
        case .failure(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }

    private static func resume(
        _ continuation:
            CheckedContinuation<HLSLiveDVRReceipt, any Error>,
        with resolution: Resolution
    ) {
        switch resolution {
        case .receipt(let receipt):
            continuation.resume(returning: receipt)
        case .failure(let error):
            continuation.resume(throwing: error)
        case .cancelled:
            continuation.resume(throwing: CancellationError())
        }
    }
}

/// Owns one bounded live DVR recording and its terminal operation.
///
/// Retain this handle for the recording lifetime. The first call to
/// ``stopAndCommit()`` or ``cancelAndDiscard()`` wins; repeated calls observe
/// the same terminal result. Releasing the handle cancels unfinished work.
/// Legacy recordings remove staging; a resumable recording preserves its last
/// complete-segment checkpoint when one exists.
public final class HLSLiveDVRRecording: Sendable {
    /// Bounded progress and completion events for this recording.
    ///
    /// Stopping iteration does not stop the recording. Use
    /// ``stopAndCommit()`` or ``cancelAndDiscard()`` for explicit lifecycle
    /// control.
    public let events: AsyncThrowingStream<HLSLiveDVREvent, Error>

    private let control: HLSLiveDVRRecordingControl
    private let task: Task<HLSLiveDVRReceipt, Error>

    init(
        events: AsyncThrowingStream<HLSLiveDVREvent, Error>,
        control: HLSLiveDVRRecordingControl,
        task: Task<HLSLiveDVRReceipt, Error>
    ) {
        self.events = events
        self.control = control
        self.task = task
    }

    deinit {
        task.cancel()
    }

    /// Stops after the current complete primary segment and atomically commits
    /// all retained tracks.
    ///
    /// If no complete primary segment has been retained, this throws
    /// ``HLSLiveDVRError/noSegmentsRecorded``. If discard won the terminal
    /// race, this throws `CancellationError`.
    public func stopAndCommit() async throws -> HLSLiveDVRReceipt {
        _ = await control.request(.stopAndCommit)
        return try await task.value
    }

    /// Cancels transfer work and removes the uncommitted staging directory.
    ///
    /// The method waits for cleanup. If commit already won the terminal race,
    /// it waits for that commit instead of deleting the completed package.
    public func cancelAndDiscard() async {
        let intent = await control.request(.cancelAndDiscard)
        if intent == .cancelAndDiscard {
            task.cancel()
        }
        _ = try? await task.value
    }

    /// Captures the next coherent complete-segment boundary as an independent
    /// local VOD package while the recording continues.
    ///
    /// The destination must not exist. The returned receipt can be opened with
    /// `HLSLocalPlaybackAsset` from `InnoNetworkHLSAVFoundation`; it remains
    /// valid after rolling retention evicts the source files or the recording
    /// commits elsewhere. Requests wait for the next boundary rather than
    /// exposing mutable staging files. Cancelling the caller cancels only this
    /// snapshot request; an atomic publication that already won returns its
    /// receipt.
    public func capturePlaybackSnapshot(
        to destinationDirectoryURL: URL
    ) async throws -> HLSLiveDVRReceipt {
        guard destinationDirectoryURL.isFileURL else {
            throw HLSLiveDVRError.invalidDestination
        }
        let request = HLSLiveDVRPlaybackSnapshotRequest(
            destinationDirectoryURL: destinationDirectoryURL
        )
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await control.registerPlaybackSnapshotRequest(request)
            try Task.checkCancellation()
            return try await request.value()
        } onCancel: {
            Task {
                await request.cancel()
                await control.cancelPlaybackSnapshotRequest(request)
            }
        }
    }

    func interrupt() async {
        task.cancel()
        _ = try? await task.value
    }
}
