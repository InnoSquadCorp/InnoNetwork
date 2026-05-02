import Foundation

/// Protocol abstraction over `URLSessionWebSocketTask` used internally by the
/// WebSocket runtime. The production conformance is `URLSessionWebSocketTask`
/// itself; tests can inject a stub implementation.
package protocol WebSocketURLTask: AnyObject, Sendable {
    var taskIdentifier: Int { get }
    var maximumMessageSize: Int { get set }
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func cancel()
}


/// Protocol abstraction over `URLSession` for WebSocket task creation.
/// The production conformance is `URLSession`; tests can inject a stub.
package protocol WebSocketURLSession: AnyObject, Sendable {
    func makeWebSocketTask(with request: URLRequest) -> any WebSocketURLTask
    func finishTasksAndInvalidate()
    func invalidateAndCancel()
}


extension URLSessionWebSocketTask: WebSocketURLTask {}


extension URLSession: WebSocketURLSession {
    package func makeWebSocketTask(with request: URLRequest) -> any WebSocketURLTask {
        let task: URLSessionWebSocketTask = self.webSocketTask(with: request)
        return task
    }
}
