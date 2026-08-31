import Foundation

enum HLSLiveDVRRecordingIntent: Sendable {
    case stopAndCommit
    case cancelAndDiscard
}

actor HLSLiveDVRRecordingControl {
    private var intent: HLSLiveDVRRecordingIntent?
    private var snapshotRelayTask: Task<Void, Never>?

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
}

/// Owns one bounded live DVR recording and its terminal operation.
///
/// Retain this handle for the recording lifetime. The first call to
/// ``stopAndCommit()`` or ``cancelAndDiscard()`` wins; repeated calls observe
/// the same terminal result. Releasing the handle cancels unfinished work and
/// removes its staging directory.
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
}
