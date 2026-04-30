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

public extension DownloadState {
    /// Returns all documented next states from the current lifecycle point.
    var nextStates: Set<Self> {
        switch self {
        case .idle:
            [.waiting, .downloading, .cancelled]
        case .waiting:
            [.downloading, .failed, .cancelled]
        case .downloading:
            [.paused, .completed, .failed, .cancelled, .waiting]
        case .paused:
            // `.waiting` covers the resume-without-resume-data path, where
            // the task is restarted from scratch and re-registers with
            // persistence before reaching `.downloading`.
            [.downloading, .waiting, .cancelled]
        case .completed, .cancelled:
            []
        case .failed:
            [.idle]
        }
    }

    /// Whether the state ends the download lifecycle.
    var isTerminal: Bool {
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
    func canTransition(to next: Self) -> Bool {
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
    case maxRetriesExceeded
    case noResumeData
    case unknown
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
        case .maxRetriesExceeded:
            return "Maximum retry attempts exceeded"
        case .noResumeData:
            return "No resume data available"
        case .unknown:
            return "Unknown error occurred"
        }
    }
}
