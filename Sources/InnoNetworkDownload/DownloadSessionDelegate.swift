import Foundation
import InnoNetwork
import os

package final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private let callbacks: DownloadSessionDelegateCallbacks
    private let backgroundCompletionStore: BackgroundCompletionStore
    private let completionStager: DownloadCompletionStager
    package let completionAdmissionGate: DownloadCompletionAdmissionGate
    private let allowsInsecureHTTP: Bool
    private let rejectedRedirectTaskIdentifiers = OSAllocatedUnfairLock<Set<Int>>(initialState: [])

    package init(
        callbacks: DownloadSessionDelegateCallbacks,
        backgroundCompletionStore: BackgroundCompletionStore,
        completionStager: DownloadCompletionStager = DownloadCompletionStager(),
        completionAdmissionGate: DownloadCompletionAdmissionGate = DownloadCompletionAdmissionGate(),
        allowsInsecureHTTP: Bool = false
    ) {
        self.callbacks = callbacks
        self.backgroundCompletionStore = backgroundCompletionStore
        self.completionStager = completionStager
        self.completionAdmissionGate = completionAdmissionGate
        self.allowsInsecureHTTP = allowsInsecureHTTP
        super.init()
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalRequest =
            task.originalRequest.flatMap { $0.url == nil ? nil : $0 }
            ?? task.currentRequest.flatMap { $0.url == nil ? nil : $0 }
        guard let originalRequest else {
            rejectRedirect(
                task: task,
                targetRequest: newRequest,
                reason: "The download task did not retain its original request.",
                completionHandler: completionHandler
            )
            return
        }
        guard
            let admittedByPolicy = DefaultRedirectPolicy().redirect(
                request: newRequest,
                response: response,
                originalRequest: originalRequest
            )
        else {
            rejectRedirect(
                task: task,
                targetRequest: newRequest,
                reason: "The default redirect policy rejected this redirect.",
                completionHandler: completionHandler
            )
            return
        }

        do {
            try NetworkURLAdmission.validate(
                admittedByPolicy,
                policy: .http(allowsInsecure: allowsInsecureHTTP)
            )
            completionHandler(admittedByPolicy)
        } catch {
            rejectRedirect(
                task: task,
                targetRequest: admittedByPolicy,
                reason: "The redirect target failed network URL admission.",
                completionHandler: completionHandler
            )
        }
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
        guard !isRejectedRedirectTask(downloadTask.taskIdentifier) else {
            return
        }
        let taskDescription = downloadTask.taskDescription ?? ""
        guard !taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            callbacks.handleCompletion(
                taskIdentifier: downloadTask.taskIdentifier,
                taskDescription: downloadTask.taskDescription,
                originalRequestURL: downloadTask.originalRequest?.url,
                currentRequestURL: downloadTask.currentRequest?.url,
                location: nil,
                error: SendableUnderlyingError(
                    DownloadCompletionStagingError.invalidTaskID
                )
            )
            return
        }
        guard
            completionAdmissionGate.beginStaging(
                taskID: taskDescription,
                taskIdentifier: downloadTask.taskIdentifier
            )
        else {
            return
        }
        do {
            let originalRequestURL = downloadTask.originalRequest?.url
            let currentRequestURL = downloadTask.currentRequest?.url
            let stagedCompletion = try completionStager.stage(
                location,
                taskID: taskDescription,
                originalRequestURL: originalRequestURL,
                currentRequestURL: currentRequestURL
            )
            completionAdmissionGate.finishStaging(
                taskID: taskDescription,
                taskIdentifier: downloadTask.taskIdentifier,
                journaled: true
            )
            callbacks.handleCompletion(
                taskIdentifier: downloadTask.taskIdentifier,
                taskDescription: downloadTask.taskDescription,
                originalRequestURL: originalRequestURL,
                currentRequestURL: currentRequestURL,
                payload: .journaled(stagedCompletion),
                error: nil
            )
        } catch {
            completionAdmissionGate.finishStaging(
                taskID: taskDescription,
                taskIdentifier: downloadTask.taskIdentifier,
                journaled: false
            )
            callbacks.handleCompletion(
                taskIdentifier: downloadTask.taskIdentifier,
                taskDescription: downloadTask.taskDescription,
                originalRequestURL: downloadTask.originalRequest?.url,
                currentRequestURL: downloadTask.currentRequest?.url,
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
        if rejectedRedirectTaskIdentifiers.withLock({ $0.remove(task.taskIdentifier) != nil }) {
            return
        }
        if let error = error {
            callbacks.handleCompletion(
                taskIdentifier: task.taskIdentifier,
                taskDescription: task.taskDescription,
                originalRequestURL: task.originalRequest?.url,
                currentRequestURL: task.currentRequest?.url,
                location: nil,
                error: SendableUnderlyingError(error)
            )
        }
    }

    package func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        callbacks.handleBackgroundEventsFinished(
            completion: backgroundCompletionStore.take()
        )
    }

    package func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        callbacks.handleInvalidation(error.map(SendableUnderlyingError.init))
    }

    private func rejectRedirect(
        task: URLSessionTask,
        targetRequest: URLRequest,
        reason: String,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let shouldReport = rejectedRedirectTaskIdentifiers.withLock { identifiers in
            identifiers.insert(task.taskIdentifier).inserted
        }
        if shouldReport {
            callbacks.handleCompletion(
                taskIdentifier: task.taskIdentifier,
                taskDescription: task.taskDescription,
                originalRequestURL: task.originalRequest?.url,
                currentRequestURL: targetRequest.url,
                location: nil,
                error: DownloadRedirectAdmissionFailure.make(
                    targetURL: targetRequest.url,
                    reason: reason
                )
            )
        }
        completionHandler(nil)
        task.cancel()
    }

    private func isRejectedRedirectTask(_ taskIdentifier: Int) -> Bool {
        rejectedRedirectTaskIdentifiers.withLock { $0.contains(taskIdentifier) }
    }
}


