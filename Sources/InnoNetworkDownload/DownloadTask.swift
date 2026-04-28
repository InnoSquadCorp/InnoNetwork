import Foundation

public actor DownloadTask: Identifiable {
    public nonisolated let id: String
    public nonisolated let url: URL
    public nonisolated let destinationURL: URL

    private var _state: DownloadState = .idle
    private var _progress: DownloadProgress = .zero
    private var _retryCount: Int = 0
    private var _totalRetryCount: Int = 0
    private var _resumeData: Data?
    private var _error: DownloadError?

    public var state: DownloadState { _state }
    public var progress: DownloadProgress { _progress }
    public var retryCount: Int { _retryCount }
    public var totalRetryCount: Int { _totalRetryCount }
    public var resumeData: Data? { _resumeData }
    public var error: DownloadError? { _error }

    public init(url: URL, destinationURL: URL, id: String = UUID().uuidString) {
        self.id = id
        self.url = url
        self.destinationURL = destinationURL
    }

    func updateState(_ newState: DownloadState) {
        _state = newState
    }

    func updateProgress(_ newProgress: DownloadProgress) {
        _progress = newProgress
    }

    func incrementRetryCount() -> Int {
        _retryCount += 1
        return _retryCount
    }

    func setRetryCount(_ retryCount: Int) {
        _retryCount = max(0, retryCount)
    }

    func incrementTotalRetryCount() -> Int {
        _totalRetryCount += 1
        return _totalRetryCount
    }

    func resetRetryCount() {
        _retryCount = 0
    }

    func setResumeData(_ data: Data?) {
        _resumeData = data
    }

    func setError(_ error: DownloadError?) {
        _error = error
    }

    func reset() {
        _state = .idle
        _progress = .zero
        _retryCount = 0
        _totalRetryCount = 0
        _error = nil
    }
}


extension DownloadTask: Hashable {
    public nonisolated static func == (lhs: DownloadTask, rhs: DownloadTask) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
