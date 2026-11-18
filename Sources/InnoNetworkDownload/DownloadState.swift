import Foundation
import InnoNetwork

public enum DownloadState: String, Sendable {
    case idle
    case waiting
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

extension DownloadState {
    /// Returns all documented next states from the current lifecycle point.
    package var nextStates: Set<Self> {
        switch self {
        case .idle:
            [.waiting, .downloading, .failed, .cancelled]
        case .waiting:
            [.downloading, .failed, .cancelled]
        case .downloading:
            [.paused, .completed, .failed, .cancelled, .waiting]
        case .paused:
            // `.waiting` covers the resume-without-resume-data path, where
            // the task is restarted from scratch and re-registers with
            // persistence before reaching `.downloading`. `.failed` covers
            // the resume-with-resume-data persistence-write failure that
            // marks the paused task as failed without rerunning it.
            [.downloading, .waiting, .failed, .cancelled]
        case .completed, .cancelled:
            []
        case .failed:
            [.idle]
        }
    }

    /// Whether the state ends the download lifecycle.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .idle, .waiting, .downloading, .paused:
            return false
        }
    }

    /// Documents the intended download lifecycle transitions.
    ///
    /// This is an invariant helper for session/task lifecycle modeling. It is
    /// not enforced by a generic state machine runtime.
    package func canTransition(to next: Self) -> Bool {
        next == self || nextStates.contains(next)
    }
}


public struct DownloadProgress: Sendable {
    public let bytesWritten: Int64
    public let totalBytesWritten: Int64
    public let totalBytesExpectedToWrite: Int64

    public var fractionCompleted: Double {
        guard totalBytesExpectedToWrite > 0 else { return 0 }
        return Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    public var percentCompleted: Int {
        Int(fractionCompleted * 100)
    }

    public static let zero = DownloadProgress(
        bytesWritten: 0,
        totalBytesWritten: 0,
        totalBytesExpectedToWrite: 0
    )
}


public enum DownloadError: Error, Sendable {
    case invalidURL(String)
    case networkError(SendableUnderlyingError)
    case fileSystemError(SendableUnderlyingError)
    case cancelled
    /// The retry budget is exhausted. `lastError` is the failure of the final
    /// attempt, so the caller can tell an offline device from a DNS failure,
    /// a TLS failure, or a server that kept answering `503`.
    case maxRetriesExceeded(lastError: SendableUnderlyingError)
    /// The server answered with an HTTP status outside the configured
    /// acceptable set and another attempt cannot change that answer, for
    /// example `403` for an expired signed URL or `404` for a missing object.
    /// Nothing is written to the destination. Statuses that another attempt
    /// can clear (`408`, `416`, `429`, `5xx`) are retried instead and end as
    /// ``maxRetriesExceeded(lastError:)`` when the budget runs out. A resumed
    /// attempt refused for its stale resume point, by a `416` or by the
    /// redirect target it continued at, restarts from the source URL at once
    /// without spending that budget.
    case unacceptableStatusCode(Int)
    case noResumeData
    case restorationMissingSystemTask
    case unknown
}

extension DownloadError {
    /// The HTTP status code behind this failure, when a status caused it:
    /// the code of ``unacceptableStatusCode(_:)``, or the status of the final
    /// attempt of ``maxRetriesExceeded(lastError:)``.
    public var httpStatusCode: Int? {
        switch self {
        case .unacceptableStatusCode(let statusCode):
            return statusCode
        case .maxRetriesExceeded(let lastError):
            return DownloadHTTPStatusFailure.statusCode(from: lastError)
        default:
            return nil
        }
    }
}

extension DownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .networkError(let error):
            return "Network error: \(error.message)"
        case .fileSystemError(let error):
            return "File system error: \(error.message)"
        case .cancelled:
            return "Download was cancelled"
        case .maxRetriesExceeded(let lastError):
            return "Maximum retry attempts exceeded. Last error: \(lastError.message)"
        case .unacceptableStatusCode(let statusCode):
            return "The server responded with HTTP status \(statusCode)"
        case .noResumeData:
            return "No resume data available"
        case .restorationMissingSystemTask:
            return "Persisted download no longer exists in the background URLSession"
        case .unknown:
            return "Unknown error occurred"
        }
    }
}
