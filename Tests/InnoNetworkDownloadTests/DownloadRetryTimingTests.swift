import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkDownload

/// Deterministic timing tests for `DownloadFailureCoordinator`. Drives the
/// coordinator directly (no URLSession / no DownloadManager) so the retry
/// delay path is exercised against a virtual-time `TestClock` instead of
/// `Task.sleep` wall-clock. Complements the integration-oriented
/// `DownloadRetryTests` suite, which keeps `retryDelay: 0` to avoid real
/// sleeps.
@Suite("Download Retry Timing Tests")
struct DownloadRetryTimingTests {

    @Test("retryDelay > 0 suspends on the injected clock until advance fires")
    func retryDelayRespectsInjectedClock() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 2.0,
            sessionIdentifier: "test.retry-timing.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        let restartCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "connection lost"
                ),
                restart: { _ in
                    restartCounter.withLock { $0 += 1 }
                }
            )
        }

        // Coordinator bumps retry counters synchronously and then enqueues a
        // single waiter on the virtual clock.
        #expect(await clock.waitForWaiters(count: 1))
        #expect(restartCounter.withLock { $0 } == 0)
        #expect(await task.retryCount == 1)
        #expect(await task.totalRetryCount == 1)

        // Until advance, restart must not have fired.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(restartCounter.withLock { $0 } == 0)

        // Advance past the retryDelay -> waiter resumes -> restart fires.
        clock.advance(by: .seconds(2))
        await handleTask.value
        #expect(restartCounter.withLock { $0 } == 1)
    }

    @Test("retryDelay == 0 skips the clock entirely")
    func zeroDelayRetryFiresImmediately() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 0,
            sessionIdentifier: "test.retry-zero.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        let restartCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

        await coordinator.handleError(
            task: task,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue,
                message: "net lost"
            ),
            restart: { _ in
                restartCounter.withLock { $0 += 1 }
            }
        )

        #expect(clock.enqueuedCount == 0)
        #expect(restartCounter.withLock { $0 } == 1)
        #expect(await task.retryCount == 1)
    }

    @Test("Deterministic filesystem errors fail with the original filesystem reason")
    func deterministicFilesystemErrorFailsWithFilesystemReason() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 0,
            sessionIdentifier: "test.retry-filesystem.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )
        await task.restoreState(.downloading)

        let restarted = OSAllocatedUnfairLock<Bool>(initialState: false)
        let filesystemError = SendableUnderlyingError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileWriteNoPermission.rawValue,
            message: "permission denied"
        )

        await coordinator.handleError(
            task: task,
            error: filesystemError,
            restart: { _ in
                restarted.withLock { $0 = true }
            }
        )

        #expect(restarted.withLock { $0 } == false)
        #expect(await task.state == .failed)
        let actualError = await task.error
        guard case .fileSystemError(let underlying)? = actualError else {
            Issue.record("Expected fileSystemError, got \(String(describing: actualError))")
            return
        }
        #expect(underlying.domain == filesystemError.domain)
        #expect(underlying.code == filesystemError.code)
    }

    @Test("Cancelled task skips restart after clock advance")
    func cancelledTaskSuppressesRestartAfterDelay() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 1.0,
            sessionIdentifier: "test.retry-cancel.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        let restartCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "net lost"
                ),
                restart: { _ in
                    restartCounter.withLock { $0 += 1 }
                }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        await task.updateState(.cancelled)
        clock.advance(by: .seconds(1))

        await handleTask.value
        #expect(restartCounter.withLock { $0 } == 0)
    }

    @Test("Cancelling the retry task while sleeping suppresses restart")
    func cancelledRetryTaskDoesNotRestart() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 1.0,
            sessionIdentifier: "test.retry-task-cancel.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        let restartCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "cancelled while sleeping"
                ),
                restart: { _ in
                    restartCounter.withLock { $0 += 1 }
                }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        handleTask.cancel()

        await handleTask.value
        #expect(clock.waiterCount == 0)
        #expect(restartCounter.withLock { $0 } == 0)
    }

    @Test("Exponential backoff disabled (default) reuses the fixed retryDelay on every cycle")
    func exponentialBackoffDisabledUsesFixedDelay() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 2.0,
            exponentialBackoff: false,
            sessionIdentifier: "test.retry-exp-off.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )
        // Pre-inflate the retry counter so the second cycle would use
        // exponent 2 if exp backoff were active. Since it's disabled we
        // must see the plain 2.0s delay.
        _ = await task.incrementRetryCount()

        let restartCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "net lost"
                ),
                restart: { _ in
                    restartCounter.withLock { $0 += 1 }
                }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        // Half the fixed delay — must still be pending.
        clock.advance(by: .seconds(1))
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(restartCounter.withLock { $0 } == 0)
        // Cross the remaining slack — delay is exactly 2.0s.
        clock.advance(by: .seconds(1.1))
        await handleTask.value
        #expect(restartCounter.withLock { $0 } == 1)
    }

    @Test("Exponential backoff enabled doubles the delay each retry cycle")
    func exponentialBackoffEnabledDoublesDelay() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 5,
            maxTotalRetries: 5,
            retryDelay: 1.0,
            exponentialBackoff: true,
            retryJitterRatio: 0.0,
            maxRetryDelay: 0,
            sessionIdentifier: "test.retry-exp-on.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        // retryCount=1 → delay = 1 * 2^0 = 1s
        // retryCount=2 → delay = 1 * 2^1 = 2s
        // retryCount=3 → delay = 1 * 2^2 = 4s
        let expected: [TimeInterval] = [1, 2, 4]
        for (index, seconds) in expected.enumerated() {
            // Align the task's retryCount to what the coordinator will see
            // after its `incrementRetryCount` inside this cycle.
            while await task.retryCount < index {
                _ = await task.incrementRetryCount()
            }

            let restarted = OSAllocatedUnfairLock<Bool>(initialState: false)
            let handleTask = Task {
                await coordinator.handleError(
                    task: task,
                    error: SendableUnderlyingError(
                        domain: NSURLErrorDomain,
                        code: URLError.networkConnectionLost.rawValue,
                        message: "cycle-\(index)"
                    ),
                    restart: { _ in
                        restarted.withLock { $0 = true }
                    }
                )
            }

            #expect(await clock.waitForWaiters(count: 1))
            clock.advance(by: .seconds(seconds))
            await handleTask.value
            #expect(
                restarted.withLock { $0 },
                "cycle \(index): expected delay \(seconds)s to unblock restart"
            )
        }
    }

    @Test("maxRetryDelay caps the exponential backoff delay")
    func exponentialBackoffCapsAtMaxRetryDelay() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 20,
            maxTotalRetries: 20,
            retryDelay: 1.0,
            exponentialBackoff: true,
            retryJitterRatio: 0.0,
            maxRetryDelay: 5.0,
            sessionIdentifier: "test.retry-cap.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )
        // retryCount=10 → unclamped = 1 * 2^9 = 512s. Cap pins it at 5s.
        for _ in 0..<9 {
            _ = await task.incrementRetryCount()
        }

        let restarted = OSAllocatedUnfairLock<Bool>(initialState: false)
        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "cap"
                ),
                restart: { _ in
                    restarted.withLock { $0 = true }
                }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(5.001))
        await handleTask.value
        #expect(restarted.withLock { $0 })
    }

    @Test("maxRetryDelay <= 0 disables the cap")
    func maxRetryDelayZeroDisablesCap() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 10,
            maxTotalRetries: 10,
            retryDelay: 2.0,
            exponentialBackoff: true,
            retryJitterRatio: 0.0,
            maxRetryDelay: 0,
            sessionIdentifier: "test.retry-uncap.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )
        // retryCount=3 → delay = 2 * 2^2 = 8s. 5s advance leaves the waiter
        // pending — cap is disabled so there is no clamp.
        for _ in 0..<2 {
            _ = await task.incrementRetryCount()
        }

        let restarted = OSAllocatedUnfairLock<Bool>(initialState: false)
        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "uncap"
                ),
                restart: { _ in
                    restarted.withLock { $0 = true }
                }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(5))
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(restarted.withLock { $0 } == false, "5s advance should not unblock an 8s unclamped delay")
        clock.advance(by: .seconds(4))
        await handleTask.value
        #expect(restarted.withLock { $0 })
    }

    @Test("Huge retry counts stay finite when maxRetryDelay caps the backoff")
    func hugeRetryCountRemainsFiniteWhenCapped() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: Int.max,
            maxTotalRetries: Int.max,
            retryDelay: 1.0,
            exponentialBackoff: true,
            retryJitterRatio: 0.0,
            maxRetryDelay: 5.0,
            sessionIdentifier: "test.retry-huge-capped.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        await task.setRetryCount(Int.max - 2)

        let restarted = OSAllocatedUnfairLock<Bool>(initialState: false)
        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "huge-capped"
                ),
                restart: { _ in
                    restarted.withLock { $0 = true }
                }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(5.001))
        await handleTask.value
        #expect(restarted.withLock { $0 })
    }

    @Test("Huge retry counts still enqueue a finite wait when the user-facing cap is disabled")
    func hugeRetryCountWithoutUserCapStillEnqueuesFiniteWait() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: Int.max,
            maxTotalRetries: Int.max,
            retryDelay: 1.0,
            exponentialBackoff: true,
            retryJitterRatio: 0.0,
            maxRetryDelay: 0,
            sessionIdentifier: "test.retry-huge-uncapped.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        await task.setRetryCount(Int.max - 2)

        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "huge-uncapped"
                ),
                restart: { _ in }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        await task.updateState(.cancelled)
        handleTask.cancel()
        await handleTask.value
    }
}


