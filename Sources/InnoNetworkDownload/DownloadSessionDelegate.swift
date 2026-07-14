import Foundation
import InnoNetwork
import os

package final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private let callbacks: DownloadSessionDelegateCallbacks
    private let backgroundCompletionStore: BackgroundCompletionStore
    private let completionStager: DownloadCompletionStager

    package init(
        callbacks: DownloadSessionDelegateCallbacks,
        backgroundCompletionStore: BackgroundCompletionStore,
        completionStager: DownloadCompletionStager = DownloadCompletionStager()
    ) {
        self.callbacks = callbacks
        self.backgroundCompletionStore = backgroundCompletionStore
        self.completionStager = completionStager
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
        do {
            let stagedLocation = try completionStager.stage(
                location,
                taskIdentifier: downloadTask.taskIdentifier
            )
            callbacks.handleCompletion(
                taskIdentifier: downloadTask.taskIdentifier,
                location: stagedLocation,
                error: nil
            )
        } catch {
            callbacks.handleCompletion(
                taskIdentifier: downloadTask.taskIdentifier,
                location: nil,
                error: SendableUnderlyingError(error)
            )
        }
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
        var isDrainingPendingCompletions = false
        var pendingCompletions: [(Int, URL?, SendableUnderlyingError?)] = []
    }

    private let handlersLock = OSAllocatedUnfairLock<Handlers>(initialState: .init())

    package init() {}

    package func setHandlers(
        onProgress: @escaping ProgressHandler,
        onCompletion: @escaping CompletionHandler
    ) {
        var pending = handlersLock.withLock { state -> [(Int, URL?, SendableUnderlyingError?)] in
            state.progress = onProgress
            state.completion = onCompletion
            state.isDrainingPendingCompletions = true
            let pending = state.pendingCompletions
            state.pendingCompletions.removeAll(keepingCapacity: true)
            return pending
        }

        // Preserve delegate order across the installation boundary. New
        // completions keep buffering while this loop drains, then switch to
        // direct delivery only after every earlier completion was delivered.
        while true {
            for (taskIdentifier, location, error) in pending {
                onCompletion(taskIdentifier, location, error)
            }
            pending = handlersLock.withLock { state in
                guard !state.pendingCompletions.isEmpty else {
                    state.isDrainingPendingCompletions = false
                    return []
                }
                let next = state.pendingCompletions
                state.pendingCompletions.removeAll(keepingCapacity: true)
                return next
            }
            if pending.isEmpty { break }
        }
    }

    deinit {
        let pendingLocations = handlersLock.withLock { state -> [URL] in
            let locations = state.pendingCompletions.compactMap(\.1)
            state.pendingCompletions.removeAll()
            return locations
        }
        for location in pendingLocations {
            DownloadCompletionStager.removeIfPresent(location)
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
        let handler = handlersLock.withLock { state -> CompletionHandler? in
            guard let completion = state.completion, !state.isDrainingPendingCompletions else {
                state.pendingCompletions.append((taskIdentifier, location, error))
                return nil
            }
            return completion
        }
        handler?(taskIdentifier, location, error)
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
