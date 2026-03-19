import Foundation
import InnoNetwork
import os


final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate {
    private let callbacks: WebSocketSessionDelegateCallbacks
    private let backgroundCompletionStore: BackgroundCompletionStore

    init(
        callbacks: WebSocketSessionDelegateCallbacks,
        backgroundCompletionStore: BackgroundCompletionStore
    ) {
        self.callbacks = callbacks
        self.backgroundCompletionStore = backgroundCompletionStore
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        _ = session
        callbacks.handleConnected(
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
        _ = session
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        callbacks.handleDisconnected(
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
        _ = session
        guard let error = error else { return }
        callbacks.handleError(
            taskIdentifier: task.taskIdentifier,
            error: SendableUnderlyingError(error),
            statusCode: (task.response as? HTTPURLResponse)?.statusCode
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        _ = session
        Task {
            guard let completion = await backgroundCompletionStore.take() else { return }
            await MainActor.run {
                completion()
            }
        }
    }
}


final class WebSocketSessionDelegateCallbacks: Sendable {
    typealias ConnectedHandler = @Sendable (Int, String?) -> Void
    typealias DisconnectedHandler = @Sendable (Int, URLSessionWebSocketTask.CloseCode, String?) -> Void
    typealias ErrorHandler = @Sendable (Int, SendableUnderlyingError, Int?) -> Void

    private let connectedHandlerLock = OSAllocatedUnfairLock<ConnectedHandler?>(initialState: nil)
    private let disconnectedHandlerLock = OSAllocatedUnfairLock<DisconnectedHandler?>(initialState: nil)
    private let errorHandlerLock = OSAllocatedUnfairLock<ErrorHandler?>(initialState: nil)

    func setHandlers(
        onConnected: @escaping ConnectedHandler,
        onDisconnected: @escaping DisconnectedHandler,
        onError: @escaping ErrorHandler
    ) {
        connectedHandlerLock.withLock { $0 = onConnected }
        disconnectedHandlerLock.withLock { $0 = onDisconnected }
        errorHandlerLock.withLock { $0 = onError }
    }

    func handleConnected(taskIdentifier: Int, protocolName: String?) {
        connectedHandlerLock.withLock { $0 }?(taskIdentifier, protocolName)
    }

    func handleDisconnected(taskIdentifier: Int, closeCode: URLSessionWebSocketTask.CloseCode, reason: String?) {
        disconnectedHandlerLock.withLock { $0 }?(taskIdentifier, closeCode, reason)
    }

    func handleError(taskIdentifier: Int, error: SendableUnderlyingError, statusCode: Int?) {
        errorHandlerLock.withLock { $0 }?(taskIdentifier, error, statusCode)
    }
}


actor BackgroundCompletionStore {
    private var completion: (@Sendable () -> Void)?

    func set(_ completion: @escaping @Sendable () -> Void) {
        self.completion = completion
    }

    func take() -> (@Sendable () -> Void)? {
        let stored = completion
        completion = nil
        return stored
    }
}
