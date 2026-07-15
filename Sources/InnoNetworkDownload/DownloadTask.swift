import Foundation
import OSLog

struct DownloadTaskLifecycleSnapshot: Sendable, Equatable {
    let state: DownloadState
    let generation: Int
    let attempt: Int
}


enum DownloadTerminalTransitionResult: Sendable, Equatable {
    case transitioned
    case alreadyTerminal
    case busy
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
    /// Serializes competing completion, failure, and cancellation paths. A
    /// completion may need to stage/move a file before it can expose the final
    /// public state; while it owns this claim, other terminal paths must not
    /// remove runtime or persistence state underneath it.
    private var _terminalTransitionClaimed = false
    private var _terminalTransitionClaimWaiters: [CheckedContinuation<Void, Never>] = []
    /// Covers the only persistence write that can create/re-activate an
    /// `active` row. Cancellation may still win the public state transition
    /// while this claim is held, but it waits for the write to settle before
    /// sealing/removing persistence so a late upsert cannot resurrect it.
    private var _startPersistenceClaimed = false
    private var _startPersistenceClaimWaiters: [CheckedContinuation<Void, Never>] = []
    /// Serializes terminal persistence cleanup with a new manual generation.
    /// The claim is acquired in the same actor turn as cancellation so a
    /// retry cannot reopen the handle between the terminal-state check and
    /// the old generation's marker/remove operations.
    private var _terminalPersistenceCleanupClaimed = false
    private var _terminalPersistenceCleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var _manualRetryInvalidatedByCancellation = false
    /// A cancellation requested while completion owns the terminal claim.
    /// Other terminal paths remain blocked after a failed commit until the
    /// cancelling manager resumes and records `.cancelled`.
    private var _pendingCancellation = false
    /// A failed state is publicly retryable only after its old-generation
    /// runtime, persistence, and terminal event partition are finalized.
    private var _failureFinalizationInProgress = false
    private var _failureFinalizationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Manager ownership is claimed exactly once when the task first enters a
    /// runtime registry. Keeping the token on the handle lets a manager accept
    /// retry after terminal registry cleanup without accepting a foreign or
    /// same-ID fabricated handle.
    private var _ownerID: UUID?
    /// A no-system-task `.pausing` / `.resuming` record is reconstructed as
    /// paused while the manager drains the restoration delegate snapshot.
    /// During that bounded window, a staged successful completion is still
    /// authoritative and may reopen the handle for final commit. Ordinary
    /// paused tasks never set this bit, so a late predecessor callback cannot
    /// steal a later public resume generation.
    private var _admitsRestoredSuccessWhilePaused = false
    /// An active/legacy persistence row with no surviving URLSession task is
    /// reconstructed as a synthetic restoration failure before the manager
    /// drains the delegate snapshot captured at launch. A correlated staged
    /// success inside that snapshot may still prove the transfer completed.
    /// Keep this admission separate from the intermediate-pause bit so neither
    /// recovery case can accidentally authorize the other, and consume it at
    /// most once before the restoration FIFO boundary closes.
    private var _admitsMissingSystemRestoredSuccess = false

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
    package init(url: URL, destinationURL: URL, id: String = UUID().uuidString, resumeData: Data? = nil) {
        self.id = id
        self.url = url
        self.destinationURL = destinationURL
        self._resumeData = resumeData
    }

    func claimOwnership(_ ownerID: UUID) -> Bool {
        if let currentOwnerID = _ownerID {
            return currentOwnerID == ownerID
        }
        _ownerID = ownerID
        return true
    }

    func isOwned(by ownerID: UUID) -> Bool {
        _ownerID == ownerID
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
        if reduction.state.isTerminal {
            _terminalTransitionClaimed = true
        }
    }

    /// Assign the task state without validating the transition.
    ///
    /// Reserved for state restoration (rebuilding actor state from persisted
    /// records or live `URLSession` task state on app relaunch) and for test
    /// state injection. Production lifecycle code should use
    /// ``updateState(_:)`` so unintended transitions are caught.
    func restoreState(_ newState: DownloadState) {
        _state = newState
        _terminalTransitionClaimed = newState.isTerminal
    }

