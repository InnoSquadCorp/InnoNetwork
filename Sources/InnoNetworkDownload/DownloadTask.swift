import Foundation
import OSLog

public actor DownloadTask: Identifiable {
    public nonisolated let id: String
    public nonisolated let url: URL
    public nonisolated let destinationURL: URL

    private static let logger = Logger(subsystem: "innosquad.network.download", category: "DownloadTask")

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

    public init(url: URL, destinationURL: URL, id: String = UUID().uuidString, resumeData: Data? = nil) {
        self.id = id
        self.url = url
        self.destinationURL = destinationURL
        self._resumeData = resumeData
    }

    /// Apply a new state, enforcing the documented transition table from
    /// ``DownloadState/canTransition(to:)``.
    ///
    /// Illegal transitions trigger an `assertionFailure` in DEBUG builds so
    /// that bugs surface during development. In release builds the attempt is
    /// logged as an OSLog `.fault` and the assignment is **rejected** — the
    /// existing state is preserved so a misbehaving caller cannot drive the
    /// task into an inconsistent state. For non-progressive writes (restoring
    /// persisted state on app launch, or test-only state injection), use
    /// ``restoreState(_:)``.
    func updateState(_ newState: DownloadState) {
        let current = _state
        let reduction = DownloadLifecycleReducer.reduce(
            state: current,
            event: .transition(to: newState)
        )
        if reduction.effects.contains(.rejectIllegalTransition(from: current, to: newState)) {
            Self.logger.fault(
                "Illegal DownloadState transition: \(current.rawValue, privacy: .public) -> \(newState.rawValue, privacy: .public) for task \(self.id, privacy: .private(mask: .hash))"
            )
            assertionFailure("Illegal DownloadState transition: \(current) -> \(newState) for task \(self.id)")
            return
        }
        _state = reduction.state
    }

    /// Assign the task state without validating the transition.
    ///
    /// Reserved for state restoration (rebuilding actor state from persisted
    /// records or live `URLSession` task state on app relaunch) and for test
    /// state injection. Production lifecycle code should use
    /// ``updateState(_:)`` so unintended transitions are caught.
    func restoreState(_ newState: DownloadState) {
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
