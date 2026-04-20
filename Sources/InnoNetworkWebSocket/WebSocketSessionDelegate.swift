import Foundation
import InnoNetwork
import os


package final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate {
    private let callbacks: WebSocketSessionDelegateCallbacks
    private let backgroundCompletionStore: BackgroundCompletionStore

    package init(
        callbacks: WebSocketSessionDelegateCallbacks,
        backgroundCompletionStore: BackgroundCompletionStore
    ) {
        self.callbacks = callbacks
        self.backgroundCompletionStore = backgroundCompletionStore
        super.init()
    }

    package func urlSession(
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

    package func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        _ = session
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        // Convert Apple's close-code enum to the library's `WebSocketCloseCode`
        // at the Foundation boundary. All downstream code works with the
        // canonical type so retryable variants (1012/1013) and custom (3xxx/4xxx)
        // codes survive the trip without losing information.
        callbacks.handleDisconnected(
            taskIdentifier: webSocketTask.taskIdentifier,
            closeCode: WebSocketCloseCode(closeCode),
            reason: reasonString
        )
    }

    package func urlSession(
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

    package func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        _ = session
        Task {
            guard let completion = await backgroundCompletionStore.take() else { return }
            await MainActor.run {
                completion()
            }
        }
    }
}


package final class WebSocketSessionDelegateCallbacks: Sendable {
    package typealias ConnectedHandler = @Sendable (Int, String?) -> Void
    package typealias DisconnectedHandler = @Sendable (Int, WebSocketCloseCode, String?) -> Void
    package typealias ErrorHandler = @Sendable (Int, SendableUnderlyingError, Int?) -> Void

    private let connectedHandlerLock = OSAllocatedUnfairLock<ConnectedHandler?>(initialState: nil)
    private let disconnectedHandlerLock = OSAllocatedUnfairLock<DisconnectedHandler?>(initialState: nil)
    private let errorHandlerLock = OSAllocatedUnfairLock<ErrorHandler?>(initialState: nil)

    package init() {}

    package func setHandlers(
        onConnected: @escaping ConnectedHandler,
        onDisconnected: @escaping DisconnectedHandler,
        onError: @escaping ErrorHandler
    ) {
        connectedHandlerLock.withLock { $0 = onConnected }
        disconnectedHandlerLock.withLock { $0 = onDisconnected }
        errorHandlerLock.withLock { $0 = onError }
    }

    package func handleConnected(taskIdentifier: Int, protocolName: String?) {
        connectedHandlerLock.withLock { $0 }?(taskIdentifier, protocolName)
    }

    package func handleDisconnected(taskIdentifier: Int, closeCode: WebSocketCloseCode, reason: String?) {
        disconnectedHandlerLock.withLock { $0 }?(taskIdentifier, closeCode, reason)
    }

    package func handleError(taskIdentifier: Int, error: SendableUnderlyingError, statusCode: Int?) {
        errorHandlerLock.withLock { $0 }?(taskIdentifier, error, statusCode)
    }
}


package actor BackgroundCompletionStore {
    private var completion: (@Sendable () -> Void)?

    package init() {}

    package func set(_ completion: @escaping @Sendable () -> Void) {
        self.completion = completion
    }

    package func take() -> (@Sendable () -> Void)? {
        let stored = completion
        completion = nil
        return stored
    }
}
