import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkDownload

/// `pause(_:)` issued while an automatic retry is waiting for backoff or a
/// network change. The logical task is still `.downloading` in that window
/// but owns no `URLSession` attempt, so the pause has nothing to cancel; it
/// must still take effect durably and stop the pending retry from restarting
/// the transfer.
@Suite("Download pause during retry wait", .serialized)
struct DownloadPauseDuringRetryWaitTests {

    @Test("Pause during retry backoff ends paused, outlives the backoff, and resume starts a new attempt")
    func pauseDuringBackoffTakesEffect() async throws {
        let clock = TestClock()
        let resumedStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 30,
            clock: clock,
            label: "pause-retry-backoff",
            prequeuedStubs: [resumedStub]
        )
        let states = RetryWaitStateRecorder()
        await harness.manager.setOnStateChangedHandler { _, state in
            await states.record(state)
        }
        let task = await harness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let events = RetryWaitStateRecorder()
        await harness.manager.addEventListener(for: task) { event in
            if case .stateChanged(let state) = event {
                await events.record(state)
            }
        }
        let failedIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })

        await harness.injectCompletion(taskIdentifier: failedIdentifier, error: retryWaitConnectionLost)

        // Reaching the virtual-clock sleeper proves the retry job persisted
        // its plan and is now suspended in backoff with no live attempt.
        #expect(await clock.waitForEnqueuedCount(atLeast: 1, timeout: 10.0))
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == nil)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .retryPending)
        #expect(await task.state == .downloading)

        await harness.manager.pause(task)

        #expect(await task.state == .paused)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .paused)
        // Observers learn about it through both delivery lanes, exactly as
        // they do for a pause that cancelled a live attempt.
        #expect(await states.waitUntilContains(.paused))
        #expect(await events.waitUntilContains(.paused))

        // Release the backoff and let the pending retry job run to its end.
        clock.advance(by: .seconds(30))
        await harness.manager.drainDeferredFailureTasks()

        #expect(await task.state == .paused)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .paused)
        #expect(harness.stubSession.createdTasks.count == 1)
        #expect(resumedStub.resumeCount == 0)
        #expect(await states.count(of: .waiting) == 1)

        await harness.manager.resume(task)

        let resumedIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                excluding: failedIdentifier,
                timeout: 10.0
            )
        )
        #expect(resumedIdentifier == resumedStub.taskIdentifier)
        #expect(await waitForResumeCount(resumedStub, atLeast: 1, timeout: 10.0))
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .active)
        #expect(harness.stubSession.createdTasks.count == 2)

        await harness.manager.shutdown()
    }

    @Test("Pause while a retry waits for a network change ends paused and the change does not restart it")
    func pauseDuringNetworkWaitTakesEffect() async throws {
        let monitor = GatedNetworkMonitor()
        let resumedStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 0,
            networkMonitor: monitor,
            waitsForNetworkChanges: true,
            networkChangeTimeout: nil,
            label: "pause-retry-network-wait",
            prequeuedStubs: [resumedStub]
        )
        let task = await harness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let failedIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })

        await harness.injectCompletion(taskIdentifier: failedIdentifier, error: retryWaitConnectionLost)

        #expect(await monitor.waitUntilWaiting())
        #expect(await harness.store.record(forID: task.id)?.retryPlan?.phase == .waitingForNetwork)

        await harness.manager.pause(task)

        #expect(await task.state == .paused)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .paused)

        // The network comes back. The pending retry must neither rewrite the
        // durable pause back to `retryPending` nor create a new attempt.
        await monitor.reportChange(NetworkSnapshot(status: .satisfied, interfaceTypes: [.cellular]))
        await harness.manager.drainDeferredFailureTasks()

        #expect(await task.state == .paused)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .paused)
        #expect(harness.stubSession.createdTasks.count == 1)
        #expect(resumedStub.resumeCount == 0)

        await harness.manager.shutdown()
    }

    @Test("A backoff that ends after pause and resume does not replace the resumed attempt")
    func staleBackoffDoesNotHijackResumedAttempt() async throws {
        let clock = TestClock()
        let resumedStub = StubDownloadURLTask()
        let hijackStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 30,
            clock: clock,
            label: "pause-retry-stale-backoff",
            prequeuedStubs: [resumedStub, hijackStub]
        )
        let states = RetryWaitStateRecorder()
        await harness.manager.setOnStateChangedHandler { _, state in
            await states.record(state)
        }
        let task = await harness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let failedIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
        await harness.injectCompletion(taskIdentifier: failedIdentifier, error: retryWaitConnectionLost)
        #expect(await clock.waitForEnqueuedCount(atLeast: 1, timeout: 10.0))

        await harness.manager.pause(task)
        await harness.manager.resume(task)

        let resumedIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                excluding: failedIdentifier,
                timeout: 10.0
            )
        )
        #expect(resumedIdentifier == resumedStub.taskIdentifier)
        #expect(await waitForResumeCount(resumedStub, atLeast: 1, timeout: 10.0))
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
        let waitingCallbacks = await states.count(of: .waiting)
        let resumedAttempt = await task.attempt

        // The original retry's backoff ends while the resumed attempt runs.
        clock.advance(by: .seconds(30))
        await harness.manager.drainDeferredFailureTasks()

        // The stale retry must not even claim the next attempt: that would
        // invalidate the lifecycle snapshot the live attempt runs under.
        #expect(await task.attempt == resumedAttempt)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == resumedStub.taskIdentifier)
        #expect(await task.state == .downloading)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .active)
        #expect(resumedStub.cancelCount == 0)
        #expect(hijackStub.resumeCount == 0)
        #expect(harness.stubSession.createdTasks.count == 2)
        #expect(await states.count(of: .waiting) == waitingCallbacks)

        await harness.manager.shutdown()
    }

    @Test("A network change that arrives after pause and resume does not reschedule the resumed attempt")
    func staleNetworkWaitDoesNotHijackResumedAttempt() async throws {
        let monitor = GatedNetworkMonitor()
        let resumedStub = StubDownloadURLTask()
        let hijackStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 0,
            networkMonitor: monitor,
            waitsForNetworkChanges: true,
            networkChangeTimeout: nil,
            label: "pause-retry-stale-network",
            prequeuedStubs: [resumedStub, hijackStub]
        )
        let task = await harness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let failedIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
        await harness.injectCompletion(taskIdentifier: failedIdentifier, error: retryWaitConnectionLost)
        #expect(await monitor.waitUntilWaiting())

        await harness.manager.pause(task)
        await harness.manager.resume(task)

        let resumedIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                excluding: failedIdentifier,
                timeout: 10.0
            )
        )
        #expect(resumedIdentifier == resumedStub.taskIdentifier)
        #expect(await waitForResumeCount(resumedStub, atLeast: 1, timeout: 10.0))
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .active)
        let resumedAttempt = await task.attempt
        let retryCountBeforeChange = await task.retryCount

        await monitor.reportChange(NetworkSnapshot(status: .satisfied, interfaceTypes: [.cellular]))
        await harness.manager.drainDeferredFailureTasks()

        // The stale retry must not turn the live attempt's record back into
        // a retry marker, reset its retry budget, or start a competing
        // attempt.
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .active)
        #expect(await task.attempt == resumedAttempt)
        #expect(await task.retryCount == retryCountBeforeChange)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == resumedStub.taskIdentifier)
        #expect(await task.state == .downloading)
        #expect(resumedStub.cancelCount == 0)
        #expect(hijackStub.resumeCount == 0)
        #expect(harness.stubSession.createdTasks.count == 2)

        await harness.manager.shutdown()
    }

    @Test("A pause taken during the retry wait is restored as paused after relaunch")
    func retryWaitPauseSurvivesRelaunch() async throws {
        let clock = TestClock()
        let firstHarness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 30,
            clock: clock,
            label: "pause-retry-relaunch-first"
        )
        let task = await firstHarness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let failedIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: firstHarness.manager, task: task, timeout: 10.0)
        )
        await firstHarness.injectCompletion(taskIdentifier: failedIdentifier, error: retryWaitConnectionLost)
        #expect(await clock.waitForEnqueuedCount(atLeast: 1, timeout: 10.0))

        await firstHarness.manager.pause(task)

        // The record a relaunched process would read from disk.
        let durablePause = try #require(await firstHarness.store.record(forID: task.id))
        #expect(durablePause.lifecycle == .paused)
        await firstHarness.manager.shutdown()

        let secondHarness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 30,
            clock: clock,
            label: "pause-retry-relaunch-second",
            prepopulatedRecords: [durablePause]
        )
        #expect(await secondHarness.manager.waitForRestoration())
        let restored = try #require(await secondHarness.manager.task(withId: task.id))

        #expect(await restored.state == .paused)
        // No retry is scheduled for a paused record, whatever plan it kept.
        clock.advance(by: .seconds(60))
        await secondHarness.manager.drainDeferredFailureTasks()
        #expect(secondHarness.stubSession.createdTasks.isEmpty)
        #expect(await restored.state == .paused)

        await secondHarness.manager.shutdown()
    }

    @Test("Without a durable retry marker an attempt-less downloading task still ignores pause")
    func pauseWithoutRetryMarkerStaysNoOp() async throws {
        let harness = try StubDownloadHarness(label: "pause-retry-no-marker")
        let task = await harness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
        // Same shape as a failure still being admitted: the attempt is
        // retired but the record does not schedule a retry yet.
        await harness.manager.runtimeRegistry.removeAttemptRuntime(taskIdentifier: identifier)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .active)

        await harness.manager.pause(task)

        #expect(await task.state == .downloading)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .active)

        await harness.manager.shutdown()
    }

    @Test("A retry admitted for an already paused task never claims the next attempt")
    func retryAdmittedForPausedTaskDoesNotRestart() async throws {
        // A second failure report for the retired attempt lands after the
        // pause is visible in memory but before its durable phase.
        let (coordinator, task, persistence) = await makeStatusFailureCoordinator(
            state: .paused,
            lifecycle: .retryPending
        )
        let restarts = OSAllocatedUnfairLock<Int>(initialState: 0)

        await coordinator.handleError(
            task: task,
            error: retryWaitConnectionLost,
            restart: { _ in restarts.withLock { $0 += 1 } }
        )

        #expect(restarts.withLock { $0 } == 0)
        #expect(await task.state == .paused)
        #expect(await task.attempt == 0)
        // The pause's own durable transition from the retry marker still applies.
        #expect(
            try await persistence.transitionResumeState(
                id: task.id,
                from: .retryPending,
                to: .paused,
                resumeData: nil
            )
        )
    }

    @Test("This failure's resume data is in place before its retry marker becomes durable")
    func resumeDataPrecedesDurableRetryMarker() async throws {
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/resume-order.bin")!,
            destinationURL: makeRetryWaitDestinationURL()
        )
        await task.restoreState(.downloading)
        // An earlier attempt left its own blob behind.
        await task.setResumeData(Data("earlier-attempt".utf8))
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
        // A pause that takes the waiting task the moment the marker is
        // durable persists whatever resume data the task holds right then.
        let seenByPause = OSAllocatedUnfairLock<Data?>(initialState: nil)
        await store.setAfterRetryMarkerWritten { _ in
            let held = await task.resumeData
            seenByPause.withLock { $0 = held }
        }
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 0,
            sessionIdentifier: makeDownloadTestSessionIdentifier("resume-order"),
            networkMonitor: nil
        )
        let coordinator = DownloadFailureCoordinator(
            configuration: configuration,
            runtimeRegistry: DownloadRuntimeRegistry(),
            persistence: DownloadTaskPersistence(store: store),
            eventHub: TaskEventHub<DownloadEvent>(
                policy: configuration.eventDeliveryPolicy,
                metricsReporter: configuration.eventMetricsReporter,
                hubKind: .downloadTask
            ),
            clock: TestClock()
        )
        let freshResumeData = Data("failed-attempt".utf8)

        await coordinator.handleError(
            task: task,
            error: retryWaitConnectionLost,
            resumeData: freshResumeData,
            restart: { _ in }
        )

        #expect(seenByPause.withLock { $0 } == freshResumeData)
        #expect(await store.record(forID: task.id)?.resumeData == freshResumeData)
    }

    @Test("A stale automatic retry start never drives a task that a pause already took")
    func staleAutomaticRetryStartLeavesPausedTaskAlone() async throws {
        // The pause is visible in memory while its durable phase is still
        // the retry marker: the narrowest window a stale start can hit.
        let fixture = await makeStaleRetryStartFixture(state: .paused, lifecycle: .retryPending)

        await fixture.coordinator.startDownload(fixture.task, mode: .automaticRetry)

        #expect(await fixture.task.state == .paused)
        #expect(fixture.session.createdTasks.isEmpty)
        #expect(await fixture.store.record(forID: fixture.task.id)?.lifecycle == .retryPending)
    }

    @Test(
        "A stale automatic retry start leaves a task alone once its retry marker was replaced",
        arguments: [
            DownloadTaskPersistence.Record.Lifecycle.paused,
            .resuming,
            .active,
        ]
    )
    func staleAutomaticRetryStartRequiresRetryMarker(
        lifecycle: DownloadTaskPersistence.Record.Lifecycle
    ) async throws {
        let fixture = await makeStaleRetryStartFixture(state: .downloading, lifecycle: lifecycle)

        await fixture.coordinator.startDownload(fixture.task, mode: .automaticRetry)

        // In particular the task is not parked in `.waiting` behind a start
        // that can no longer win its persistence compare-and-set.
        #expect(await fixture.task.state == .downloading)
        #expect(fixture.session.createdTasks.isEmpty)
        #expect(await fixture.store.record(forID: fixture.task.id)?.lifecycle == lifecycle)
    }
}


