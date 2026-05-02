import Foundation
import InnoNetwork
import os

package final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private let callbacks: DownloadSessionDelegateCallbacks
    private let backgroundCompletionStore: BackgroundCompletionStore

    package init(
        callbacks: DownloadSessionDelegateCallbacks,
        backgroundCompletionStore: BackgroundCompletionStore
    ) {
        self.callbacks = callbacks
        self.backgroundCompletionStore = backgroundCompletionStore
        super.init()
    }

    package func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        callbacks.handleProgress(
            taskIdentifier: downloadTask.taskIdentifier,
            bytesWritten: bytesWritten,
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
    }

    package func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        callbacks.handleCompletion(
            taskIdentifier: downloadTask.taskIdentifier,
            location: location,
            error: nil
        )
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            callbacks.handleCompletion(
                taskIdentifier: task.taskIdentifier,
                location: nil,
                error: SendableUnderlyingError(error)
            )
        }
    }

    package func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task {
            guard let completion = await backgroundCompletionStore.take() else { return }
            await MainActor.run {
                completion()
            }
        }
    }

    package func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        callbacks.handleInvalidation(error.map(SendableUnderlyingError.init))
    }
}


package final class DownloadSessionDelegateCallbacks: Sendable {
    package typealias ProgressHandler = @Sendable (Int, Int64, Int64, Int64) -> Void
    package typealias CompletionHandler = @Sendable (Int, URL?, SendableUnderlyingError?) -> Void
    package typealias InvalidationHandler = @Sendable (SendableUnderlyingError?) -> Void

    private struct Handlers {
        var progress: ProgressHandler?
        var completion: CompletionHandler?
        var invalidation: InvalidationHandler?
    }

    private let handlersLock = OSAllocatedUnfairLock<Handlers>(initialState: .init())

    package init() {}

    package func setHandlers(
        onProgress: @escaping ProgressHandler,
        onCompletion: @escaping CompletionHandler
    ) {
        handlersLock.withLock {
            $0.progress = onProgress
            $0.completion = onCompletion
        }
    }

    package func setInvalidationHandler(_ callback: @escaping InvalidationHandler) {
        handlersLock.withLock {
            $0.invalidation = callback
        }
    }

    package func handleProgress(
        taskIdentifier: Int,
        bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        handlersLock.withLock { $0.progress }?(
            taskIdentifier,
            bytesWritten,
            totalBytesWritten,
            totalBytesExpectedToWrite
        )
    }

    package func handleCompletion(
        taskIdentifier: Int,
        location: URL?,
        error: SendableUnderlyingError?
    ) {
        handlersLock.withLock { $0.completion }?(taskIdentifier, location, error)
    }

    package func handleInvalidation(_ error: SendableUnderlyingError?) {
        handlersLock.withLock { $0.invalidation }?(error)
    }
}


package actor BackgroundCompletionStore {
    private var completion: (@Sendable () -> Void)?
    private var didFinishEvents = false

    package init() {}

    package func set(_ completion: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
        if didFinishEvents {
            didFinishEvents = false
            return completion
        }
        self.completion = completion
        return nil
    }

    package func take() -> (@Sendable () -> Void)? {
        guard let stored = completion else {
            didFinishEvents = true
            return nil
        }
        completion = nil
        didFinishEvents = false
        return stored
    }
}