    func admitRestoredSuccessWhilePaused() {
        guard _state == .paused else { return }
        _admitsRestoredSuccessWhilePaused = true
    }

    func admitMissingSystemRestoredSuccess() {
        guard _state == .failed,
            case .restorationMissingSystemTask? = _error,
            _terminalTransitionClaimed
        else { return }
        _admitsMissingSystemRestoredSuccess = true
    }

    func endRestoredSuccessAdmission() {
        _admitsRestoredSuccessWhilePaused = false
        _admitsMissingSystemRestoredSuccess = false
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

    func restoreRetryCounts(retryCount: Int, totalRetryCount: Int) {
        _retryCount = max(0, retryCount)
        _totalRetryCount = max(0, totalRetryCount)
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

    func applyProgressIfActive(
        _ progress: DownloadProgress,
        observedAt: ContinuousClock.Instant?
    ) -> DownloadTaskLifecycleSnapshot? {
        guard !_pendingCancellation, !_terminalTransitionClaimed, _state == .downloading else { return nil }
        _progress = progress
        if let observedAt {
            _lastProgressAt = observedAt
        }
        return lifecycleSnapshot()
    }

    func transition(
        to newState: DownloadState,
        ifMatching expected: DownloadTaskLifecycleSnapshot
    ) -> DownloadTaskLifecycleSnapshot? {
        guard !_pendingCancellation,
            !_terminalTransitionClaimed,
            lifecycleSnapshot() == expected,
            _state.canTransition(to: newState)
        else {
            return nil
        }
        updateState(newState)
        return lifecycleSnapshot()
    }

    func startNextAttempt(
        transitioningTo newState: DownloadState,
        ifMatching expected: DownloadTaskLifecycleSnapshot
    ) -> DownloadTaskLifecycleSnapshot? {
        guard !_pendingCancellation,
            !_terminalTransitionClaimed,
            lifecycleSnapshot() == expected,
            _state.canTransition(to: newState)
        else {
            return nil
        }
        startAttempt(generation: _generation, attempt: _attempt + 1)
        updateState(newState)
        return lifecycleSnapshot()
    }

    func resume(
        _ urlTask: any DownloadURLTask,
        ifMatching expected: DownloadTaskLifecycleSnapshot,
        lifecycleGate: DownloadLifecycleGate
    ) -> Bool {
        guard !_pendingCancellation, !_terminalTransitionClaimed, lifecycleSnapshot() == expected else {
            return false
        }
        return lifecycleGate.resumeIfOpen(urlTask)
    }

    func claimStartPersistence(
        ifMatching expected: DownloadTaskLifecycleSnapshot
    ) -> Bool {
        guard !_startPersistenceClaimed,
            !_pendingCancellation,
            !_state.isTerminal,
            lifecycleSnapshot() == expected
        else { return false }
        _startPersistenceClaimed = true
        return true
    }

    func releaseStartPersistenceClaim() {
        guard _startPersistenceClaimed else { return }
        _startPersistenceClaimed = false
        let waiters = _startPersistenceClaimWaiters
        _startPersistenceClaimWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForStartPersistenceClaimRelease() async {
        guard _startPersistenceClaimed else { return }
        await withCheckedContinuation { continuation in
            _startPersistenceClaimWaiters.append(continuation)
        }
    }

    func claimTerminalTransition() -> Bool {
        guard !_pendingCancellation, !_terminalTransitionClaimed, !_state.isTerminal else { return false }
        _terminalTransitionClaimed = true
        return true
    }

    func releaseTerminalTransitionClaim() {
        guard !_state.isTerminal else { return }
        _terminalTransitionClaimed = false
        resumeTerminalTransitionClaimWaiters()
    }

    func finishClaimedTerminalTransition(
        to newState: DownloadState,
        error: DownloadError?
    ) -> Bool {
        guard _terminalTransitionClaimed,
            !_state.isTerminal,
            newState.isTerminal,
            _state.canTransition(to: newState)
        else {
            return false
        }
        _error = error
        _pendingCancellation = false
        updateState(newState)
        resumeTerminalTransitionClaimWaiters()
        return true
    }

    func transitionToTerminal(
        _ newState: DownloadState,
        error: DownloadError?
    ) -> DownloadTerminalTransitionResult {
        guard !_state.isTerminal else { return .alreadyTerminal }
        if _terminalTransitionClaimed {
            if newState == .cancelled {
                _pendingCancellation = true
            }
            return .busy
        }
        guard !_pendingCancellation || newState == .cancelled else { return .busy }
        guard newState.isTerminal, _state.canTransition(to: newState) else {
            return .busy
        }
        if newState == .cancelled {
            _pendingCancellation = false
        }
        _terminalTransitionClaimed = true
        _error = error
        updateState(newState)
        return .transitioned
    }

    func transitionToFailureFinalizing(
        error: DownloadError
    ) -> DownloadTerminalTransitionResult {
        guard !_failureFinalizationInProgress else { return .busy }
        let result = transitionToTerminal(.failed, error: error)
        if result == .transitioned {
            _failureFinalizationInProgress = true
        }
        return result
    }

    func transitionToFailureFinalizing(
        error: DownloadError,
        ifMatching expected: DownloadTaskLifecycleSnapshot
    ) -> DownloadTerminalTransitionResult {
        guard lifecycleSnapshot() == expected else { return .busy }
        return transitionToFailureFinalizing(error: error)
    }

    func waitForFailureFinalization() async {
        guard _failureFinalizationInProgress else { return }
        await withCheckedContinuation { continuation in
            _failureFinalizationWaiters.append(continuation)
        }
    }

    func finishFailureFinalization() {
        guard _failureFinalizationInProgress else { return }
        _failureFinalizationInProgress = false
        let waiters = _failureFinalizationWaiters
        _failureFinalizationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func requestCancellationClaimingPersistenceCleanup() async -> DownloadTerminalTransitionResult {
        while true {
            let result = transitionToTerminal(.cancelled, error: .cancelled)
            if result == .transitioned || result == .alreadyTerminal {
                guard !_terminalPersistenceCleanupClaimed else { return .busy }
                _terminalPersistenceCleanupClaimed = true
                if result == .alreadyTerminal, _state == .failed {
                    _manualRetryInvalidatedByCancellation = true
                }
                return result
            }
            guard result == .busy, _pendingCancellation else { return result }
            await waitForTerminalTransitionClaimResolution()
        }
    }

    func requestCancellationClaimingPersistenceCleanup(
        ifMatching expected: DownloadTaskLifecycleSnapshot
    ) async -> DownloadTerminalTransitionResult {
        while true {
            guard lifecycleSnapshot() == expected else { return .busy }
            let result = transitionToTerminal(.cancelled, error: .cancelled)
            if result == .transitioned || result == .alreadyTerminal {
                guard !_terminalPersistenceCleanupClaimed else { return .busy }
                _terminalPersistenceCleanupClaimed = true
                if result == .alreadyTerminal, _state == .failed {
                    _manualRetryInvalidatedByCancellation = true
                }
                return result
            }
            guard result == .busy, _pendingCancellation else { return result }
            await waitForTerminalTransitionClaimResolution()
        }
    }

    func releaseTerminalPersistenceCleanupClaim() {
        guard _terminalPersistenceCleanupClaimed else { return }
        _terminalPersistenceCleanupClaimed = false
        let waiters = _terminalPersistenceCleanupWaiters
        _terminalPersistenceCleanupWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// State-machine-only cancellation used by reducer tests. Manager
    /// lifecycle code uses the persistence-cleanup claiming variant above.
    func requestCancellation() async -> DownloadTerminalTransitionResult {
        while true {
            let result = transitionToTerminal(.cancelled, error: .cancelled)
            guard result == .busy, _pendingCancellation else { return result }
            await waitForTerminalTransitionClaimResolution()
        }
    }

    func waitForTerminalTransitionClaimResolution() async {
        guard _terminalTransitionClaimed, !_state.isTerminal else { return }
        await withCheckedContinuation { continuation in
            _terminalTransitionClaimWaiters.append(continuation)
        }
    }

    private func resumeTerminalTransitionClaimWaiters() {
        let waiters = _terminalTransitionClaimWaiters
        _terminalTransitionClaimWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Reconstructs the retained terminal outcome for subscribers that attach
    /// after the live event partition has already been retired. Returning the
    /// value from the task actor avoids a manager-wide tombstone table whose
    /// memory would otherwise grow with every completed download.
    func terminalEvent() -> DownloadEvent? {
        switch _state {
        case .completed:
            return .completed(destinationURL)
        case .failed:
            guard let error = _error else { return nil }
            return .failed(error)
        case .cancelled:
            return .stateChanged(.cancelled)
        case .idle, .waiting, .downloading, .paused:
            return nil
        }
    }

    /// Reopens the synthetic missing-system-task state when a staged
    /// background completion proves that the transfer did in fact finish.
    /// This is used only during restoration before the deferred failure is
    /// exposed to consumers.
    func prepareForRestoredCompletion(
        hasSuccessfulPayload: Bool
    ) -> DownloadTaskLifecycleSnapshot? {
        guard hasSuccessfulPayload else { return nil }

        if _state == .failed,
            case .restorationMissingSystemTask? = _error,
            _admitsMissingSystemRestoredSuccess,
            _terminalTransitionClaimed
        {
            _admitsMissingSystemRestoredSuccess = false
            _state = .downloading
            _error = nil
            _terminalTransitionClaimed = false
            _pendingCancellation = false
            return lifecycleSnapshot()
        }

        guard _state == .paused,
            _admitsRestoredSuccessWhilePaused,
            !_terminalTransitionClaimed,
            !_pendingCancellation
        else { return nil }

        _admitsRestoredSuccessWhilePaused = false
        _state = .downloading
        _error = nil
        _terminalTransitionClaimed = false
        _pendingCancellation = false
        return lifecycleSnapshot()
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
        guard !_pendingCancellation,
            !_terminalTransitionClaimed,
            lifecycleSnapshot() == expected,
            _state == .downloading
        else {
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
        _resumeData = nil
        _error = nil
        _generation = 0
        _attempt = 0
        _lastProgressAt = nil
        _terminalTransitionClaimed = false
        _pendingCancellation = false
        _failureFinalizationInProgress = false
        _admitsRestoredSuccessWhilePaused = false
        _admitsMissingSystemRestoredSuccess = false
        _manualRetryInvalidatedByCancellation = false
        releaseStartPersistenceClaim()
        resumeTerminalTransitionClaimWaiters()
        let failureWaiters = _failureFinalizationWaiters
        _failureFinalizationWaiters.removeAll(keepingCapacity: false)
        for waiter in failureWaiters {
            waiter.resume()
        }
    }

    func beginManualRetry() async -> DownloadTaskLifecycleSnapshot? {
        while _terminalPersistenceCleanupClaimed {
            await withCheckedContinuation { continuation in
                _terminalPersistenceCleanupWaiters.append(continuation)
            }
        }
        guard !_pendingCancellation,
            !_manualRetryInvalidatedByCancellation,
            _state == .failed
        else { return nil }
        let nextGeneration = _generation + 1
        reset()
        startAttempt(generation: nextGeneration, attempt: 0)
        return lifecycleSnapshot()
    }

    func advanceAttempt(
        ifMatching expected: DownloadTaskLifecycleSnapshot
    ) -> DownloadTaskLifecycleSnapshot? {
        guard !_pendingCancellation,
            !_terminalTransitionClaimed,
            !_state.isTerminal,
            lifecycleSnapshot() == expected
        else {
            return nil
        }
        startNextAttemptInCurrentGeneration()
        return lifecycleSnapshot()
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
