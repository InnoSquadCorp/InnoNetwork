import Foundation


public actor WebSocketTask: Identifiable {
    public nonisolated let id: String
    public nonisolated let url: URL
    public let subprotocols: [String]?

    private var _state: WebSocketState = .idle
    private var _reconnectCount: Int = 0
    private var _pingCounter: Int = 0
    private var _error: WebSocketError?
    private var _closeCode: WebSocketCloseCode?
    private var _closeDisposition: WebSocketCloseDisposition?
    private var _autoReconnectEnabled: Bool = true
    private var _pendingManualDisconnectError: WebSocketError?
    private var _awaitingCloseHandshake = false

    public var state: WebSocketState { _state }
    public var reconnectCount: Int { _reconnectCount }
    public var error: WebSocketError? { _error }
    public var closeCode: WebSocketCloseCode? { _closeCode }
    /// Library-classified reason for the most recent close, observable after
    /// the task reaches `.disconnected` / `.failed`. `nil` until the task
    /// completes at least once. Values are stable across minor releases but
    /// new cases may be added (prefer `@unknown default`).
    public var closeDisposition: WebSocketCloseDisposition? { _closeDisposition }
    public var autoReconnectEnabled: Bool { _autoReconnectEnabled }
    public var awaitingCloseHandshake: Bool { _awaitingCloseHandshake }

    public init(url: URL, subprotocols: [String]? = nil, id: String = UUID().uuidString) {
        self.id = id
        self.url = url
        self.subprotocols = subprotocols
    }

    func updateState(_ newState: WebSocketState) {
        _state = newState
    }

    func incrementReconnectCount() -> Int {
        _reconnectCount += 1
        return _reconnectCount
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

    func resetReconnectCount() {
        _reconnectCount = 0
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
        _reconnectCount = 0
        _pingCounter = 0
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