private struct StaleRetryStartFixture {
    let coordinator: DownloadTransferCoordinator
    let task: DownloadTask
    let session: StubDownloadURLSession
    let store: InMemoryDownloadTaskStore
}


private func makeStaleRetryStartFixture(
    state: DownloadState,
    lifecycle: DownloadTaskPersistence.Record.Lifecycle
) async -> StaleRetryStartFixture {
    let task = DownloadTask(
        url: URL(string: "https://example.invalid/stale-retry-start.bin")!,
        destinationURL: makeRetryWaitDestinationURL()
    )
    await task.restoreState(state)
    let store = InMemoryDownloadTaskStore(
        seed: [
            DownloadTaskPersistence.Record(
                id: task.id,
                url: task.url,
                destinationURL: task.destinationURL,
                lifecycle: lifecycle
            )
        ]
    )
    let session = StubDownloadURLSession()
    let configuration = DownloadConfiguration.safeDefaults()
    let coordinator = DownloadTransferCoordinator(
        session: session,
        runtimeRegistry: DownloadRuntimeRegistry(),
        persistence: DownloadTaskPersistence(store: store),
        eventHub: TaskEventHub(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .downloadTask
        ),
        lifecycleGate: DownloadLifecycleGate()
    )
    return StaleRetryStartFixture(coordinator: coordinator, task: task, session: session, store: store)
}