@Suite("Large restored download timing", .timeLimit(.minutes(1)))
struct LargeRestoredDownloadTimingTests {
    @Test(arguments: [Double(Int64.max), 1e308])
    @MainActor func finiteRestoredDeadlineDoesNotRestartAfterSlice(seconds: Double) async {
        let clock = TestClock()
        let (coordinator, task) = await makeCoordinator(configuration: .advanced(), clock: clock)
        await task.restoreState(.downloading)
        let restarts = OSAllocatedUnfairLock(initialState: 0)
        let retry = DownloadRestoredRetry(
            task: task,
            plan: .backoff(retryNotBefore: clock.now().addingTimeInterval(seconds)),
            waitingLifecycle: await task.lifecycleSnapshot()
        )
        let job = Task {
            await coordinator.resumePersistedRetry(
                retry,
                restart: { _ in restarts.withLock { $0 += 1 } })
        }
        await withTaskCancellationHandler {
            #expect(await clock.waitForEnqueuedCount(atLeast: 1))
            clock.advance(by: SchedulingTime.maximumSleepSlice)
            #expect(await clock.waitForEnqueuedCount(atLeast: 2))
            #expect(restarts.withLock { $0 } == 0)
            job.cancel()
            await job.value
            #expect(clock.waiterCount == 0)
            #expect(restarts.withLock { $0 } == 0)
        } onCancel: {
            job.cancel()
        }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    @MainActor func invalidRestoredDeadlineHasTerminalFailure(seconds: Double) async {
        let clock = TestClock()
        let (coordinator, task) = await makeCoordinator(configuration: .advanced(), clock: clock)
        await task.restoreState(.downloading)
        let restarts = OSAllocatedUnfairLock(initialState: 0)
        await coordinator.resumePersistedRetry(
            DownloadRestoredRetry(
                task: task,
                plan: .backoff(retryNotBefore: Date(timeIntervalSince1970: seconds)),
                waitingLifecycle: await task.lifecycleSnapshot()
            ),
            restart: { _ in restarts.withLock { $0 += 1 } })
        #expect(await task.state == .failed)
        #expect(restarts.withLock { $0 } == 0)
        #expect(clock.waiterCount == 0)
        guard case .fileSystemError(let error) = await task.error else {
            Issue.record("Expected restoration failure")
            return
        }
        #expect(error.domain == "InnoNetwork.DownloadRestoration")
    }
}

@Suite("Restored retry claim", .timeLimit(.minutes(1)))
struct RestoredRetryClaimTests {
    @Test("A restored retry leaves alone a task paused and resumed before its job starts")
    func restoredRetryYieldsToPauseAndResumeBeforeItsJobStarts() async {
        let clock = TestClock()
        let (coordinator, task) = await makeCoordinator(configuration: .advanced(), clock: clock)
        await task.restoreState(.downloading)
        let waitingLifecycle = await task.lifecycleSnapshot()
        let retry = DownloadRestoredRetry(
            task: task,
            plan: .backoff(retryNotBefore: clock.now().addingTimeInterval(30)),
            waitingLifecycle: waitingLifecycle
        )

        // Once restoration releases public commands, a pause and a resume
        // can both finish before the deferred retry job runs. The resumed
        // attempt is the caller's, not the restored retry's.
        #expect(await task.transitionToPausedRetainingResumeData(ifMatching: waitingLifecycle))
        let pausedLifecycle = await task.lifecycleSnapshot()
        let resumedLifecycle = await task.startNextAttempt(
            transitioningTo: .downloading,
            ifMatching: pausedLifecycle
        )
        #expect(resumedLifecycle != nil)

        let restarts = OSAllocatedUnfairLock(initialState: 0)
        let job = Task {
            await coordinator.resumePersistedRetry(
                retry,
                restart: { _ in restarts.withLock { $0 += 1 } })
        }
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(30))
        await job.value

