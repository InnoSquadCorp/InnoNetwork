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

/// Actor-owned lifecycle data for one logical download.
///
/// Keeping the values together makes lifecycle snapshots and reset behavior
/// reviewable as one state model while `DownloadTask` remains the only
/// synchronization boundary.
private struct DownloadTaskLifecycleState {
    var state: DownloadState = .idle
    var progress: DownloadProgress = .zero
    var retryCount = 0
    var totalRetryCount = 0
    var resumeData: Data?
    var error: DownloadError?
    /// Outer epoch counter. Bumped each time the download is fully re-driven.
    var generation = 0
    /// Per-generation attempt counter.
    var attempt = 0
    /// Timestamp of the most recent manager-observed download activity.
    var lastProgressAt: ContinuousClock.Instant?
    /// Claimed exactly once by the manager that owns this task handle.
    var ownerID: UUID?
    /// Bounded restoration admissions for staged completions.
    var admitsRestoredSuccessWhilePaused = false
    var admitsMissingSystemRestoredSuccess = false
}

/// Actor-owned serialization claims for competing lifecycle effects.
///
/// Claims and their waiters stay adjacent so every acquire/release pair can be
/// audited without weakening the actor's atomic transition boundary.
private struct DownloadTaskTransitionClaims {
    var terminalTransitionClaimed = false
    var terminalTransitionWaiters: [CheckedContinuation<Void, Never>] = []
    var startPersistenceClaimed = false
    var startPersistenceWaiters: [CheckedContinuation<Void, Never>] = []
    var terminalPersistenceCleanupClaimed = false
    var terminalPersistenceCleanupWaiters: [CheckedContinuation<Void, Never>] = []
    var manualRetryInvalidatedByCancellation = false
    var pendingCancellation = false
    var failureFinalizationInProgress = false
    var failureFinalizationWaiters: [CheckedContinuation<Void, Never>] = []
}

