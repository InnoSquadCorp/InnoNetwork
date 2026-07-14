import Foundation
import OSLog

struct DownloadTaskLifecycleSnapshot: Sendable, Equatable {
    let state: DownloadState
    let generation: Int
    let attempt: Int
}

public actor DownloadTask: Identifiable {
    public nonisolated let id: String
    public nonisolated let url: URL
    public nonisolated let destinationURL: URL

    private static let logger = Logger(subsystem: "innosquad.network.download", category: "DownloadTask")

    private var _state: DownloadState = .idle
    private var _progress: DownloadProgress = .zero
    private var _retryCount: Int = 0
    private var _totalRetryCount: Int = 0
    private var _resumeData: Data?
    private var _error: DownloadError?
    /// Outer epoch counter. Bumped each time the download is fully
    /// re-driven (for example, after a hard reset that drops resume
    /// data). Inner `attempt` counters are scoped to one generation.
    /// Maintained by `DownloadManager` to disambiguate in-flight
    /// callbacks across retry cycles, mirroring the `WebSocketTask`
    /// pattern.
    private var _generation: Int = 0
    /// Per-generation attempt counter. Reset to `0` whenever
    /// `_generation` advances; otherwise increments by one for each
    /// retry of the same generation.
    private var _attempt: Int = 0
    /// Timestamp of the most recent download activity observed by
    /// `DownloadManager`. Progress callbacks update it directly; the
    /// inactivity watchdog may seed it when a task is downloading but has
    /// not produced its first progress event yet. Consumed by
    /// ``DownloadConfiguration/taskInactivityTimeout``.
    private var _lastProgressAt: ContinuousClock.Instant?

    public var state: DownloadState { _state }
    public var progress: DownloadProgress { _progress }
    public var retryCount: Int { _retryCount }
    public var totalRetryCount: Int { _totalRetryCount }
    public var resumeData: Data? { _resumeData }
    public var error: DownloadError? { _error }
    /// Current generation epoch maintained by `DownloadManager`.
    public var generation: Int { _generation }
    /// Current attempt index within the active generation.
    public var attempt: Int { _attempt }
    /// Timestamp of the most recent progress or watchdog-observed download
    /// activity, or `nil` before a running attempt is observed.
    public var lastProgressAt: ContinuousClock.Instant? { _lastProgressAt }

    /// Construct a download task description.
    ///
    /// - Parameters:
    ///   - url: Source URL the task will download from.
    ///   - destinationURL: File URL the downloaded payload will be moved to on
    ///     completion.
    ///   - id: Stable identifier used to correlate the task across restarts and
    ///     to key persistence rows. Defaults to a fresh UUID; callers that
    ///     restore state from disk should pass the persisted identifier.
    ///   - resumeData: Optional `URLSession` resume payload. Pass non-nil only
    ///     when reconstructing a task whose previous attempt was paused or
    ///     interrupted; the manager will use it to resume from the last
    ///     persisted byte offset.
    public init(url: URL, destinationURL: URL, id: String = UUID().uuidString, resumeData: Data? = nil) {
        self.id = id
        self.url = url
        self.destinationURL = destinationURL
        self._resumeData = resumeData
    }

    /// Apply a new state, enforcing the documented transition table from
    /// ``DownloadState/canTransition(to:)``.
    ///
    /// Illegal transitions trigger an `assertionFailure` in DEBUG builds so
    /// that bugs surface during development. In release builds the attempt is
    /// logged as an OSLog `.fault` and the assignment is **rejected** — the
    /// existing state is preserved so a misbehaving caller cannot drive the
    /// task into an inconsistent state. For non-progressive writes (restoring
    /// persisted state on app launch, or test-only state injection), use
    /// ``restoreState(_:)``.
    func updateState(_ newState: DownloadState) {
        let current = _state
        let reduction = DownloadLifecycleReducer.reduce(
            state: current,
            event: .transition(to: newState)
        )
        if reduction.effects.contains(.rejectIllegalTransition(from: current, to: newState)) {
            Self.logger.fault(
                "Illegal DownloadState transition: \(current.rawValue, privacy: .public) -> \(newState.rawValue, privacy: .public) for task \(self.id, privacy: .private(mask: .hash))"
            )
            assertionFailure("Illegal DownloadState transition: \(current) -> \(newState) for task \(self.id)")
            return
        }
        _state = reduction.state
    }

    /// Assign the task state without validating the transition.
    ///
    /// Reserved for state restoration (rebuilding actor state from persisted
    /// records or live `URLSession` task state on app relaunch) and for test
    /// state injection. Production lifecycle code should use
    /// ``updateState(_:)`` so unintended transitions are caught.
    func restoreState(_ newState: DownloadState) {
        _state = newState
    }

    func updateProgress(_ newProgress: DownloadProgress) {
        _progress = newProgress
    }

    func setLastProgressAt(_ instant: ContinuousClock.Instant?) {
        _lastProgressAt = instant
    }

    func incrementRetryCount() -> Int {
        _retryCount += 1
        return _retryCount
    }

    func setRetryCount(_ retryCount: Int) {
        _retryCount = max(0, retryCount)
    }

    func incrementTotalRetryCount() -> Int {
        _totalRetryCount += 1
        return _totalRetryCount
    }

    func resetRetryCount() {
        _retryCount = 0
    }

    func setResumeData(_ data: Data?) {
        _resumeData = data
    }

    func setError(_ error: DownloadError?) {
        _error = error
    }

    func lifecycleSnapshot() -> DownloadTaskLifecycleSnapshot {
        DownloadTaskLifecycleSnapshot(
            state: _state,
            generation: _generation,
            attempt: _attempt
        )
    }

    /// Applies the pause result only when the same running attempt is still
    /// active. `cancelByProducingResumeData()` is asynchronous, so a terminal
    /// delegate callback or retry may advance the task while `pause(_:)` is
    /// suspended. Keeping the comparison, resume-data assignment, and state
    /// transition in one actor turn prevents a stale pause result from
    /// reviving that superseded attempt.
    func transitionToPaused(
        resumeData: Data?,
        ifMatching expected: DownloadTaskLifecycleSnapshot
    ) -> Bool {
        guard lifecycleSnapshot() == expected, _state == .downloading else {
            return false
        }
        _resumeData = resumeData
        updateState(.paused)
        return true
    }

    func reset() {
        _state = .idle
        _progress = .zero
        _retryCount = 0
        _totalRetryCount = 0
        _error = nil
        _generation = 0
        _attempt = 0
        _lastProgressAt = nil
    }

    func startNextAttemptInCurrentGeneration() {
        startAttempt(generation: _generation, attempt: _attempt + 1)
    }

    /// Record the start of a new download attempt by reducing through
    /// ``DownloadLifecycleReducer`` and applying any emitted
    /// ``DownloadLifecycleEffect/advancedEpoch`` effect.
    ///
    /// The reducer keeps the visible ``state`` unchanged on this path —
    /// epoch advancement is orthogonal to the transition table — so this
    /// method only updates `_generation` / `_attempt`. This is internal
    /// lifecycle bookkeeping; public callers should observe
    /// ``generation`` and ``attempt`` instead of trying to drive them.
    func startAttempt(generation: Int, attempt: Int) {
        let reduction = DownloadLifecycleReducer.reduce(
            state: _state,
            event: .startAttempt(generation: generation, attempt: attempt)
        )
        for effect in reduction.effects {
            switch effect {
            case .advancedEpoch(let nextGeneration, let nextAttempt):
                _generation = nextGeneration
                _attempt = nextAttempt
                // A fresh attempt has no real progress timestamp yet. Keeping
                // the prior epoch's value would let the inactivity watchdog
                // cancel a freshly resumed/retried `URLSessionDownloadTask`
                // before its first progress callback arrives — comparing
                // `now` against a pause-era timestamp.
                _lastProgressAt = nil
            case .rejectIllegalTransition:
                continue
            }
        }
    }
}


extension DownloadTask: Hashable {
    public nonisolated static func == (lhs: DownloadTask, rhs: DownloadTask) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