let retryWaitConnectionLost = SendableUnderlyingError(
    domain: NSURLErrorDomain,
    code: URLError.networkConnectionLost.rawValue,
    message: "network lost"
)


func makeRetryWaitDestinationURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "inno-retry-wait-\(UUID().uuidString).bin",
        isDirectory: false
    )
}


/// `NetworkMonitoring` double whose `waitForChange` stays suspended until the
/// test reports a change, so a retry can be held in its network-wait phase
/// for exactly as long as the test needs.
actor GatedNetworkMonitor: NetworkMonitoring {
    private let baseline = NetworkSnapshot(status: .unsatisfied, interfaceTypes: [])
    private var changeWaiters: [CheckedContinuation<NetworkSnapshot?, Never>] = []
    private var reportedChange: NetworkSnapshot?

    func currentSnapshot() async -> NetworkSnapshot? {
        baseline
    }

    func waitForChange(from snapshot: NetworkSnapshot?, timeout: TimeInterval?) async -> NetworkSnapshot? {
        if let reportedChange { return reportedChange }
        return await withCheckedContinuation { continuation in
            changeWaiters.append(continuation)
        }
    }

    private var isWaiting: Bool { !changeWaiters.isEmpty }

    /// Bounded wait until a retry is parked in `waitForChange`.
    nonisolated func waitUntilWaiting(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await isWaiting { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await isWaiting
    }

    func reportChange(_ snapshot: NetworkSnapshot) {
        reportedChange = snapshot
        let waiters = changeWaiters
        changeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: snapshot)
        }
    }
}


actor RetryWaitStateRecorder {
    private var states: [DownloadState] = []

    func record(_ state: DownloadState) {
        states.append(state)
    }

    func count(of state: DownloadState) -> Int {
        states.filter { $0 == state }.count
    }

    private func contains(_ state: DownloadState) -> Bool {
        states.contains(state)
    }

    /// Bounded wait for the app callback lane, which is delivered out of
    /// band from the lifecycle transition that produced it.
    nonisolated func waitUntilContains(
        _ state: DownloadState,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await contains(state) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await contains(state)
    }
}
