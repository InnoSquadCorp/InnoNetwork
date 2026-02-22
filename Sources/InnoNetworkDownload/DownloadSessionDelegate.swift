import Foundation
import InnoNetwork
import os


final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private let callbacks: DownloadSessionDelegateCallbacks
    private let backgroundCompletionStore: BackgroundCompletionStore

    init(
        callbacks: DownloadSessionDelegateCallbacks,
        backgroundCompletionStore: BackgroundCompletionStore
    ) {
        self.callbacks = callbacks
        self.backgroundCompletionStore = backgroundCompletionStore
        super.init()
    }
    
    func urlSession(
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
    
    func urlSession(
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
    
    func urlSession(
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


final class DownloadSessionDelegateCallbacks: Sendable {
    typealias ProgressHandler = @Sendable (Int, Int64, Int64, Int64) -> Void
    typealias CompletionHandler = @Sendable (Int, URL?, SendableUnderlyingError?) -> Void

    private let progressHandlerLock = OSAllocatedUnfairLock<ProgressHandler?>(initialState: nil)
    private let completionHandlerLock = OSAllocatedUnfairLock<CompletionHandler?>(initialState: nil)

    func setHandlers(
        onProgress: @escaping ProgressHandler,
        onCompletion: @escaping CompletionHandler
    ) {
        progressHandlerLock.withLock { $0 = onProgress }
        completionHandlerLock.withLock { $0 = onCompletion }
    }

    func handleProgress(
        taskIdentifier: Int,
        bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandlerLock.withLock { $0 }?(
            taskIdentifier,
            bytesWritten,
            totalBytesWritten,
            totalBytesExpectedToWrite
        )
    }

    func handleCompletion(
        taskIdentifier: Int,
        location: URL?,
        error: SendableUnderlyingError?
    ) {
        completionHandlerLock.withLock { $0 }?(taskIdentifier, location, error)
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
