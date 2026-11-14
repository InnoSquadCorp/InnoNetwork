import Foundation
import InnoNetwork
import os

package final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private let callbacks: DownloadSessionDelegateCallbacks
    private let backgroundCompletionStore: BackgroundCompletionStore
    private let completionStager: DownloadCompletionStager
    package let completionAdmissionGate: DownloadCompletionAdmissionGate
    private let allowsInsecureHTTP: Bool
    private let acceptableStatusCodes: Set<Int>
    private let rejectedRedirectTaskIdentifiers = OSAllocatedUnfairLock<Set<Int>>(initialState: [])

    package init(
        callbacks: DownloadSessionDelegateCallbacks,
        backgroundCompletionStore: BackgroundCompletionStore,
        completionStager: DownloadCompletionStager = DownloadCompletionStager(),
        completionAdmissionGate: DownloadCompletionAdmissionGate = DownloadCompletionAdmissionGate(),
        allowsInsecureHTTP: Bool = false,
        acceptableStatusCodes: Set<Int> = DownloadHTTPStatusFailure.defaultAcceptableStatusCodes
    ) {
        self.callbacks = callbacks
        self.backgroundCompletionStore = backgroundCompletionStore
        self.completionStager = completionStager
        self.completionAdmissionGate = completionAdmissionGate
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.acceptableStatusCodes = acceptableStatusCodes
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
        handleFinishedDownload(downloadTask, location: location)
    }

    /// Transport-independent body of `didFinishDownloadingTo`. Foreground
    /// attempts and background-session attempts redelivered after a relaunch
    /// both arrive here, so admission decisions made in this method apply to
    /// restored tasks as well. Package tests drive it with a stub task.
    package func handleFinishedDownload(
        _ downloadTask: any DownloadURLTask,
        location: URL
    ) {
        guard !isRejectedRedirectTask(downloadTask.taskIdentifier) else {
            return
        }
        if let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode,
            !acceptableStatusCodes.contains(statusCode)
        {
            // A download task does not fail on 4xx/5xx: Foundation hands over
            // the error body as if it were the requested file. Never stage
            // it. Foundation removes its temporary file once this callback
            // returns; a non-HTTP response keeps the unvalidated behavior.
            callbacks.handleCompletion(
                taskIdentifier: downloadTask.taskIdentifier,
                taskDescription: downloadTask.taskDescription,
                originalRequestURL: downloadTask.originalRequest?.url,
                currentRequestURL: downloadTask.currentRequest?.url,
                location: nil,
                error: DownloadHTTPStatusFailure.make(
                    statusCode: statusCode,
                    url: downloadTask.currentRequest?.url
                )
            )
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
        handleCompletedAttempt(
            taskIdentifier: task.taskIdentifier,
            taskDescription: task.taskDescription,
            originalRequestURL: task.originalRequest?.url,
            currentRequestURL: task.currentRequest?.url,
            error: error
        )
    }

    /// Transport-independent body of `didCompleteWithError`. Package tests
    /// drive it with the values a stub attempt would report.
    package func handleCompletedAttempt(
        taskIdentifier: Int,
        taskDescription: String?,
        originalRequestURL: URL?,
        currentRequestURL: URL?,
        error: Error?
    ) {
        if rejectedRedirectTaskIdentifiers.withLock({ $0.remove(taskIdentifier) != nil }) {
            return
        }
        if let error = error {
            callbacks.handleCompletion(
                taskIdentifier: taskIdentifier,
                taskDescription: taskDescription,
                originalRequestURL: originalRequestURL,
                currentRequestURL: currentRequestURL,
                payload: nil,
                error: SendableUnderlyingError(error),
                // `SendableUnderlyingError` is a value projection of the
                // NSError and drops its userInfo, so the resume blob has to
                // be lifted out here, before the error is wrapped.
                resumeData: DownloadAttemptResumeData.extract(from: error)
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


/// Resume data Foundation attaches to a failed download attempt.
package enum DownloadAttemptResumeData {
    /// Returns the blob stored under `NSURLSessionDownloadTaskResumeData`,
    /// or `nil` when the failure carries none (the server does not support
    /// range requests, nothing was received yet, the status was rejected).
    package static func extract(from error: Error) -> Data? {
        let userInfo = (error as NSError).userInfo
        guard let resumeData = userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
            !resumeData.isEmpty
        else {
            return nil
        }
        return resumeData
    }

    /// Whether `resumeData` is safe to hand to
    /// `URLSession.downloadTask(withResumeData:)`.
    ///
    /// Foundation's blob is a property list whose root is a dictionary. It
    /// tolerates a malformed dictionary by returning a task without a URL,
    /// which resumed-task admission rejects, but raises an Objective-C
    /// exception for any other property-list root. A blob read back from
    /// persistence is untrusted, so reject that shape before Foundation
    /// sees it and let the caller restart from the source URL instead.
    package static func isStructurallyUsable(_ resumeData: Data) -> Bool {
        guard !resumeData.isEmpty,
            let propertyList = try? PropertyListSerialization.propertyList(
                from: resumeData,
                options: [],
                format: nil
            )
        else {
            return false
        }
        return propertyList is [String: Any]
    }

    /// Whether a task Foundation rebuilt from opaque resume data still
    /// targets the admitted logical source. Shared by `resume(_:)` and the
    /// automatic retry so both apply one admission rule.
    package static func admits(
        _ urlTask: any DownloadURLTask,
        expectedURL: URL,
        allowsInsecureHTTP: Bool
    ) -> Bool {
        guard
            let originalURL = urlTask.originalRequest?.url,
            let currentURL = urlTask.currentRequest?.url,
            originalURL == expectedURL,
            currentURL == expectedURL
        else {
            return false
        }
        do {
            try NetworkURLAdmission.validate(
                expectedURL,
                policy: .http(allowsInsecure: allowsInsecureHTTP)
            )
            return true
        } catch {
            return false
        }
    }
}


/// Typed failure for a finished attempt whose HTTP status is outside the
/// configured acceptable set. `code` is the HTTP status code itself, so the
/// classification survives the value projection carried by
/// ``DownloadError/networkError(_:)``.
package enum DownloadHTTPStatusFailure {
    package static let domain = "InnoNetworkDownload.HTTPStatus"
    /// Successful responses, including the 206 a resumed transfer returns.
    package static let defaultAcceptableStatusCodes = Set(200..<300)

    package static func make(statusCode: Int, url: URL?) -> SendableUnderlyingError {
        let target = NetworkError.diagnosticURLString(for: url)
        return SendableUnderlyingError(
            domain: domain,
            code: statusCode,
            message: "Download from \(target) finished with unacceptable HTTP status \(statusCode)."
        )
    }

    package static func statusCode(from error: SendableUnderlyingError) -> Int? {
        guard error.domain == domain else { return nil }
        return error.code
    }

    /// Statuses another attempt can clear. Every other unacceptable status
    /// is deterministic for the same request and fails the task at once.
    ///
    /// - `408`, `429`, `500...599`: request timeout, throttling, and
    ///   server-side failures.
    /// - `416`: only a range request can be answered this way, and only an
    ///   attempt rebuilt from resume data sends one. The status failure
    ///   carries no resume data, so the retry restarts from the source URL
    ///   instead of turning an unusable resume point into a terminal error.
    package static func isRetryable(statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 416, 429, 500...599:
            return true
        default:
            return false
        }
    }
}


package final class DownloadSessionDelegateCallbacks: Sendable {
    package typealias ProgressHandler = @Sendable (Int, Int64, Int64, Int64) -> Void
    /// The trailing `Data?` is the resume data Foundation attached to a
    /// failed attempt, when it produced any.
    package typealias CompletionHandler =
        @Sendable (Int, String?, URL?, URL?, DownloadCompletionPayload?, SendableUnderlyingError?, Data?) -> Void
    package typealias BackgroundEventsFinishedHandler =
        @Sendable ((@Sendable () -> Void)?) -> Void
    package typealias InvalidationHandler = @Sendable (SendableUnderlyingError?) -> Void

    private enum PendingLifecycleEvent {
        case completion(Int, String?, URL?, URL?, DownloadCompletionPayload?, SendableUnderlyingError?, Data?)
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
                    let error,
                    let resumeData
                ):
                    onCompletion(
                        taskIdentifier,
                        taskDescription,
                        originalRequestURL,
                        currentRequestURL,
                        payload,
                        error,
                        resumeData
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
                guard case .completion(_, _, _, _, let payload, _, _) = event else { return nil }
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
        error: SendableUnderlyingError?,
        resumeData: Data? = nil
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
                        error,
                        resumeData
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
            error,
            resumeData
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
        error: SendableUnderlyingError?,
        resumeData: Data? = nil
    ) {
        handleCompletion(
            taskIdentifier: taskIdentifier,
            taskDescription: taskDescription,
            originalRequestURL: originalRequestURL,
            currentRequestURL: currentRequestURL,
            payload: location.map(DownloadCompletionPayload.legacy),
            error: error,
            resumeData: resumeData
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