        #expect(restarts.withLock { $0 } == 0)
        #expect(await task.lifecycleSnapshot() == resumedLifecycle)
    }

    /// A relaunched process without a network monitor has no change to wait
    /// for, so a restored retry that was waiting for one goes straight to
    /// rewriting its plan as a backoff.
    private static let withoutNetworkMonitor = DownloadConfiguration(
        maxRetryCount: 3,
        maxTotalRetries: 3,
        retryDelay: 0,
        retryJitterRatio: 0,
        sessionIdentifier: "test.restored-retry-claim.\(UUID().uuidString)",
        networkMonitor: nil,
        waitsForNetworkChanges: true
    )

    private static let waitingPlan = DownloadTaskPersistence.RetryPlan.waitingForNetwork(
        baseline: nil,
        deadline: Date(timeIntervalSince1970: 500)
    )

    @Test("A restored retry without a network monitor leaves alone a task a pause took before its job ran")
    func restoredNetworkWaitYieldsToPauseWithoutMonitor() async throws {
        let clock = TestClock()
        let (coordinator, task) = await makeCoordinator(configuration: Self.withoutNetworkMonitor, clock: clock)
        await task.restoreState(.downloading)
        let waitingLifecycle = await task.lifecycleSnapshot()
        #expect(
            try await coordinator.persistence.updateRetryState(
                id: task.id, retryCount: 1, totalRetryCount: 1, retryPlan: Self.waitingPlan)
        )
        // The pause has taken the task, and its durable `.paused` is still
        // to come.
        #expect(await task.transitionToPausedRetainingResumeData(ifMatching: waitingLifecycle))

