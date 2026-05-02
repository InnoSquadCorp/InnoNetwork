import Foundation

public actor WebSocketTask: Identifiable {
    /// Stable identifier for this logical WebSocket task.
    public nonisolated let id: String

    /// Endpoint URL used when the manager creates or retries the underlying transport task.
    public nonisolated let url: URL

    /// Optional WebSocket subprotocols advertised during the opening handshake.
    public let subprotocols: [String]?

    private var lifecycleState: WebSocketLifecycleState = .initial
    private var _attemptedReconnectCount: Int = 0
    private var _successfulReconnectCount: Int = 0
    private var _pingCounter: Int = 0
    private var _inFlightSends: Int = 0
    private var _error: WebSocketError?
    private var _closeCode: WebSocketCloseCode?
    private var _closeDisposition: WebSocketCloseDisposition?
    private var _reconnectWindowStartedAt: Date?

    /// Current public lifecycle state projected from the reducer-owned internal state.
    public var state: WebSocketState { lifecycleState.publicState }

    /// Reconnect attempts dispatched since the most recent successful
    /// connection (or task start). Includes the attempt currently in flight.
    ///
    /// The counter is incremented **before** the library checks
    /// `maxReconnectAttempts`, so observers polling this value during the
    /// transition into `.failed` may briefly see `maxReconnectAttempts + 1`
    /// — that single overshoot represents the rejected attempt that triggered
    /// the `.exceeded` decision. The counter resets to `0` whenever a
    /// connection becomes ready or `reset()` is called. Use this for "did we
    /// even try recently?" alarms.
    public var attemptedReconnectCount: Int { _attemptedReconnectCount }

    /// Cumulative number of reconnect attempts that successfully re-entered
    /// the `.connected` state for the lifetime of this task. Unlike
    /// ``attemptedReconnectCount`` this counter is **not** reset on each
    /// successful connection — it only resets when ``reset()`` is invoked.
    /// Use this for SLO dashboards that need "how flaky was this socket?".
    public var successfulReconnectCount: Int { _successfulReconnectCount }

    /// Number of `send(_:message:)` / `send(_:string:)` operations currently
    /// awaiting completion on this task. Used by the manager's send-queue
    /// guard to enforce ``WebSocketConfiguration/sendQueueLimit``.
    public var inFlightSendCount: Int { _inFlightSends }

    /// Most recent lifecycle error, including terminal failures and caller-initiated close context.
    public var error: WebSocketError? { _error }

    /// Close code requested or observed by the current lifecycle, or `nil` while the socket is open.
    public var closeCode: WebSocketCloseCode? { _closeCode }

    /// Library-classified reason for the most recent close, observable after
    /// the task reaches `.disconnected` / `.failed`. `nil` until the task
    /// completes at least once. Values are stable across minor releases but
    /// new cases may be added (prefer `@unknown default`).
    public var closeDisposition: WebSocketCloseDisposition? { _closeDisposition }

    /// Whether automatic reconnect is currently allowed for this task.
    public var autoReconnectEnabled: Bool { lifecycleState.autoReconnectEnabled }

    /// Whether the task is waiting for a peer close acknowledgement after a caller-initiated close.
    public var awaitingCloseHandshake: Bool { lifecycleState.awaitingCloseHandshake }
    package var connectionGeneration: Int { lifecycleState.generation }
    package var currentLifecycleState: WebSocketLifecycleState { lifecycleState }

    public init(url: URL, subprotocols: [String]? = nil, id: String = UUID().uuidString) {
        self.id = id
        self.url = url
        self.subprotocols = subprotocols
    }

    @discardableResult
    package func updateState(_ newState: WebSocketState) -> WebSocketStateTransitionResult {
        let previousState = lifecycleState.publicState
        guard previousState.canTransition(to: newState) else {
            return .rejected(previous: previousState, next: newState)
        }

        lifecycleState = lifecycleState.replacingPublicState(newState)
        syncLifecycleMetadata()
        return .applied(previous: previousState, next: newState)
    }

    package func restoreStateForTesting(_ state: WebSocketState) {
        lifecycleState = lifecycleState.replacingPublicState(state)
        syncLifecycleMetadata()
    }

    @discardableResult
    package func applyLifecycleEvent(
        _ event: WebSocketLifecycleEvent,
        context: WebSocketLifecycleDecisionContext = .init()
    ) -> WebSocketLifecycleTransition {
        let transition = WebSocketLifecycleReducer.reduce(
            state: lifecycleState,
            event: event,
            context: context
        )
        guard !transition.isIgnoredCallback else { return transition }
        lifecycleState = transition.state
        syncLifecycleMetadata()
        return transition
    }

    @discardableResult
    package func advanceConnectionGeneration() -> Int {
        let nextGeneration = lifecycleState.generation + 1
        lifecycleState = lifecycleState.replacingGeneration(nextGeneration)
        return nextGeneration
    }

    func incrementAttemptedReconnectCount() -> Int {
        _attemptedReconnectCount += 1
        lifecycleState = lifecycleState.withAttempt(_attemptedReconnectCount)
        return _attemptedReconnectCount
    }

    func incrementSuccessfulReconnectCount() {
        _successfulReconnectCount += 1
    }

    func setError(_ error: WebSocketError?) {
        _error = error
        lifecycleState = lifecycleState.withError(error)
    }

    func setCloseCode(_ closeCode: WebSocketCloseCode?) {
        _closeCode = closeCode
        lifecycleState = lifecycleState.withCloseCode(closeCode)
    }

    func setCloseDisposition(_ disposition: WebSocketCloseDisposition?) {
        _closeDisposition = disposition
        lifecycleState = lifecycleState.withCloseDisposition(disposition)
    }

    func resetAttemptedReconnectCount() {
        _attemptedReconnectCount = 0
        lifecycleState = lifecycleState.withAttempt(0)
    }

    /// Marks the start of a reconnect window if one is not already in flight.
    /// The reconnect coordinator stamps this on the first reconnect attempt
    /// after a clean connection and uses ``reconnectWindowStartedAt`` to
    /// enforce ``WebSocketConfiguration/reconnectMaxTotalDuration``.
    package func beginReconnectWindowIfNeeded(now: Date) {
        if _reconnectWindowStartedAt == nil {
            _reconnectWindowStartedAt = now
        }
    }

    /// Clears the reconnect window stamp. Called after a successful reconnect
    /// or task ``reset()``.
    package func clearReconnectWindow() {
        _reconnectWindowStartedAt = nil
    }

    package var reconnectWindowStartedAt: Date? { _reconnectWindowStartedAt }

    /// Atomically reserves a send slot if one is available. Returns true if
    /// the slot was reserved (caller must pair with ``releaseSendSlot()``);
    /// returns false if the queue is at `limit`.
    package func tryReserveSendSlot(limit: Int) -> Bool {
        guard _inFlightSends < limit else { return false }
        _inFlightSends += 1
        return true
    }

    /// Releases a send slot previously reserved by ``tryReserveSendSlot(limit:)``.
    package func releaseSendSlot() {
        if _inFlightSends > 0 {
            _inFlightSends -= 1
        }
    }

    /// Returns the next monotonic ping sequence number for this task's
    /// current connection. Reset to 0 whenever a new connection becomes
    /// ready (and on `reset()`) so consumers can tell heartbeat attempts
    /// within a single connection apart.
    func incrementPingCounter() -> Int {
        _pingCounter += 1
        return _pingCounter
    }

    func resetPingCounter() {
        _pingCounter = 0
    }

    func setAutoReconnectEnabled(_ enabled: Bool) {
        lifecycleState = lifecycleState.withAutoReconnectEnabled(enabled)
    }

    func beginManualDisconnect(error: WebSocketError?) {
        let closeCode = lifecycleState.closeCode ?? .normalClosure
        lifecycleState = .disconnecting(
            generation: lifecycleState.generation,
            attempt: lifecycleState.attempt,
            manualDisconnect: WebSocketManualDisconnect(closeCode: closeCode, error: error)
        )
    }

    func completeManualDisconnect() -> WebSocketError? {
        lifecycleState.manualDisconnect?.error
    }

    func clearManualDisconnectState() {
        if case .disconnecting(let generation, let attempt, let manualDisconnect) = lifecycleState {
            lifecycleState = .disconnected(
                generation: generation,
                attempt: attempt,
                autoReconnect: false,
                closeCode: manualDisconnect.closeCode,
                disposition: nil,
                error: nil
            )
            _closeCode = manualDisconnect.closeCode
            _closeDisposition = nil
            _error = nil
        }
    }

    func isClientInitiatedCloseFlow() -> Bool {
        lifecycleState.awaitingCloseHandshake
    }

    func reset() {
        lifecycleState = .idle(
            generation: lifecycleState.generation,
            attempt: 0,
            autoReconnect: true
        )
        _attemptedReconnectCount = 0
        _successfulReconnectCount = 0
        _pingCounter = 0
        _inFlightSends = 0
        _error = nil
        _closeCode = nil
        _closeDisposition = nil
        _reconnectWindowStartedAt = nil
    }

    private func syncLifecycleMetadata() {
        _error = lifecycleState.error
        _closeCode = lifecycleState.closeCode
        _closeDisposition = lifecycleState.closeDisposition
    }
}


extension WebSocketTask: Hashable {
    public nonisolated static func == (lhs: WebSocketTask, rhs: WebSocketTask) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
