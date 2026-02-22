import Foundation


final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate {
    weak var manager: WebSocketManager?
    var backgroundCompletionHandler: (() -> Void)?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        manager?.handleConnected(
            taskIdentifier: webSocketTask.taskIdentifier,
            protocolName: protocolName
        )
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        manager?.handleDisconnected(
            taskIdentifier: webSocketTask.taskIdentifier,
            closeCode: closeCode,
            reason: reasonString
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        manager?.handleError(
            taskIdentifier: task.taskIdentifier,
            error: error
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