        let restarts = OSAllocatedUnfairLock(initialState: 0)
        await coordinator.resumePersistedRetry(
            DownloadRestoredRetry(task: task, plan: Self.waitingPlan, waitingLifecycle: waitingLifecycle),
            restart: { _ in restarts.withLock { $0 += 1 } })

        let record = await coordinator.persistence.record(forID: task.id)
        #expect(record?.lifecycle == .retryPending)
        #expect(record?.retryPlan == Self.waitingPlan)
        #expect(restarts.withLock { $0 } == 0)
    }

    @Test("A restored retry without a network monitor keeps the record of an attempt resumed before its job ran")
    func restoredNetworkWaitKeepsResumedRecordWithoutMonitor() async throws {
        let clock = TestClock()
        let (coordinator, task) = await makeCoordinator(configuration: Self.withoutNetworkMonitor, clock: clock)
        await task.restoreState(.downloading)
        let waitingLifecycle = await task.lifecycleSnapshot()
        #expect(
            try await coordinator.persistence.updateRetryState(
                id: task.id, retryCount: 1, totalRetryCount: 1, retryPlan: Self.waitingPlan)
        )
        // A pause and a resume finished first: the resumed attempt is running
        // and its record is `.active`.
        #expect(await task.transitionToPausedRetainingResumeData(ifMatching: waitingLifecycle))
        #expect(
            try await coordinator.persistence.transitionResumeState(
                id: task.id, from: .retryPending, to: .paused, resumeData: nil)
        )
        let pausedLifecycle = await task.lifecycleSnapshot()
        #expect(await task.startNextAttempt(transitioningTo: .downloading, ifMatching: pausedLifecycle) != nil)
        #expect(
            try await coordinator.persistence.transitionResumeState(
                id: task.id, from: .paused, to: .active, resumeData: nil)
        )

        let restarts = OSAllocatedUnfairLock(initialState: 0)
        await coordinator.resumePersistedRetry(
            DownloadRestoredRetry(task: task, plan: Self.waitingPlan, waitingLifecycle: waitingLifecycle),
            restart: { _ in restarts.withLock { $0 += 1 } })

        // A `.retryPending` record would refuse the resumed attempt's commit.
        #expect(await coordinator.persistence.record(forID: task.id)?.lifecycle == .active)
        #expect(restarts.withLock { $0 } == 0)
    }

    @Test("A waiting retry leaves alone a newer retry's marker even when both plans have the same contents")
    func waitingRetryLeavesNewerMarkerWithSameContents() async throws {
        let clock = TestClock()
        let (coordinator, task, store) = await makeCoordinatorWithStore(
            configuration: Self.withoutNetworkMonitor,
            clock: clock
        )
        let persistence = coordinator.persistence
        await task.restoreState(.downloading)
        let waitingLifecycle = await task.lifecycleSnapshot()
        // Without a deadline or a baseline, two retries make plans with the
        // same contents. Only their identity tells them apart.
        let ownPlan = DownloadTaskPersistence.RetryPlan.waitingForNetwork(baseline: nil, deadline: nil)
        let newerPlan = DownloadTaskPersistence.RetryPlan.waitingForNetwork(baseline: nil, deadline: nil)
        #expect(ownPlan != newerPlan)
        #expect(
            try await persistence.updateRetryState(
                id: task.id, retryCount: 1, totalRetryCount: 1, retryPlan: ownPlan)
        )
        // After the retry's lifecycle check and before its write, a pause and
        // a resume start a newer attempt, which fails into a retry of its own.
        await store.setBeforeRetryPlanRewrite { id in
            guard await task.transitionToPausedRetainingResumeData(ifMatching: waitingLifecycle) else { return }
            _ = try? await persistence.transitionResumeState(id: id, from: .retryPending, to: .paused, resumeData: nil)
            let pausedLifecycle = await task.lifecycleSnapshot()
            _ = await task.startNextAttempt(transitioningTo: .downloading, ifMatching: pausedLifecycle)
            _ = try? await persistence.transitionResumeState(id: id, from: .paused, to: .active, resumeData: nil)
            _ = try? await persistence.updateRetryState(
                id: id, retryCount: 1, totalRetryCount: 2, retryPlan: newerPlan)
        }

        let restarts = OSAllocatedUnfairLock(initialState: 0)
        await coordinator.resumePersistedRetry(
            DownloadRestoredRetry(task: task, plan: ownPlan, waitingLifecycle: waitingLifecycle),
            restart: { _ in restarts.withLock { $0 += 1 } })

        // The newer retry's marker is untouched, so that retry can still
        // rewrite it when its own wait ends instead of stopping short.
        #expect(await persistence.record(forID: task.id)?.retryPlan == newerPlan)
        #expect(restarts.withLock { $0 } == 0)
        #expect(
            try await persistence.rewriteRetryPlan(
                id: task.id,
                replacing: newerPlan,
                with: .backoff(retryNotBefore: clock.now()),
                retryCount: 1,
                totalRetryCount: 2,
                resumeData: nil
            )
        )
    }
}

