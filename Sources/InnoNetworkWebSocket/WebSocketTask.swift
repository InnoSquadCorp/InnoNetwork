import Foundation

public actor WebSocketTask: Identifiable {
    public nonisolated let id: String
    public nonisolated let url: URL
    public let subprotocols: [String]?

    private var _state: WebSocketState = .idle
    private var _attemptedReconnectCount: Int = 0
    private var _successfulReconnectCount: Int = 0
    private var _pingCounter: Int = 0
    private var _inFlightSends: Int = 0
    private var _error: WebSocketError?
    private var _closeCode: WebSocketCloseCode?
    private var _closeDisposition: WebSocketCloseDisposition?
    private var _autoReconnectEnabled: Bool = true
    private var _pendingManualDisconnectError: WebSocketError?
    private var _awaitingCloseHandshake = false
    private var _connectionGeneration = 0

    public var state: WebSocketState { _state }

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
    public var error: WebSocketError? { _error }
    public var closeCode: WebSocketCloseCode? { _closeCode }
    /// Library-classified reason for the most recent close, observable after
    /// the task reaches `.disconnected` / `.failed`. `nil` until the task
    /// completes at least once. Values are stable across minor releases but
    /// new cases may be added (prefer `@unknown default`).
    public var closeDisposition: WebSocketCloseDisposition? { _closeDisposition }
    public var autoReconnectEnabled: Bool { _autoReconnectEnabled }
    public var awaitingCloseHandshake: Bool { _awaitingCloseHandshake }
    package var connectionGeneration: Int { _connectionGeneration }

    public init(url: URL, subprotocols: [String]? = nil, id: String = UUID().uuidString) {
        self.id = id
        self.url = url
        self.subprotocols = subprotocols
    }

    package func updateState(_ newState: WebSocketState) {
        _state = newState
    }

    @discardableResult
    package func advanceConnectionGeneration() -> Int {
        _connectionGeneration += 1
        return _connectionGeneration
    }

    func incrementAttemptedReconnectCount() -> Int {
        _attemptedReconnectCount += 1
        return _attemptedReconnectCount
    }

    func incrementSuccessfulReconnectCount() {
        _successfulReconnectCount += 1
    }

    func setError(_ error: WebSocketError?) {
        _error = error
    }

    func setCloseCode(_ closeCode: WebSocketCloseCode?) {
        _closeCode = closeCode
    }

    func setCloseDisposition(_ disposition: WebSocketCloseDisposition?) {
        _closeDisposition = disposition
    }

    func resetAttemptedReconnectCount() {
        _attemptedReconnectCount = 0
    }

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
        _autoReconnectEnabled = enabled
    }

    func beginManualDisconnect(error: WebSocketError?) {
        _pendingManualDisconnectError = error
        _awaitingCloseHandshake = true
    }

    func completeManualDisconnect() -> WebSocketError? {
        let error = _pendingManualDisconnectError
        _pendingManualDisconnectError = nil
        _awaitingCloseHandshake = false
        return error
    }

    func clearManualDisconnectState() {
        _pendingManualDisconnectError = nil
        _awaitingCloseHandshake = false
    }

    func isClientInitiatedCloseFlow() -> Bool {
        _awaitingCloseHandshake || _pendingManualDisconnectError != nil
    }

    func reset() {
        _state = .idle
        _attemptedReconnectCount = 0
        _successfulReconnectCount = 0
        _pingCounter = 0
        _inFlightSends = 0
        _error = nil
        _closeCode = nil
        _closeDisposition = nil
        _autoReconnectEnabled = true
        _pendingManualDisconnectError = nil
        _awaitingCloseHandshake = false
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
