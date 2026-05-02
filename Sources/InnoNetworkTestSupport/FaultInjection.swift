import Foundation
import InnoNetwork
import os

// Fault-injection helpers used by InnoNetwork's own tests to exercise
// non-cancellation failure paths in clocks, disk I/O, and POSIX advisory
// locking. These types are `package`-scoped so they remain confined to the
// InnoNetwork package and never leak into the public test-support API.

package final class ClockFailureInjector: InnoNetworkClock, @unchecked Sendable {

    package enum FailureMode: Sendable {
        case never
        case onCall(Int, Error)
        case always(Error)
    }

    private struct State {
        var callCount: Int = 0
        var mode: FailureMode = .never
    }

    private let inner: any InnoNetworkClock
    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())

    package init(wrapping inner: any InnoNetworkClock) {
        self.inner = inner
    }

    package func setFailureMode(_ mode: FailureMode) {
        stateLock.withLock { $0.mode = mode }
    }

    package var callCount: Int {
        stateLock.withLock { $0.callCount }
    }

    package func sleep(for duration: Duration) async throws {
        let action: FailureMode = stateLock.withLock { state in
            state.callCount += 1
            switch state.mode {
            case .onCall(let target, let error) where state.callCount == target:
                return .always(error)
            case .always(let error):
                return .always(error)
            default:
                return .never
            }
        }
        if case .always(let error) = action {
            throw error
        }
        try await inner.sleep(for: duration)
    }
}


package actor FsyncFailureInjector {

    package enum Mode: Sendable {
        case neverFail
        case failNext(Int)
        case failAlways
    }

    private var mode: Mode = .neverFail
    private(set) package var fsyncCallCount: Int = 0

    package init() {}

    package func setMode(_ mode: Mode) { self.mode = mode }

    /// Returns `true` if the simulated fsync should succeed; `false` if the
    /// caller should treat this as a failure. Production paths should branch
    /// on the return value so the same call site exercises both paths.
    package func performFsync() -> Bool {
        fsyncCallCount += 1
        switch mode {
        case .neverFail:
            return true
        case .failAlways:
            return false
        case .failNext(let remaining):
            if remaining <= 0 {
                mode = .neverFail
                return true
            }
            mode = .failNext(remaining - 1)
            return false
        }
    }
}


package actor FlockSimulator {

    package enum Outcome: Sendable {
        case acquired
        case wouldBlock
        case error(Int32)
    }

    private var lockHeld: Bool = false
    private var nextOutcomes: [Outcome] = []

    package init() {}

    package func enqueue(_ outcomes: [Outcome]) {
        nextOutcomes.append(contentsOf: outcomes)
    }

    package func tryAcquire() -> Outcome {
        if !nextOutcomes.isEmpty {
            let outcome = nextOutcomes.removeFirst()
            if case .acquired = outcome { lockHeld = true }
            return outcome
        }
        if lockHeld { return .wouldBlock }
        lockHeld = true
        return .acquired
    }

    package func release() { lockHeld = false }
    package var isLocked: Bool { lockHeld }
}


/// FileHandle-shaped wrapper that fails write/close on demand. Tests that
/// exercise persistence and multipart streaming pass this through the same
/// closure-based seam as a real `FileHandle` to drive failure paths without
/// relying on disk-level fault injection (read-only mounts, quota, etc.).
package final class FailingFileHandle: @unchecked Sendable {

    package struct Plan: Sendable {
        package var failWriteAt: Int?
        package var failCloseWith: Error?
        package var underlying: URL?

        package init(failWriteAt: Int? = nil, failCloseWith: Error? = nil, underlying: URL? = nil) {
            self.failWriteAt = failWriteAt
            self.failCloseWith = failCloseWith
            self.underlying = underlying
        }
    }

    private struct State {
        var plan: Plan
        var writeCount: Int = 0
        var written: Data = Data()
        var closed: Bool = false
    }

    private let stateLock: OSAllocatedUnfairLock<State>

    package init(plan: Plan = Plan()) {
        self.stateLock = OSAllocatedUnfairLock(initialState: State(plan: plan))
    }

    package var writeCount: Int { stateLock.withLock { $0.writeCount } }
    package var bytesWritten: Data { stateLock.withLock { $0.written } }
    package var isClosed: Bool { stateLock.withLock { $0.closed } }

    package func write(contentsOf data: Data) throws {
        let shouldFail: Bool = stateLock.withLock { state in
            state.writeCount += 1
            if let target = state.plan.failWriteAt, state.writeCount == target {
                return true
            }
            state.written.append(data)
            return false
        }
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    package func close() throws {
        let error: Error? = stateLock.withLock { state in
            state.closed = true
            return state.plan.failCloseWith
        }
        if let error { throw error }
    }
}


/// URLSession-shaped wrapper that records every request and counts how many
/// times its `data(for:)` continuation fires. Tests use the counter to assert
/// that a `DownloadManager.shutdown()` (or analogous teardown) actually
/// short-circuits in-flight callbacks — distinguishing "task observed
/// cancellation" from "task observed no callback at all".
package final class CountingURLSession: URLSessionProtocol, @unchecked Sendable {

    private struct State {
        var captured: [URLRequest] = []
        var dataCallCount: Int = 0
        var completionCount: Int = 0
        var nextResult: Result<(Data, URLResponse), Error>
        var artificialDelay: Duration = .zero
    }

    private let stateLock: OSAllocatedUnfairLock<State>

    package init(initial: Result<(Data, URLResponse), Error> = .success((Data(), URLResponse()))) {
        self.stateLock = OSAllocatedUnfairLock(initialState: State(nextResult: initial))
    }

    package var capturedRequests: [URLRequest] { stateLock.withLock { $0.captured } }
    package var dataCallCount: Int { stateLock.withLock { $0.dataCallCount } }
    package var completionCount: Int { stateLock.withLock { $0.completionCount } }

    package func setNextResult(_ result: Result<(Data, URLResponse), Error>) {
        stateLock.withLock { $0.nextResult = result }
    }

    package func setArtificialDelay(_ duration: Duration) {
        stateLock.withLock { $0.artificialDelay = duration }
    }

    package func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (delay, result): (Duration, Result<(Data, URLResponse), Error>) = stateLock.withLock { state in
            state.dataCallCount += 1
            state.captured.append(request)
            return (state.artificialDelay, state.nextResult)
        }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        stateLock.withLock { $0.completionCount += 1 }
        return try result.get()
    }
}
