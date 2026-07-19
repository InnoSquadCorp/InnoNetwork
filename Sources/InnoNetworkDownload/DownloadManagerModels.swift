import Foundation

enum DownloadPersistenceStateError: Error {
    case missingPausingRecord(String)
    case missingResumingRecord(String)
    case failedToFinalizeResumingRecord(String)
}

public enum DownloadEvent: Sendable {
    case progress(DownloadProgress)
    case stateChanged(DownloadState)
    case completed(URL)
    case failed(DownloadError)
}

public enum DownloadManagerError: Error, Sendable, Equatable {
    case duplicateSessionIdentifier(String)
}

extension DownloadManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateSessionIdentifier(let identifier):
            return
                "DownloadManager sessionIdentifier '\(identifier)' is already in use. Use a unique sessionIdentifier for multiple managers."
        }
    }
}

extension DownloadManager {
    // Internal so extension files in this module can pattern-match on the
    // payload when implementing the delegate-event consumer.
    enum DelegateEvent: Sendable {
        case progress(
            taskIdentifier: Int,
            bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        )
        case completion(
            taskIdentifier: Int,
            taskDescription: String?,
            originalRequestURL: URL?,
            currentRequestURL: URL?,
            payload: DownloadCompletionPayload?,
            error: SendableUnderlyingError?
        )
        case restorationBoundary
        case backgroundEventsFinished(completion: (@Sendable () -> Void)?)
    }
}
