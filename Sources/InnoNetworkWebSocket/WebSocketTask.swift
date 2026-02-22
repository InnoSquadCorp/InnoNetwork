import Foundation


public actor WebSocketTask: Identifiable {
    public nonisolated let id: String
    public nonisolated let url: URL
    public let subprotocols: [String]?

    private var _state: WebSocketState = .idle
    private var _reconnectCount: Int = 0
    private var _error: WebSocketError?
    private var _closeCode: URLSessionWebSocketTask.CloseCode?
    private var _autoReconnectEnabled: Bool = true

    public var state: WebSocketState { _state }
    public var reconnectCount: Int { _reconnectCount }
    public var error: WebSocketError? { _error }
    public var closeCode: URLSessionWebSocketTask.CloseCode? { _closeCode }
    public var autoReconnectEnabled: Bool { _autoReconnectEnabled }

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

    func setCloseCode(_ closeCode: URLSessionWebSocketTask.CloseCode?) {
        _closeCode = closeCode
    }

    func resetReconnectCount() {
        _reconnectCount = 0
    }

    func setAutoReconnectEnabled(_ enabled: Bool) {
        _autoReconnectEnabled = enabled
    }

    func reset() {
        _state = .idle
        _reconnectCount = 0
        _error = nil
        _closeCode = nil
        _autoReconnectEnabled = true
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
