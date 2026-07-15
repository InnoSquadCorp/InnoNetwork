import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkDownload

@Suite("Download Retry Persistence Tests", .serialized)
struct DownloadRetryPersistenceTests {

    @Test("retryPending restores retry counts and immediately starts a fresh attempt")
    func retryPendingRestoresCountsAndRestarts() async throws {
        let taskID = "retry-pending-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/retry-pending.bin")!
        let destinationURL = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString)-retry-pending.bin"
        )
        let record = DownloadTaskPersistence.Record(
            id: taskID,
            url: sourceURL,
            destinationURL: destinationURL,
            lifecycle: .retryPending,
            retryCount: 2,
            totalRetryCount: 4
        )
        let harness = try StubDownloadHarness(
            maxRetryCount: 5,
            maxTotalRetries: 8,
            label: "retry-pending-restore",
            prepopulatedRecords: [record]
        )

        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: taskID))
        let runtimeIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: restored,
                timeout: 2.0
            )
        )

        #expect(runtimeIdentifier == harness.stubTaskIdentifier)
        #expect(harness.stubSession.lastURL == sourceURL)
        #expect(harness.stubTask.resumeCount == 1)
        #expect(await restored.state == .downloading)
        #expect(await restored.retryCount == 2)
        #expect(await restored.totalRetryCount == 4)

        // The fresh attempt must carry the same counters in its active
        // checkpoint. Otherwise a second process death immediately after
        // restart silently resets the retry budget even though the first
        // restore reconstructed the in-memory task correctly.
        let activeCheckpoint = try #require(
            await harness.persistence.record(forID: taskID)
        )
        #expect(activeCheckpoint.lifecycle == .active)
        #expect(activeCheckpoint.retryCount == 2)
        #expect(activeCheckpoint.totalRetryCount == 4)

        await harness.manager.shutdown()

        let survivingAttempt = StubDownloadURLTask(
            request: URLRequest(url: sourceURL),
            initialState: .running
        )
        survivingAttempt.taskDescription = taskID
        let secondHarness = try StubDownloadHarness(
            maxRetryCount: 5,
            maxTotalRetries: 8,
            label: "retry-active-second-restore",
            prepopulatedRecords: [activeCheckpoint],
            preinstalledStubs: [survivingAttempt]
        )

        #expect(await secondHarness.manager.waitForRestoration())
        let restoredAgain = try #require(
            await secondHarness.manager.task(withId: taskID)
        )
        #expect(await restoredAgain.retryCount == 2)
        #expect(await restoredAgain.totalRetryCount == 4)
        #expect(
            await secondHarness.manager.runtimeTaskIdentifier(for: restoredAgain)
                == survivingAttempt.taskIdentifier
        )

        await secondHarness.manager.shutdown()
    }

    @Test("terminal records are pruned without publishing a restore failure")
    func terminalRecordIsPrunedSilently() async throws {
        let taskID = "terminal-restore-\(UUID().uuidString)"
        let record = DownloadTaskPersistence.Record(
            id: taskID,
            url: URL(string: "https://example.invalid/terminal.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-terminal.bin"),
            lifecycle: .terminal,
            retryCount: 1,
            totalRetryCount: 3
        )
        let harness = try StubDownloadHarness(
            label: "terminal-restore",
            prepopulatedRecords: [record]
        )
        let failures = DownloadFailureRecorder()

        await harness.manager.setOnFailedHandler { task, error in
            await failures.record(taskID: task.id, error: error)
        }
        #expect(await harness.manager.waitForRestoration())

        #expect(await harness.persistence.record(forID: taskID) == nil)
        #expect(await harness.manager.task(withId: taskID) == nil)
        #expect(await failures.entries.isEmpty)
        #expect(harness.stubSession.createdTasks.isEmpty)

        await harness.manager.shutdown()
    }

    @Test("a terminal tombstone surviving remove failure cannot resurrect as a missing system task")
    func terminalRemoveFailureDoesNotResurrectOnRestart() async throws {
        let firstHarness = try StubDownloadHarness(
            maxRetryCount: 0,
            maxTotalRetries: 0,
            label: "terminal-remove-failure"
        )
        let task = await firstHarness.startDownload(
            url: URL(string: "https://example.invalid/terminal-remove-failure.bin")!
        )
        let runtimeIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: firstHarness.manager,
                task: task,
                timeout: 2.0
            )
        )
        await firstHarness.store.setRemoveFailure(true)

        await firstHarness.injectCompletion(
            taskIdentifier: runtimeIdentifier,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue,
                message: "network lost"
            )
        )

        #expect(await waitForTaskState(task, timeout: 2.0) { $0 == .failed })
        let survivingTombstone = try #require(
            await firstHarness.persistence.record(forID: task.id)
        )
        #expect(survivingTombstone.lifecycle == .terminal)

        let restartedHarness = try StubDownloadHarness(
            label: "terminal-remove-failure-restart",
            prepopulatedRecords: [survivingTombstone]
        )
        let failures = DownloadFailureRecorder()
        await restartedHarness.manager.setOnFailedHandler { restoredTask, error in
            await failures.record(taskID: restoredTask.id, error: error)
        }

        #expect(await restartedHarness.manager.waitForRestoration())
        #expect(await restartedHarness.persistence.record(forID: task.id) == nil)
        #expect(await restartedHarness.manager.task(withId: task.id) == nil)
        #expect(await failures.entries.isEmpty)
        #expect(restartedHarness.stubSession.createdTasks.isEmpty)

        await firstHarness.store.setRemoveFailure(false)
        await firstHarness.manager.shutdown()
        await restartedHarness.manager.shutdown()
    }

    @Test("retryPending is durable before retry backoff begins")
    func retryPendingIsDurableBeforeBackoff() async throws {
        let clock = TestClock()
        let taskID = "retry-backoff-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/retry-backoff.bin")!
        let destinationURL = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString)-retry-backoff.bin"
        )
        let activeRecord = DownloadTaskPersistence.Record(
            id: taskID,
            url: sourceURL,
            destinationURL: destinationURL,
            lifecycle: .active
        )
        let store = InMemoryDownloadTaskStore(seed: [activeRecord])
        let persistence = DownloadTaskPersistence(store: store)
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 5,
            retryDelay: 30,
            sessionIdentifier: "test.retry-durable-backoff.\(UUID().uuidString)"
        )
        let runtimeRegistry = DownloadRuntimeRegistry()
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
        let task = DownloadTask(
            url: sourceURL,
            destinationURL: destinationURL,
            id: taskID
        )
        await task.restoreState(.downloading)
        await runtimeRegistry.add(task)
        let restarts = DownloadRestartRecorder()

        let handling = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "network lost"
                ),
                restart: { _ in
                    await restarts.record()
                }
            )
        }

        // Reaching the virtual-clock waiter proves the coordinator crossed
        // the persistence checkpoint and only then entered retry backoff.
        #expect(await clock.waitForWaiters(count: 1))
        let persistedRetry = try #require(await persistence.record(forID: taskID))
        #expect(persistedRetry.lifecycle == .retryPending)
        #expect(persistedRetry.retryCount == 1)
        #expect(persistedRetry.totalRetryCount == 1)
        #expect(persistedRetry.retryPlan?.phase == .backoff)
        #expect(
            persistedRetry.retryPlan?.retryNotBefore
                == clock.now().addingTimeInterval(30)
        )
        #expect(await task.retryCount == 1)
        #expect(await task.totalRetryCount == 1)
        #expect(await restarts.count == 0)

        handling.cancel()
        await handling.value
        #expect(await restarts.count == 0)
    }

    @Test("remaining backoff survives relaunch without choosing a new delay")
    func remainingBackoffSurvivesRelaunch() async throws {
        let clock = TestClock()
        let firstHarness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 5,
            retryDelay: 10,
            clock: clock,
            label: "retry-backoff-first-process"
        )
        let task = await firstHarness.startDownload()
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: firstHarness.manager,
                task: task
            )
        )
        await firstHarness.injectCompletion(
            taskIdentifier: identifier,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue,
                message: "network lost"
            )
        )

        #expect(await clock.waitForEnqueuedCount(atLeast: 1))
        let durableRetry = try #require(
            await firstHarness.persistence.record(forID: task.id)
        )
        #expect(durableRetry.retryPlan?.phase == .backoff)
        #expect(
            durableRetry.retryPlan?.retryNotBefore
                == Date(timeIntervalSince1970: 10)
        )
        await firstHarness.manager.shutdown()

        clock.advance(by: .seconds(4))
        let secondHarness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 5,
            retryDelay: 99,
            clock: clock,
            label: "retry-backoff-second-process",
            prepopulatedRecords: [durableRetry]
        )
        #expect(await secondHarness.manager.waitForRestoration())
        let restored = try #require(
            await secondHarness.manager.task(withId: task.id)
        )
        #expect(secondHarness.stubSession.createdTasks.isEmpty)
        #expect(await clock.waitForEnqueuedCount(atLeast: 2))

        clock.advance(by: .seconds(5))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(secondHarness.stubSession.createdTasks.isEmpty)

        clock.advance(by: .seconds(1))
        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: secondHarness.manager,
                task: restored
            )
        )
        #expect(secondHarness.stubTask.resumeCount == 1)
        #expect(await restored.retryCount == 1)
        #expect(await restored.totalRetryCount == 1)
        await secondHarness.manager.shutdown()
    }

    @Test("a past backoff deadline restarts promptly without another sleep")
    func pastBackoffDeadlineStartsImmediately() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(20))
        let taskID = "past-backoff-\(UUID().uuidString)"
        let record = DownloadTaskPersistence.Record(
            id: taskID,
            url: URL(string: "https://example.invalid/past-backoff.bin")!,
            destinationURL: URL(
                fileURLWithPath: "/tmp/\(UUID().uuidString)-past-backoff.bin"
            ),
            lifecycle: .retryPending,
            retryCount: 2,
            totalRetryCount: 4,
            retryPlan: .backoff(
                retryNotBefore: Date(timeIntervalSince1970: 10)
            )
        )
        let harness = try StubDownloadHarness(
            clock: clock,
            label: "past-backoff-restore",
            prepopulatedRecords: [record]
        )

        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: taskID))
        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: restored
            )
        )
        #expect(clock.enqueuedCount == 0)
        #expect(harness.stubTask.resumeCount == 1)
        await harness.manager.shutdown()
    }

    @Test("cancel and shutdown suppress a restored backoff restart")
    func restoredBackoffStopsAtTerminalBoundaries() async throws {
        for usesShutdown in [false, true] {
            let clock = TestClock()
            let taskID = "restored-backoff-stop-\(UUID().uuidString)"
            let record = DownloadTaskPersistence.Record(
                id: taskID,
                url: URL(string: "https://example.invalid/restored-stop.bin")!,
                destinationURL: URL(
                    fileURLWithPath: "/tmp/\(UUID().uuidString)-restored-stop.bin"
                ),
                lifecycle: .retryPending,
                retryCount: 1,
                totalRetryCount: 1,
                retryPlan: .backoff(
                    retryNotBefore: Date(timeIntervalSince1970: 30)
                )
            )
            let harness = try StubDownloadHarness(
                clock: clock,
                label: usesShutdown ? "restored-stop-shutdown" : "restored-stop-cancel",
                prepopulatedRecords: [record]
            )
            #expect(await harness.manager.waitForRestoration())
            let restored = try #require(
                await harness.manager.task(withId: taskID)
            )
            #expect(await clock.waitForWaiters(count: 1))

            if usesShutdown {
                await harness.manager.shutdown()
            } else {
                await harness.manager.cancel(restored)
            }
            clock.advance(by: .seconds(30))
            try? await Task.sleep(for: .milliseconds(20))
            #expect(harness.stubSession.createdTasks.isEmpty)

            if !usesShutdown {
                await harness.manager.shutdown()
            }
        }
    }

    @Test("network-wait admission persists its baseline and deadline before waiting")
    func networkWaitAdmissionIsDurableBeforeWait() async throws {
        let clock = TestClock()
        let baseline = NetworkSnapshot(
            status: .satisfied,
            interfaceTypes: [.wifi]
        )
        let monitor = MockNetworkMonitor(
            currentSnapshot: baseline,
            nextChangeSnapshot: nil,
            changeDelay: 60
        )
        let taskID = "network-admission-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/network-admission.bin")!
        let destinationURL = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString)-network-admission.bin"
        )
        let persistence = DownloadTaskPersistence(
            store: InMemoryDownloadTaskStore(
                seed: [
                    DownloadTaskPersistence.Record(
                        id: taskID,
                        url: sourceURL,
                        destinationURL: destinationURL,
                        lifecycle: .active
                    )
                ]
            )
        )
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 5,
            retryDelay: 30,
            sessionIdentifier: "test.retry-network-admission.\(UUID().uuidString)",
            networkMonitor: monitor,
            waitsForNetworkChanges: true,
            networkChangeTimeout: 20
        )
        let runtimeRegistry = DownloadRuntimeRegistry()
        let eventHub = TaskEventHub<DownloadEvent>(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .downloadTask
        )
        let lifecycleGate = DownloadLifecycleGate()
        let coordinator = DownloadFailureCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry,
            persistence: persistence,
            eventHub: eventHub,
            lifecycleGate: lifecycleGate,
            clock: clock
        )
        let task = DownloadTask(
            url: sourceURL,
            destinationURL: destinationURL,
            id: taskID
        )
        await task.restoreState(.downloading)
        await runtimeRegistry.add(task)
        let admissionCompleted = OSAllocatedUnfairLock(initialState: false)

        let handling = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "network lost"
                ),
                onAdmissionComplete: {
                    admissionCompleted.withLock { $0 = true }
                },
                restart: { _ in }
            )
        }

        #expect(
            await waitForRetryPersistenceCondition {
                await monitor.waitForChangeCallCount == 1
            }
        )
        #expect(admissionCompleted.withLock { $0 })
        let persisted = try #require(await persistence.record(forID: taskID))
        #expect(persisted.retryPlan?.phase == .waitingForNetwork)
        #expect(persisted.retryPlan?.networkBaseline?.value == baseline)
        #expect(
            persisted.retryPlan?.networkWaitDeadline
                == Date(timeIntervalSince1970: 20)
        )
        #expect(await monitor.lastWaitBaseline == baseline)
        #expect(await monitor.lastWaitTimeout == 20)

        _ = lifecycleGate.beginShutdown()
        await handling.value
    }

    @Test("append-log replay preserves retry schedule metadata")
    func appendLogRoundTripsRetryPlan() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "inno-retry-plan-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let sessionIdentifier = "retry-plan-roundtrip"
        let taskID = "retry-plan-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/retry-plan.bin")!
        let destinationURL = baseDirectory.appendingPathComponent("retry-plan.bin")
        let baseline = NetworkSnapshot(
            status: .requiresConnection,
            interfaceTypes: [.wifi, .cellular]
        )
        let plan = DownloadTaskPersistence.RetryPlan.waitingForNetwork(
            baseline: baseline,
            deadline: Date(timeIntervalSince1970: 123)
        )
        let writer = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        try await writer.upsert(
            id: taskID,
            url: sourceURL,
            destinationURL: destinationURL
        )
        #expect(
            try await writer.updateRetryState(
                id: taskID,
                retryCount: 2,
                totalRetryCount: 4,
                retryPlan: plan
            )
        )

        let reader = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        let replayed = try #require(await reader.record(forID: taskID))
        #expect(replayed.lifecycle == .retryPending)
        #expect(replayed.retryCount == 2)
        #expect(replayed.totalRetryCount == 4)
        #expect(replayed.retryPlan == plan)
        #expect(replayed.retryPlan?.networkBaseline?.value == baseline)
    }

    @Test("legacy retry records decode without schedule metadata")
    func legacyRetryRecordDecodesWithoutPlan() throws {
        struct LegacyRecord: Codable {
            let id: String
            let url: URL
            let destinationURL: URL
            let resumeData: Data?
            let lifecycle: DownloadTaskPersistence.Record.Lifecycle?
            let retryCount: Int?
            let totalRetryCount: Int?
        }

        let legacy = LegacyRecord(
            id: "legacy-retry",
            url: URL(string: "https://example.invalid/legacy-retry.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/legacy-retry.bin"),
            resumeData: nil,
            lifecycle: .retryPending,
            retryCount: 2,
            totalRetryCount: 4
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(
            DownloadTaskPersistence.Record.self,
            from: data
        )

        #expect(decoded.lifecycle == .retryPending)
        #expect(decoded.retryCount == 2)
        #expect(decoded.totalRetryCount == 4)
        #expect(decoded.retryPlan == nil)
    }

    @Test("expired network wait observes downtime changes and checkpoints reset backoff")
    func expiredNetworkWaitRestoresBaselineAndResetSemantics() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(25))
        let baseline = NetworkSnapshot(
            status: .satisfied,
            interfaceTypes: [.wifi]
        )
        let changed = NetworkSnapshot(
            status: .satisfied,
            interfaceTypes: [.cellular]
        )
        let monitor = MockNetworkMonitor(
            currentSnapshot: changed,
            nextChangeSnapshot: changed
        )
        let taskID = "network-restore-\(UUID().uuidString)"
        let record = DownloadTaskPersistence.Record(
            id: taskID,
            url: URL(string: "https://example.invalid/network-restore.bin")!,
            destinationURL: URL(
                fileURLWithPath: "/tmp/\(UUID().uuidString)-network-restore.bin"
            ),
            lifecycle: .retryPending,
            retryCount: 2,
            totalRetryCount: 4,
            retryPlan: .waitingForNetwork(
                baseline: baseline,
                deadline: Date(timeIntervalSince1970: 20)
            )
        )
        let harness = try StubDownloadHarness(
            maxRetryCount: 5,
            maxTotalRetries: 8,
            retryDelay: 10,
            networkMonitor: monitor,
            waitsForNetworkChanges: true,
            networkChangeTimeout: 999,
            clock: clock,
            label: "network-plan-restore",
            prepopulatedRecords: [record]
        )

        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: taskID))
        #expect(
            await waitForRetryPersistenceCondition {
                await harness.persistence.record(forID: taskID)?.retryPlan?.phase
                    == .backoff
            }
        )
        #expect(await monitor.lastWaitBaseline == baseline)
        #expect(await monitor.lastWaitTimeout == 0)
        #expect(await restored.retryCount == 0)
        #expect(await restored.totalRetryCount == 4)
        let backoff = try #require(await harness.persistence.record(forID: taskID))
        #expect(backoff.retryCount == 0)
        #expect(backoff.totalRetryCount == 4)
        #expect(
            backoff.retryPlan?.retryNotBefore
                == Date(timeIntervalSince1970: 35)
        )
        #expect(harness.stubSession.createdTasks.isEmpty)
        #expect(await clock.waitForWaiters(count: 1))

        clock.advance(by: .seconds(10))
        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: restored
            )
        )
        #expect(harness.stubTask.resumeCount == 1)
        await harness.manager.shutdown()
    }

    @Test("a suspended retry checkpoint cannot overwrite a terminal winner")
    func terminalMarkerIsAbsorbingAgainstSuspendedRetryUpdate() async throws {
        let taskID = "terminal-cas-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/terminal-cas.bin")!
        let destinationURL = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString)-terminal-cas.bin"
        )
        let store = InMemoryDownloadTaskStore(
            seed: [
                DownloadTaskPersistence.Record(
                    id: taskID,
                    url: sourceURL,
                    destinationURL: destinationURL,
                    lifecycle: .active
                )
            ]
        )
        let persistence = DownloadTaskPersistence(store: store)
        await store.suspendUpserts()

        let staleRetry = Task {
            try await persistence.updateRetryState(
                id: taskID,
                retryCount: 1,
                totalRetryCount: 1
            )
        }
        #expect(
            await waitForRetryPersistenceCondition {
                await store.pendingUpsertCount == 1
            }
        )

        try await persistence.markTerminal(ids: [taskID])
        await store.resumeUpserts()
        #expect(try await staleRetry.value == false)

        let terminal = try #require(await persistence.record(forID: taskID))
        #expect(terminal.lifecycle == .terminal)
        #expect(terminal.retryCount == nil)
        #expect(terminal.totalRetryCount == nil)
        #expect(
            try await persistence.updateRetryState(
                id: "missing-\(UUID().uuidString)",
                retryCount: 1,
                totalRetryCount: 1
            ) == false
        )

        let missingTask = DownloadTask(
            url: sourceURL,
            destinationURL: destinationURL,
            id: "missing-terminal-\(UUID().uuidString)"
        )
        await missingTask.restoreState(.cancelled)
        try await persistence.markTerminal(task: missingTask)
        let inserted = try #require(
            await persistence.record(forID: missingTask.id)
        )
        #expect(inserted.lifecycle == .terminal)
        #expect(inserted.url == sourceURL)
        #expect(inserted.destinationURL == destinationURL)
    }

    @Test("cancel waits for a suspended initial upsert and leaves an absorbing tombstone")
    func cancelWinsSuspendedInitialUpsertWhenRemoveFails() async throws {
        let harness = try StubDownloadHarness(label: "cancel-initial-upsert-race")
        await harness.store.suspendUpserts()

        let downloadWork = Task {
            await harness.startDownload(
                url: URL(string: "https://example.invalid/cancel-upsert.bin")!
            )
        }
        #expect(
            await waitForRetryPersistenceCondition {
                await harness.store.pendingUpsertCount == 1
            }
        )
        let task = try #require((await harness.manager.allTasks()).first)
        await harness.store.setRemoveFailure(true)

        let cancellation = Task {
            await harness.manager.cancel(task)
        }
        #expect(await waitForTaskState(task) { $0 == .cancelled })

        await harness.store.resumeUpserts()
        #expect(await downloadWork.value === task)
        await cancellation.value

        let survivingTombstone = try #require(
            await harness.persistence.record(forID: task.id)
        )
        #expect(survivingTombstone.lifecycle == .terminal)
        #expect(survivingTombstone.url == task.url)
        #expect(survivingTombstone.destinationURL == task.destinationURL)
        #expect(harness.stubSession.createdTasks.isEmpty)

        await harness.store.setRemoveFailure(false)
        await harness.manager.cancel(task)
        await harness.manager.shutdown()
    }

    @Test("cancel and cancelAll serialize terminal cleanup against manual retry")
    func terminalCleanupWinsConcurrentManualRetry() async throws {
        for usesCancelAll in [false, true] {
            let retryStub = StubDownloadURLTask()
            let harness = try StubDownloadHarness(
                maxRetryCount: 0,
                maxTotalRetries: 0,
                label: usesCancelAll ? "cancel-all-retry-race" : "cancel-retry-race",
                prequeuedStubs: [retryStub]
            )
            let task = await harness.startDownload()
            let taskIdentifier = try #require(
                await waitForRuntimeTaskIdentifier(
                    manager: harness.manager,
                    task: task
                )
            )
            await harness.store.setRemoveFailure(true)
            await harness.injectCompletion(
                taskIdentifier: taskIdentifier,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "network lost"
                )
            )
            #expect(await waitForTaskState(task) { $0 == .failed })
            #expect(await harness.persistence.record(forID: task.id)?.lifecycle == .terminal)

            await harness.store.setRemoveFailure(false)
            await harness.store.suspendTerminalWrites()
            let cleanup = Task {
                if usesCancelAll {
                    await harness.manager.cancelAll()
                } else {
                    await harness.manager.cancel(task)
                }
            }
            #expect(
                await waitForRetryPersistenceCondition {
                    await harness.store.pendingTerminalWriteCount == 1
                }
            )

            let retry = Task {
                await harness.manager.retry(task)
            }
            try? await Task.sleep(for: .milliseconds(25))
            #expect(await task.state == .failed)
            #expect(retryStub.resumeCount == 0)

            await harness.store.resumeTerminalWrites()
            await cleanup.value
            await retry.value

            #expect(await task.state == .failed)
            #expect(retryStub.resumeCount == 0)
            #expect(await harness.persistence.record(forID: task.id) == nil)
            #expect(await harness.manager.task(withId: task.id) == nil)
            await harness.manager.shutdown()
        }
    }

    @Test("orphan restore seals terminal intent before removal and remains manually retryable")
    func orphanRestoreRemoveFailureIsTerminalAndRetryable() async throws {
        let taskID = "orphan-terminal-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/orphan-terminal.bin")!
        let destinationURL = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString)-orphan-terminal.bin"
        )
        let active = DownloadTaskPersistence.Record(
            id: taskID,
            url: sourceURL,
            destinationURL: destinationURL,
            lifecycle: .active,
            retryCount: 2,
            totalRetryCount: 4
        )
        let harness = try StubDownloadHarness(
            label: "orphan-terminal",
            failsRemovesInitially: true,
            prepopulatedRecords: [active]
        )

        #expect(await harness.manager.waitForRestoration())
        let failedTask = try #require(await harness.manager.task(withId: taskID))
        #expect(await failedTask.state == .failed)
        if case .restorationMissingSystemTask? = await failedTask.error {
            // Expected typed restore failure.
        } else {
            Issue.record("Expected restorationMissingSystemTask")
        }
        let tombstone = try #require(await harness.persistence.record(forID: taskID))
        #expect(tombstone.lifecycle == .terminal)

        let restarted = try StubDownloadHarness(
            label: "orphan-terminal-restart",
            prepopulatedRecords: [tombstone]
        )
        #expect(await restarted.manager.waitForRestoration())
        #expect(await restarted.manager.task(withId: taskID) == nil)
        #expect(await restarted.persistence.record(forID: taskID) == nil)

        await harness.store.setRemoveFailure(false)
        await harness.manager.retry(failedTask)
        #expect(await failedTask.state == .downloading)
        #expect(harness.stubTask.resumeCount == 1)
        let retriedRecord = try #require(await harness.persistence.record(forID: taskID))
        #expect(retriedRecord.lifecycle == .active)
        #expect(retriedRecord.retryCount == 0)
        #expect(retriedRecord.totalRetryCount == 0)

        await harness.manager.cancel(failedTask)
        await harness.manager.shutdown()
        await restarted.manager.shutdown()
    }
}

private func waitForRetryPersistenceCondition(
    timeout: TimeInterval = 2.0,
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}

private actor DownloadFailureRecorder {
    private(set) var entries: [(taskID: String, error: DownloadError)] = []

    func record(taskID: String, error: DownloadError) {
        entries.append((taskID, error))
    }
}

private actor DownloadRestartRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
