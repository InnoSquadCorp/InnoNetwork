import Foundation


public enum DownloadState: String, Sendable {
    case idle
    case waiting
    case downloading
    case paused
    case completed
    case failed
    case cancelled
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
    case networkError(Error)
    case fileSystemError(Error)
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
            return "Network error: \(error.localizedDescription)"
        case .fileSystemError(let error):
            return "File system error: \(error.localizedDescription)"
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
