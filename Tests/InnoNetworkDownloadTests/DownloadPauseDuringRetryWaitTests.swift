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

    @Test("A retry restored after relaunch can be paused while it waits, and the wait does not restart it")
    func pauseDuringRestoredRetryWait() async throws {
        let clock = TestClock()
        let id = "restored-retry-wait-\(UUID().uuidString)"
        let sourceURL = try #require(URL(string: "https://example.invalid/restored-retry-wait.bin"))
        let resumeData = try makeRetryResumeData("restored-retry-wait")
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 30,
            clock: clock,
            label: "pause-restored-retry-wait",
            prepopulatedRecords: [
                DownloadTaskPersistence.Record(
                    id: id,
                    url: sourceURL,
                    destinationURL: makeRetryWaitDestinationURL(),
                    resumeData: resumeData,
                    lifecycle: .retryPending,
                    retryCount: 1,
                    totalRetryCount: 1,
                    retryPlan: .backoff(retryNotBefore: clock.now().addingTimeInterval(30))
                )
            ]
        )
        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: id))
        // The restored retry is waiting out its backoff with no attempt.
        #expect(await clock.waitForEnqueuedCount(atLeast: 1, timeout: 10.0))
        #expect(await restored.state == .downloading)

        await harness.manager.pause(restored)

        #expect(await restored.state == .paused)
        let paused = await harness.store.record(forID: id)
        #expect(paused?.lifecycle == .paused)
        #expect(paused?.resumeData == resumeData)
        clock.advance(by: .seconds(60))
        await harness.manager.drainDeferredFailureTasks()
        #expect(harness.stubSession.createdTasks.isEmpty)
        #expect(await restored.state == .paused)

        await harness.manager.shutdown()
    }

    @Test("An attempt that fails after a pause made `.pausing` durable leaves the task paused, not stranded")
    func failureAfterPausingWrittenEndsPaused() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 30,
            clock: TestClock(),
            label: "pause-then-failure"
        )
        let task = await harness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
        let failureResumeData = try makeRetryResumeData("failed-under-pause")
        await harness.store.setAfterPausingWritten { _ in
            // The failure finds `.pausing` and defers to the pause: it retires
            // the attempt and neither retries nor fails the task.
            await harness.injectCompletion(
                taskIdentifier: identifier,
                error: retryWaitConnectionLost,
                resumeData: failureResumeData
            )
        }

        await harness.manager.pause(task)

        #expect(await task.state == .paused)
        let paused = await harness.store.record(forID: task.id)
        #expect(paused?.lifecycle == .paused)
        #expect(paused?.resumeData == failureResumeData)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == nil)

        await harness.manager.shutdown()
    }

    @Test("An attempt that fails just before a pause writes `.pausing` pauses the retry instead of failing")
    func failureBeforePausingWriteEndsPaused() async throws {
        let clock = TestClock()
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 30,
            clock: clock,
            label: "failure-then-pause"
        )
        let task = await harness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
        await harness.store.setBeforePausingWrite { _ in
            // The retry marker becomes durable first, so the pause's own
            // compare-and-set finds `.retryPending` instead of `.active`.
            await harness.injectCompletion(taskIdentifier: identifier, error: retryWaitConnectionLost)
        }

        await harness.manager.pause(task)

        #expect(await task.state == .paused)
        #expect(await task.error == nil)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .paused)
        // The scheduled retry ends without restarting the paused task. Its
        // backoff sleeper is registered out of band; one registered after the
        // advance would outlast it and the drain below would never return.
        #expect(await clock.waitForEnqueuedCount(atLeast: 1, timeout: 10.0))
        clock.advance(by: .seconds(60))
        await harness.manager.drainDeferredFailureTasks()
        #expect(harness.stubSession.createdTasks.count == 1)
        #expect(await task.state == .paused)

        await harness.manager.shutdown()
    }

    @Test("An attempt that fails while a pause waits for its resume data leaves the task paused")
    func failureDuringResumeDataCancellationEndsPaused() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 30,
            clock: TestClock(),
            label: "failure-during-pause-cancel"
        )
        let task = await harness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
        harness.stubTask.suspendCancelByProducingResumeData()

        let pause = Task { await harness.manager.pause(task) }
        #expect(await waitForCancelByProducingResumeDataCount(harness.stubTask, atLeast: 1, timeout: 10.0))
        // The pause made `.pausing` durable and owns the attempt; the failure
        // that arrives now defers to it and retires the attempt.
        await harness.injectCompletion(taskIdentifier: identifier, error: retryWaitConnectionLost)
        let producedResumeData = try makeRetryResumeData("produced-by-pause")
        harness.stubTask.completeCancelByProducingResumeData(with: producedResumeData)
        await pause.value

        #expect(await task.state == .paused)
        let paused = await harness.store.record(forID: task.id)
        #expect(paused?.lifecycle == .paused)
        #expect(paused?.resumeData == producedResumeData)

        await harness.manager.shutdown()
    }

    @Test("A pause that cannot make its outcome durable fails the task instead of stranding it")
    func settledPauseWriteFailureFailsTask() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 30,
            clock: TestClock(),
            label: "pause-settle-write-failure"
        )
        let task = await harness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
        await harness.store.setAfterPausingWritten { _ in
            await harness.injectCompletion(taskIdentifier: identifier, error: retryWaitConnectionLost)
            // The `.paused` write that would settle the pause then fails.
            await harness.store.setUpsertFailure(true)
        }

        await harness.manager.pause(task)

        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .failed })

        await harness.store.setUpsertFailure(false)
        await harness.manager.shutdown()
    }

    @Test("A pause issued while a failure is being admitted waits for it and pauses the waiting retry")
    func pauseDuringFailureAdmissionPausesTheRetry() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 30,
            clock: TestClock(),
            label: "pause-during-admission"
        )
        let task = await harness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
        let failureResumeData = try makeRetryResumeData("failed-during-admission")
        let pause = ConcurrentJob()
        let pauseMetAdmission = OSAllocatedUnfairLock(initialState: false)
        await harness.store.setBeforeRetryMarkerWritten { _ in
            // The failure has retired the attempt's runtime and its retry
            // marker is not durable yet. A pause used to read this gap as
            // nothing to pause.
            pause.start { await harness.manager.pause(task) }
            let met = await eventually {
                await harness.manager.completionHandlingWaiterCount(taskID: task.id) == 1 || pause.isFinished
            }
            pauseMetAdmission.withLock { $0 = met }
        }

        await harness.injectCompletion(
            taskIdentifier: identifier,
            error: retryWaitConnectionLost,
            resumeData: failureResumeData
        )
        await pause.wait()

        // A pause that only ran once the marker was durable would pass the
        // checks below without meeting the gap.
        #expect(
            pauseMetAdmission.withLock { $0 },
            "The pause did not start while the failure was being admitted"
        )
        #expect(await task.state == .paused)
        #expect(await task.resumeData == failureResumeData)
        let paused = await harness.store.record(forID: task.id)
        #expect(paused?.lifecycle == .paused)
        #expect(paused?.resumeData == failureResumeData)

        await harness.manager.shutdown()
    }

    @Test("A pause that settles an attempt whose failure is still being admitted keeps the failure's resume data")
    func pauseSettlingDuringFailureAdmissionKeepsItsResumeData() async throws {
        let monitor = SnapshotHoldingNetworkMonitor()
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 30,
            networkMonitor: monitor,
            waitsForNetworkChanges: true,
            clock: TestClock(),
            label: "pause-settles-during-admission"
        )
        let task = await harness.startDownload(destinationURL: makeRetryWaitDestinationURL())
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
        let failureResumeData = try makeRetryResumeData("failed-while-pause-settles")
        let injection = ConcurrentJob()
        let failureStoppedInAdmission = OSAllocatedUnfairLock(initialState: false)
        await harness.store.setAfterPausingWritten { _ in
            // The failure retires the attempt's runtime, then stops before it
            // records its resume data on the task.
            injection.start {
                await harness.injectCompletion(
                    taskIdentifier: identifier,
                    error: retryWaitConnectionLost,
                    resumeData: failureResumeData
                )
            }
            let stopped = await eventually { await monitor.isHolding }
            failureStoppedInAdmission.withLock { $0 = stopped }
        }

        let pause = ConcurrentJob()
        pause.start { await harness.manager.pause(task) }
        // The pause finds no runtime and settles the ended attempt. Before
        // the fix it settled at once, without the failure's resume data.
        let pauseMetAdmission = await eventually {
            await harness.manager.completionHandlingWaiterCount(taskID: task.id) == 1 || pause.isFinished
        }
        // Had either wait run out, the admission would be let go before the
        // pause settles, and the checks below would pass without meeting
        // the gap.
        #expect(
            failureStoppedInAdmission.withLock { $0 },
            "The failure did not stop inside its admission"
        )
        #expect(pauseMetAdmission, "The pause did not settle while the failure was being admitted")
        await monitor.release()
        await injection.wait()
        await pause.wait()

        #expect(await task.state == .paused)
        #expect(await task.resumeData == failureResumeData)
        let paused = await harness.store.record(forID: task.id)
        #expect(paused?.lifecycle == .paused)
        #expect(paused?.resumeData == failureResumeData)

        await harness.manager.shutdown()
    }
}