package enum DownloadRedirectAdmissionFailure {
    package static let domain = "InnoNetworkDownload.RedirectAdmission"
    package static let code = 1

    package static func make(targetURL: URL?, reason: String) -> SendableUnderlyingError {
        let target = NetworkError.diagnosticURLString(for: targetURL)
        return SendableUnderlyingError(
            domain: domain,
            code: code,
            message: "Rejected redirect target \(target): \(reason)"
        )
    }

    package static func invalidURLDescription(from error: SendableUnderlyingError) -> String? {
        guard error.domain == domain, error.code == code else { return nil }
        return error.message
    }
}


package final class DownloadSessionDelegateCallbacks: Sendable {
    package typealias ProgressHandler = @Sendable (Int, Int64, Int64, Int64) -> Void
    package typealias CompletionHandler =
        @Sendable (Int, String?, URL?, URL?, DownloadCompletionPayload?, SendableUnderlyingError?) -> Void
    package typealias BackgroundEventsFinishedHandler =
        @Sendable ((@Sendable () -> Void)?) -> Void
    package typealias InvalidationHandler = @Sendable (SendableUnderlyingError?) -> Void

    private enum PendingLifecycleEvent {
        case completion(Int, String?, URL?, URL?, DownloadCompletionPayload?, SendableUnderlyingError?)
        case backgroundEventsFinished((@Sendable () -> Void)?)
    }

    private struct Handlers {
        var progress: ProgressHandler?
        var completion: CompletionHandler?
        var backgroundEventsFinished: BackgroundEventsFinishedHandler?
        var invalidation: InvalidationHandler?
        var isDrainingPendingLifecycleEvents = false
        var pendingLifecycleEvents: [PendingLifecycleEvent] = []
    }

    private let handlersLock = OSAllocatedUnfairLock<Handlers>(initialState: .init())

    package init() {}

    package func setHandlers(
        onProgress: @escaping ProgressHandler,
        onCompletion: @escaping CompletionHandler,
        onBackgroundEventsFinished: @escaping BackgroundEventsFinishedHandler = { _ in }
    ) {
        var pending = handlersLock.withLock { state -> [PendingLifecycleEvent] in
            state.progress = onProgress
            state.completion = onCompletion
            state.backgroundEventsFinished = onBackgroundEventsFinished
            state.isDrainingPendingLifecycleEvents = true
            let pending = state.pendingLifecycleEvents
            state.pendingLifecycleEvents.removeAll(keepingCapacity: true)
            return pending
        }

        // Preserve delegate order across the installation boundary. New
        // completions keep buffering while this loop drains, then switch to
        // direct delivery only after every earlier completion was delivered.
        while true {
            for event in pending {
                switch event {
                case .completion(
                    let taskIdentifier,
                    let taskDescription,
                    let originalRequestURL,
                    let currentRequestURL,
                    let payload,
                    let error
                ):
                    onCompletion(
                        taskIdentifier,
                        taskDescription,
                        originalRequestURL,
                        currentRequestURL,
                        payload,
                        error
                    )
                case .backgroundEventsFinished(let completion):
                    onBackgroundEventsFinished(completion)
                }
            }
            pending = handlersLock.withLock { state in
                guard !state.pendingLifecycleEvents.isEmpty else {
                    state.isDrainingPendingLifecycleEvents = false
                    return []
                }
                let next = state.pendingLifecycleEvents
                state.pendingLifecycleEvents.removeAll(keepingCapacity: true)
                return next
            }
            if pending.isEmpty { break }
        }
    }

    deinit {
        let pending = handlersLock.withLock {
            state -> ([DownloadCompletionPayload], [@Sendable () -> Void]) in
            let payloads = state.pendingLifecycleEvents.compactMap {
                event -> DownloadCompletionPayload? in
                guard case .completion(_, _, _, _, let payload, _) = event else { return nil }
                return payload
            }
            let completions = state.pendingLifecycleEvents.compactMap {
                event -> (@Sendable () -> Void)? in
                guard case .backgroundEventsFinished(let completion) = event else { return nil }
                return completion
            }
            state.pendingLifecycleEvents.removeAll()
            return (payloads, completions)
        }
        for payload in pending.0 {
            Self.cleanup(payload)
        }
        for completion in pending.1 {
            Task { @MainActor in
                completion()
            }
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
        taskDescription: String? = nil,
        originalRequestURL: URL? = nil,
        currentRequestURL: URL? = nil,
        payload: DownloadCompletionPayload?,
        error: SendableUnderlyingError?
    ) {
        let handler = handlersLock.withLock { state -> CompletionHandler? in
            guard let completion = state.completion, !state.isDrainingPendingLifecycleEvents else {
                state.pendingLifecycleEvents.append(
                    .completion(
                        taskIdentifier,
                        taskDescription,
                        originalRequestURL,
                        currentRequestURL,
                        payload,
                        error
                    )
                )
                return nil
            }
            return completion
        }
        handler?(
            taskIdentifier,
            taskDescription,
            originalRequestURL,
            currentRequestURL,
            payload,
            error
        )
    }

    /// Package-test compatibility path. Production URLSession delegate
    /// completions use the journal-backed payload overload.
    package func handleCompletion(
        taskIdentifier: Int,
        taskDescription: String? = nil,
        originalRequestURL: URL? = nil,
        currentRequestURL: URL? = nil,
        location: URL?,
        error: SendableUnderlyingError?
    ) {
        handleCompletion(
            taskIdentifier: taskIdentifier,
            taskDescription: taskDescription,
            originalRequestURL: originalRequestURL,
            currentRequestURL: currentRequestURL,
            payload: location.map(DownloadCompletionPayload.legacy),
            error: error
        )
    }

    private static func cleanup(_ payload: DownloadCompletionPayload) {
        switch payload {
        case .journaled:
            // A synchronous delegate already transferred ownership into the
            // deterministic journal. Manager restoration, not callback-holder
            // deinitialization, decides whether to commit or discard it.
            break
        case .legacy(let location):
            DownloadCompletionStager.removeIfPresent(location)
        }
    }

    package func handleBackgroundEventsFinished(
        completion: (@Sendable () -> Void)? = nil
    ) {
        let handler = handlersLock.withLock { state -> BackgroundEventsFinishedHandler? in
            guard let handler = state.backgroundEventsFinished,
                !state.isDrainingPendingLifecycleEvents
            else {
                state.pendingLifecycleEvents.append(
                    .backgroundEventsFinished(completion)
                )
                return nil
            }
            return handler
        }
        handler?(completion)
    }

    package func handleInvalidation(_ error: SendableUnderlyingError?) {
        handlersLock.withLock { $0.invalidation }?(error)
    }
}


package final class BackgroundCompletionStore: Sendable {
    private let completions = OSAllocatedUnfairLock<[@Sendable () -> Void]>(
        initialState: []
    )

    package init() {}

    /// Registers the UIKit completion handler synchronously with the public
    /// nonisolated entry point. A `didFinishEvents` observed without a handler
    /// is intentionally not latched into a later, unrelated background batch.
    package func set(_ newCompletion: @escaping @Sendable () -> Void) {
        completions.withLock { $0.append(newCompletion) }
    }

    package func take() -> (@Sendable () -> Void)? {
        completions.withLock { stored in
            guard !stored.isEmpty else { return nil }
            return stored.removeFirst()
        }
    }
}