// MARK: - Helpers

@MainActor
private func makeCoordinator(
    configuration: DownloadConfiguration,
    clock: TestClock
) async -> (DownloadFailureCoordinator, DownloadTask) {
    let (coordinator, task, _) = await makeCoordinatorWithStore(configuration: configuration, clock: clock)
    return (coordinator, task)
}

private func makeCoordinatorWithStore(
    configuration: DownloadConfiguration,
    clock: TestClock
) async -> (DownloadFailureCoordinator, DownloadTask, InMemoryDownloadTaskStore) {
    let runtimeRegistry = DownloadRuntimeRegistry()
    let task = DownloadTask(
        url: URL(string: "https://example.invalid/test.bin")!,
        destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).bin")
    )
    let store = InMemoryDownloadTaskStore(
        seed: [
            DownloadTaskPersistence.Record(
                id: task.id,
                url: task.url,
                destinationURL: task.destinationURL,
                lifecycle: .active
            )
        ]
    )
    let persistence = DownloadTaskPersistence(store: store)
    let eventHub = TaskEventHub<DownloadEvent>(
        policy: configuration.eventDeliveryPolicy,
        metricsReporter: configuration.eventMetricsReporter,
        hubKind: .downloadTask
    )
    let coordinator = DownloadFailureCoordinator(
        configuration: configuration,
        runtimeRegistry: runtimeRegistry,
        persistence: persistence,
        eventHub: eventHub,
        clock: clock
    )
    await runtimeRegistry.add(task)
    return (coordinator, task, store)
}


// `InMemoryDownloadTaskStore` lives in its own file now so the pause/resume,
// restore, retry, and retry-timing suites can all seed persistence from the
// same implementation.