public actor DownloadTask: Identifiable {
    public nonisolated let id: String
    public nonisolated let url: URL
    public nonisolated let destinationURL: URL

    private static let logger = Logger(subsystem: "innosquad.network.download", category: "DownloadTask")

    private var lifecycle = DownloadTaskLifecycleState()
    private var transitionClaims = DownloadTaskTransitionClaims()

    public var state: DownloadState { lifecycle.state }
    public var progress: DownloadProgress { lifecycle.progress }
    public var retryCount: Int { lifecycle.retryCount }
    public var totalRetryCount: Int { lifecycle.totalRetryCount }
    public var resumeData: Data? { lifecycle.resumeData }
    public var error: DownloadError? { lifecycle.error }
    /// Current generation epoch maintained by `DownloadManager`.
    public var generation: Int { lifecycle.generation }
    /// Current attempt index within the active generation.
    public var attempt: Int { lifecycle.attempt }
    /// Timestamp of the most recent progress or watchdog-observed download
    /// activity, or `nil` before a running attempt is observed.
    public var lastProgressAt: ContinuousClock.Instant? { lifecycle.lastProgressAt }

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
        self.lifecycle = DownloadTaskLifecycleState(resumeData: resumeData)
    }

    func claimOwnership(_ ownerID: UUID) -> Bool {
        if let currentOwnerID = lifecycle.ownerID {
            return currentOwnerID == ownerID
        }
        lifecycle.ownerID = ownerID
        return true
    }

    func isOwned(by ownerID: UUID) -> Bool {
        lifecycle.ownerID == ownerID
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
        let current = lifecycle.state
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
        lifecycle.state = reduction.state
        if reduction.state.isTerminal {
            transitionClaims.terminalTransitionClaimed = true
        }
    }

    /// Assign the task state without validating the transition.
    ///
    /// Reserved for state restoration (rebuilding actor state from persisted
    /// records or live `URLSession` task state on app relaunch) and for test
    /// state injection. Production lifecycle code should use
    /// ``updateState(_:)`` so unintended transitions are caught.
    func restoreState(_ newState: DownloadState) {
        lifecycle.state = newState
        transitionClaims.terminalTransitionClaimed = newState.isTerminal
    }

    func admitRestoredSuccessWhilePaused() {
        guard lifecycle.state == .paused else { return }
        lifecycle.admitsRestoredSuccessWhilePaused = true
    }

    func admitMissingSystemRestoredSuccess() {
        guard lifecycle.state == .failed,
            case .restorationMissingSystemTask? = lifecycle.error,
            transitionClaims.terminalTransitionClaimed
        else { return }
        lifecycle.admitsMissingSystemRestoredSuccess = true
    }

    func endRestoredSuccessAdmission() {
        lifecycle.admitsRestoredSuccessWhilePaused = false
        lifecycle.admitsMissingSystemRestoredSuccess = false
    }

    func updateProgress(_ newProgress: DownloadProgress) {
        lifecycle.progress = newProgress
    }

    func setLastProgressAt(_ instant: ContinuousClock.Instant?) {
        lifecycle.lastProgressAt = instant
    }

    func incrementRetryCount() -> Int {
        lifecycle.retryCount += 1
        return lifecycle.retryCount
    }

    func setRetryCount(_ retryCount: Int) {
        lifecycle.retryCount = max(0, retryCount)
    }

    func restoreRetryCounts(retryCount: Int, totalRetryCount: Int) {
        lifecycle.retryCount = max(0, retryCount)
        lifecycle.totalRetryCount = max(0, totalRetryCount)
    }

    func incrementTotalRetryCount() -> Int {
        lifecycle.totalRetryCount += 1
        return lifecycle.totalRetryCount
    }

    func resetRetryCount() {
        lifecycle.retryCount = 0
    }

    func setResumeData(_ data: Data?) {
        lifecycle.resumeData = data
    }

    func setError(_ error: DownloadError?) {
        lifecycle.error = error
    }

    func lifecycleSnapshot() -> DownloadTaskLifecycleSnapshot {
        DownloadTaskLifecycleSnapshot(
            state: lifecycle.state,
            generation: lifecycle.generation,
            attempt: lifecycle.attempt
        )
    }

    func applyProgressIfActive(
        _ progress: DownloadProgress,
        observedAt: ContinuousClock.Instant?
    ) -> DownloadTaskLifecycleSnapshot? {
        guard !transitionClaims.pendingCancellation, !transitionClaims.terminalTransitionClaimed,
            lifecycle.state == .downloading
        else { return nil }
        lifecycle.progress = progress
        if let observedAt {
            lifecycle.lastProgressAt = observedAt
        }
        return lifecycleSnapshot()
    }

    func transition(
        to newState: DownloadState,
        ifMatching expected: DownloadTaskLifecycleSnapshot
    ) -> DownloadTaskLifecycleSnapshot? {
        guard !transitionClaims.pendingCancellation,
            !transitionClaims.terminalTransitionClaimed,
            lifecycleSnapshot() == expected,
            lifecycle.state.canTransition(to: newState)
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
        guard !transitionClaims.pendingCancellation,
            !transitionClaims.terminalTransitionClaimed,
            lifecycleSnapshot() == expected,
            lifecycle.state.canTransition(to: newState)
        else {
            return nil
        }
        startAttempt(generation: lifecycle.generation, attempt: lifecycle.attempt + 1)
        updateState(newState)
        return lifecycleSnapshot()
    }

    func resume(
        _ urlTask: any DownloadURLTask,
        ifMatching expected: DownloadTaskLifecycleSnapshot,
        lifecycleGate: DownloadLifecycleGate
    ) -> Bool {
        guard !transitionClaims.pendingCancellation, !transitionClaims.terminalTransitionClaimed,
            lifecycleSnapshot() == expected
        else {
            return false
        }
        return lifecycleGate.resumeIfOpen(urlTask)
    }

    func claimStartPersistence(
        ifMatching expected: DownloadTaskLifecycleSnapshot
    ) -> Bool {
        guard !transitionClaims.startPersistenceClaimed,
            !transitionClaims.pendingCancellation,
            !lifecycle.state.isTerminal,
            lifecycleSnapshot() == expected
        else { return false }
        transitionClaims.startPersistenceClaimed = true
        return true
    }

    func releaseStartPersistenceClaim() {
        guard transitionClaims.startPersistenceClaimed else { return }
        transitionClaims.startPersistenceClaimed = false
        let waiters = transitionClaims.startPersistenceWaiters
        transitionClaims.startPersistenceWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForStartPersistenceClaimRelease() async {
        guard transitionClaims.startPersistenceClaimed else { return }
        await withCheckedContinuation { continuation in
            transitionClaims.startPersistenceWaiters.append(continuation)
        }
    }

    func claimTerminalTransition() -> Bool {
        guard !transitionClaims.pendingCancellation, !transitionClaims.terminalTransitionClaimed,
            !lifecycle.state.isTerminal
        else { return false }
        transitionClaims.terminalTransitionClaimed = true
        return true
    }

    func releaseTerminalTransitionClaim() {
        guard !lifecycle.state.isTerminal else { return }
        transitionClaims.terminalTransitionClaimed = false
        resumeTerminalTransitionClaimWaiters()
    }

    func finishClaimedTerminalTransition(
        to newState: DownloadState,
        error: DownloadError?
    ) -> Bool {
        guard transitionClaims.terminalTransitionClaimed,
            !lifecycle.state.isTerminal,
            newState.isTerminal,
            lifecycle.state.canTransition(to: newState)
        else {
            return false
        }
        lifecycle.error = error
        transitionClaims.pendingCancellation = false
        updateState(newState)
        resumeTerminalTransitionClaimWaiters()
        return true
    }

    func transitionToTerminal(
        _ newState: DownloadState,
        error: DownloadError?
    ) -> DownloadTerminalTransitionResult {
        guard !lifecycle.state.isTerminal else { return .alreadyTerminal }
        if transitionClaims.terminalTransitionClaimed {
            if newState == .cancelled {
                transitionClaims.pendingCancellation = true
            }
            return .busy
        }
        guard !transitionClaims.pendingCancellation || newState == .cancelled else { return .busy }
        guard newState.isTerminal, lifecycle.state.canTransition(to: newState) else {
            return .busy
        }
        if newState == .cancelled {
            transitionClaims.pendingCancellation = false
        }
        transitionClaims.terminalTransitionClaimed = true
        lifecycle.error = error
        updateState(newState)
        return .transitioned
    }

    func transitionToFailureFinalizing(
        error: DownloadError
    ) -> DownloadTerminalTransitionResult {
        guard !transitionClaims.failureFinalizationInProgress else { return .busy }
        let result = transitionToTerminal(.failed, error: error)
        if result == .transitioned {
            transitionClaims.failureFinalizationInProgress = true
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
        guard transitionClaims.failureFinalizationInProgress else { return }
        await withCheckedContinuation { continuation in
            transitionClaims.failureFinalizationWaiters.append(continuation)
        }
    }

    func finishFailureFinalization() {
        guard transitionClaims.failureFinalizationInProgress else { return }
        transitionClaims.failureFinalizationInProgress = false
        let waiters = transitionClaims.failureFinalizationWaiters
        transitionClaims.failureFinalizationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func requestCancellationClaimingPersistenceCleanup() async -> DownloadTerminalTransitionResult {
        while true {
            let result = transitionToTerminal(.cancelled, error: .cancelled)
            if result == .transitioned || result == .alreadyTerminal {
                guard !transitionClaims.terminalPersistenceCleanupClaimed else { return .busy }
                transitionClaims.terminalPersistenceCleanupClaimed = true
                if result == .alreadyTerminal, lifecycle.state == .failed {
                    transitionClaims.manualRetryInvalidatedByCancellation = true
                }
                return result
            }
            guard result == .busy, transitionClaims.pendingCancellation else { return result }
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
                guard !transitionClaims.terminalPersistenceCleanupClaimed else { return .busy }
                transitionClaims.terminalPersistenceCleanupClaimed = true
                if result == .alreadyTerminal, lifecycle.state == .failed {
                    transitionClaims.manualRetryInvalidatedByCancellation = true
                }
                return result
            }
            guard result == .busy, transitionClaims.pendingCancellation else { return result }
            await waitForTerminalTransitionClaimResolution()
        }
    }

    func releaseTerminalPersistenceCleanupClaim() {
        guard transitionClaims.terminalPersistenceCleanupClaimed else { return }
        transitionClaims.terminalPersistenceCleanupClaimed = false
        let waiters = transitionClaims.terminalPersistenceCleanupWaiters
        transitionClaims.terminalPersistenceCleanupWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// State-machine-only cancellation used by reducer tests. Manager
    /// lifecycle code uses the persistence-cleanup claiming variant above.
    func requestCancellation() async -> DownloadTerminalTransitionResult {
        while true {
            let result = transitionToTerminal(.cancelled, error: .cancelled)
            guard result == .busy, transitionClaims.pendingCancellation else { return result }
            await waitForTerminalTransitionClaimResolution()
        }
    }

    func waitForTerminalTransitionClaimResolution() async {
        guard transitionClaims.terminalTransitionClaimed, !lifecycle.state.isTerminal else { return }
        await withCheckedContinuation { continuation in
            transitionClaims.terminalTransitionWaiters.append(continuation)
        }
    }

    private func resumeTerminalTransitionClaimWaiters() {
        let waiters = transitionClaims.terminalTransitionWaiters
        transitionClaims.terminalTransitionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Reconstructs the retained terminal outcome for subscribers that attach
    /// after the live event partition has already been retired. Returning the
    /// value from the task actor avoids a manager-wide tombstone table whose
    /// memory would otherwise grow with every completed download.
    func terminalEvent() -> DownloadEvent? {
        switch lifecycle.state {
        case .completed:
            return .completed(destinationURL)
        case .failed:
            guard let error = lifecycle.error else { return nil }
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

        if lifecycle.state == .failed,
            case .restorationMissingSystemTask? = lifecycle.error,
            lifecycle.admitsMissingSystemRestoredSuccess,
            transitionClaims.terminalTransitionClaimed
        {
            lifecycle.admitsMissingSystemRestoredSuccess = false
            lifecycle.state = .downloading
            lifecycle.error = nil
            transitionClaims.terminalTransitionClaimed = false
            transitionClaims.pendingCancellation = false
            return lifecycleSnapshot()
        }

        guard lifecycle.state == .paused,
            lifecycle.admitsRestoredSuccessWhilePaused,
            !transitionClaims.terminalTransitionClaimed,
            !transitionClaims.pendingCancellation
        else { return nil }

        lifecycle.admitsRestoredSuccessWhilePaused = false
        lifecycle.state = .downloading
        lifecycle.error = nil
        transitionClaims.terminalTransitionClaimed = false
        transitionClaims.pendingCancellation = false
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
        guard !transitionClaims.pendingCancellation,
            !transitionClaims.terminalTransitionClaimed,
            lifecycleSnapshot() == expected,
            lifecycle.state == .downloading
        else {
            return false
        }
        lifecycle.resumeData = resumeData
        updateState(.paused)
        return true
    }

    func reset() {
        lifecycle.state = .idle
        lifecycle.progress = .zero
        lifecycle.retryCount = 0
        lifecycle.totalRetryCount = 0
        lifecycle.resumeData = nil
        lifecycle.error = nil
        lifecycle.generation = 0
        lifecycle.attempt = 0
        lifecycle.lastProgressAt = nil
        transitionClaims.terminalTransitionClaimed = false
        transitionClaims.pendingCancellation = false
        transitionClaims.failureFinalizationInProgress = false
        lifecycle.admitsRestoredSuccessWhilePaused = false
        lifecycle.admitsMissingSystemRestoredSuccess = false
        transitionClaims.manualRetryInvalidatedByCancellation = false
        releaseStartPersistenceClaim()
        resumeTerminalTransitionClaimWaiters()
        let failureWaiters = transitionClaims.failureFinalizationWaiters
        transitionClaims.failureFinalizationWaiters.removeAll(keepingCapacity: false)
        for waiter in failureWaiters {
            waiter.resume()
        }
    }

    func beginManualRetry() async -> DownloadTaskLifecycleSnapshot? {
        while transitionClaims.terminalPersistenceCleanupClaimed {
            await withCheckedContinuation { continuation in
                transitionClaims.terminalPersistenceCleanupWaiters.append(continuation)
            }
        }
        guard !transitionClaims.pendingCancellation,
            !transitionClaims.manualRetryInvalidatedByCancellation,
            lifecycle.state == .failed
        else { return nil }
        let nextGeneration = lifecycle.generation + 1
        reset()
        startAttempt(generation: nextGeneration, attempt: 0)
        return lifecycleSnapshot()
    }

    func advanceAttempt(
        ifMatching expected: DownloadTaskLifecycleSnapshot
    ) -> DownloadTaskLifecycleSnapshot? {
        guard !transitionClaims.pendingCancellation,
            !transitionClaims.terminalTransitionClaimed,
            !lifecycle.state.isTerminal,
            lifecycleSnapshot() == expected
        else {
            return nil
        }
        startNextAttemptInCurrentGeneration()
        return lifecycleSnapshot()
    }

    func startNextAttemptInCurrentGeneration() {
        startAttempt(generation: lifecycle.generation, attempt: lifecycle.attempt + 1)
    }

    /// Record the start of a new download attempt by reducing through
    /// ``DownloadLifecycleReducer`` and applying any emitted
    /// ``DownloadLifecycleEffect/advancedEpoch`` effect.
    ///
    /// The reducer keeps the visible ``state`` unchanged on this path —
    /// epoch advancement is orthogonal to the transition table — so this
    /// method only updates `lifecycle.generation` / `lifecycle.attempt`. This is internal
    /// lifecycle bookkeeping; public callers should observe
    /// ``generation`` and ``attempt`` instead of trying to drive them.
    func startAttempt(generation: Int, attempt: Int) {
        let reduction = DownloadLifecycleReducer.reduce(
            state: lifecycle.state,
            event: .startAttempt(generation: generation, attempt: attempt)
        )
        for effect in reduction.effects {
            switch effect {
            case .advancedEpoch(let nextGeneration, let nextAttempt):
                lifecycle.generation = nextGeneration
                lifecycle.attempt = nextAttempt
                // A fresh attempt has no real progress timestamp yet. Keeping
                // the prior epoch's value would let the inactivity watchdog
                // cancel a freshly resumed/retried `URLSessionDownloadTask`
                // before its first progress callback arrives — comparing
                // `now` against a pause-era timestamp.
                lifecycle.lastProgressAt = nil
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
