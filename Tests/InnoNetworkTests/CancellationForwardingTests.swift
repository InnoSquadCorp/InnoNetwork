import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

/// Counts the runs of one step and ends its stream once nothing holds the
/// step any more. Only the step holds the probe, so the end of the stream
/// means the task that held the step has finished. A test waits for that end,
/// not for a quiet period, before it asserts that the step never ran.
private final class StepProbe: Sendable {
    private let runs: AsyncStream<Void>.Continuation

    init(_ runs: AsyncStream<Void>.Continuation) {
        self.runs = runs
    }

    func recordRun() {
        runs.yield()
    }

    deinit {
        runs.finish()
    }
}

/// Cancels the task that reads the monotonic time for the `cancelOnRead`-th
/// time, so a test can land a cancellation at one exact point in the code
/// under test. Sleeping and wall-clock time come from a ``TestClock``.
private final class CancellingClock: InnoNetworkClock {
    private let base = TestClock()
    private let cancelOnRead: Int
    private let reads = OSAllocatedUnfairLock(initialState: 0)

    init(cancelOnRead: Int) {
        self.cancelOnRead = cancelOnRead
    }

    func sleep(for duration: Duration) async throws {
        try await base.sleep(for: duration)
    }

    func now() -> Date {
        base.now()
    }

    func monotonicNow() -> Duration {
        let read = reads.withLock { reads -> Int in
            reads += 1
            return reads
        }
        if read == cancelOnRead {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return base.monotonicNow()
    }
}

private func makeStep(
    recordingRunsIn runs: AsyncStream<Void>.Continuation
) -> @Sendable () async throws -> Int {
    let probe = StepProbe(runs)
    return {
        probe.recordRun()
        return 1
    }
}

private func makeRequest(
    recordingRunsIn runs: AsyncStream<Void>.Continuation
) -> @Sendable (CancellationTag) async throws(NetworkError) -> Int {
    let probe = StepProbe(runs)
    return { _ in
        probe.recordRun()
        return 1
    }
}

/// Counts a step's runs until its probe is gone.
private func runCount(of runs: AsyncStream<Void>) async -> Int {
    var count = 0
    for await _ in runs {
        count += 1
    }
    return count
}

@Suite("Cancellation forwarding", .timeLimit(.minutes(1)))
struct CancellationForwardingTests {
    @Test("A timed streaming step cancelled before its task can be reached never starts")
    func cancelledTimedStreamingStepNeverStarts() async throws {
        let (runs, recordRun) = AsyncStream<Void>.makeStream()
        let executor = StreamingExecutor(session: MockURLSession(), eventHub: NetworkEventHub())
        // Read 1 is the step's start time, taken before the step's task exists.
        let clock = CancellingClock(cancelOnRead: 1)

        let caller = Task {
            try await executor.withStreamingTimeout(
                phase: .total,
                phaseBudget: nil,
                totalBudget: .seconds(60),
                logicalStart: .zero,
                clock: clock,
                operation: makeStep(recordingRunsIn: recordRun)
            )
        }

        await #expect(throws: CancellationError.self) {
            try await caller.value
        }
        #expect(await runCount(of: runs) == 0)
    }

    @Test("An operation cancelled before its request task can be reached never starts the request")
    func cancelledOperationNeverStartsRequest() async throws {
        let (runs, recordRun) = AsyncStream<Void>.makeStream()
        // Read 1 starts the deadline budget in start(...). Read 2 is the expiry
        // check inside the operation task, after its cancellation check and
        // before the request task exists.
        let clock = CancellingClock(cancelOnRead: 2)

        let error = try #require(await operationError(clock: clock, recordingRunsIn: recordRun))

        #expect(NetworkError.isCancellation(error))
        #expect(await runCount(of: runs) == 0)
    }

    /// Starts an operation, returns its error, and lets go of the handle, so
    /// only the operation's own tasks still hold the request.
    private func operationError(
        clock: some InnoNetworkClock,
        recordingRunsIn runs: AsyncStream<Void>.Continuation
    ) async -> NetworkError? {
        let operation = NetworkOperationRunner.start(
            method: .get,
            authentication: .anonymous,
            replaySafety: .methodDefault,
            deadline: NetworkOperationDeadline(after: .seconds(60)),
            deadlineClock: clock,
            execute: makeRequest(recordingRunsIn: runs)
        )
        do {
            _ = try await operation.value()
            return nil
        } catch {
            return error
        }
    }
}