/// Runs one job concurrently and reports whether it has returned.
private final class ConcurrentJob: Sendable {
    private let state = OSAllocatedUnfairLock<(job: Task<Void, Never>?, finished: Bool)>(
        initialState: (nil, false)
    )

    var isFinished: Bool { state.withLock { $0.finished } }

    func start(_ body: @escaping @Sendable () async -> Void) {
        let job = Task {
            await body()
            self.state.withLock { $0.finished = true }
        }
        state.withLock { $0.job = job }
    }

    func wait() async {
        await state.withLock { $0.job }?.value
    }
}

/// Holds `currentSnapshot()` until released, so a failure's admission stops
/// after the attempt's runtime is retired and before its resume data is set.
private actor SnapshotHoldingNetworkMonitor: NetworkMonitoring {
    private var holds: [CheckedContinuation<Void, Never>] = []
    private var released = false

    var isHolding: Bool { !holds.isEmpty }

    func currentSnapshot() async -> NetworkSnapshot? {
        if !released {
            await withCheckedContinuation { holds.append($0) }
        }
        return NetworkSnapshot(status: .unsatisfied, interfaceTypes: [])
    }

    func waitForChange(from snapshot: NetworkSnapshot?, timeout: TimeInterval?) async -> NetworkSnapshot? {
        nil
    }

    func release() {
        released = true
        let held = holds
        holds.removeAll()
        for hold in held {
            hold.resume()
        }
    }
}

/// Polls `condition` until it holds or the wait budget runs out.
private func eventually(
    timeout: TimeInterval = 10,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(TestWaitBudget.upperBound(timeout))
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
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
