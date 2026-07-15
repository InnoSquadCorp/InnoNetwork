import Foundation
import Testing

@testable import InnoNetworkDownload

/// Restore-coordinator behavior verified through `StubDownloadURLSession`
/// + an in-memory `InMemoryDownloadTaskStore`. Replaces the previous real
/// URLSession + on-disk `AppendLogDownloadTaskStore` integration tests so
/// persistence pre-population is deterministic and no temp directory is
/// left behind.
@Suite("Download Restore Tests", .serialized)
struct DownloadRestoreTests {

    @Test("Fresh manager completes restore barrier and accepts new downloads")
    func freshManagerCompletesRestoreBarrier() async throws {
        let harness = try StubDownloadHarness(label: "restore-fresh")

        let task = await harness.startDownload()

        #expect(await harness.manager.task(withId: task.id) != nil)
        await harness.manager.cancel(task)
    }

    @Test("Orphaned persistence records are pruned after restore")
    func orphanedPersistenceRecordsPruned() async throws {
        let orphanRecord = DownloadTaskPersistence.Record(
            id: "orphan-task",
            url: URL(string: "https://example.invalid/orphan.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-orphan.zip")
        )
        let harness = try StubDownloadHarness(
            label: "restore-orphan",
            prepopulatedRecords: [orphanRecord]
        )

        // `waitForRestore` runs before the first `download()` returns, so
        // awaiting a no-op download guarantees restore has completed.
        let probe = await harness.startDownload()
        await harness.manager.cancel(probe)

        #expect(await harness.persistence.record(forID: "orphan-task") == nil)
    }

    @Test("Paused persisted records with resume data restore without a system task")
    func pausedRecordWithResumeDataRestores() async throws {
        let pausedID = "paused-task-\(UUID().uuidString)"
        let resumeData = Data("resume-after-relaunch".utf8)
        let pausedRecord = DownloadTaskPersistence.Record(
            id: pausedID,
            url: URL(string: "https://example.invalid/paused.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-paused.zip"),
            resumeData: resumeData
        )
        let resumedStub = StubDownloadURLTask(request: URLRequest(url: pausedRecord.url))
        let harness = try StubDownloadHarness(
            label: "restore-paused",
            prepopulatedRecords: [pausedRecord],
            prequeuedStubs: [resumedStub]
        )

        let probe = await harness.startDownload(
            url: URL(string: "https://example.invalid/probe.zip")!
        )
        await harness.manager.cancel(probe)

        let restoredTask = try #require(await harness.manager.task(withId: pausedID))
        #expect(await restoredTask.state == .paused)
        #expect(await restoredTask.resumeData == resumeData)

        await harness.manager.resume(restoredTask)

        #expect(harness.stubSession.lastResumeData == resumeData)
        #expect(await restoredTask.resumeData == nil)
    }

    @Test("Explicitly paused record without resume data restores as paused and restarts fresh")
    func pausedRecordWithoutResumeDataRestores() async throws {
        let pausedID = "paused-without-data-\(UUID().uuidString)"
        let pausedURL = URL(string: "https://example.invalid/paused-without-data.zip")!
        let pausedRecord = DownloadTaskPersistence.Record(
            id: pausedID,
            url: pausedURL,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-paused-without-data.zip"),
            resumeData: nil,
            lifecycle: .paused
        )
        let harness = try StubDownloadHarness(
            label: "restore-paused-without-data",
            prepopulatedRecords: [pausedRecord]
        )

        let restoredTask = try #require(await harness.manager.task(withId: pausedID))
        #expect(await restoredTask.state == .paused)
        #expect(await restoredTask.resumeData == nil)

        await harness.manager.resume(restoredTask)

        #expect(harness.stubSession.lastURL == pausedURL)
        #expect(harness.stubSession.lastResumeData == nil)
        #expect(await restoredTask.state == .downloading)
        await harness.manager.cancel(restoredTask)
    }

    @Test("Restore quarantines persisted resume data whose source URL is no longer admitted")
    func rejectedPausedRecordIsPrunedBeforeResume() async throws {
        let rejectedID = "rejected-paused-\(UUID().uuidString)"
        let rejectedRecord = DownloadTaskPersistence.Record(
            id: rejectedID,
            url: URL(string: "http://example.invalid/paused.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-paused.zip"),
            resumeData: Data("legacy-http-resume-data".utf8)
        )
        let harness = try StubDownloadHarness(
            label: "restore-rejected-paused",
            prepopulatedRecords: [rejectedRecord]
        )

        #expect(await harness.manager.waitForRestoration())
        #expect(await harness.manager.task(withId: rejectedID) == nil)
        #expect(await harness.persistence.record(forID: rejectedID) == nil)
        #expect(harness.stubSession.lastResumeData == nil)
        #expect(harness.stubSession.createdTasks.isEmpty)
        await harness.manager.shutdown()
    }

    @Test("Restore keeps plain HTTP resume data when explicitly opted in")
    func optedInHTTPPausedRecordRestores() async throws {
        let pausedID = "opted-in-http-paused-\(UUID().uuidString)"
        let resumeData = Data("opted-in-http-resume-data".utf8)
        let pausedRecord = DownloadTaskPersistence.Record(
            id: pausedID,
            url: URL(string: "http://localhost/paused.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-paused.zip"),
            resumeData: resumeData
        )
        let harness = try StubDownloadHarness(
            allowsInsecureHTTP: true,
            label: "restore-opted-in-http-paused",
            prepopulatedRecords: [pausedRecord]
        )

        #expect(await harness.manager.waitForRestoration())
        let restoredTask = try #require(await harness.manager.task(withId: pausedID))
        #expect(await restoredTask.state == .paused)
        #expect(await restoredTask.resumeData == resumeData)
        await harness.manager.shutdown()
    }

    @Test("Foreign system tasks are cancelled during restore")
    func foreignSystemTasksAreCancelled() async throws {
        let foreignURL = URL(string: "https://example.invalid/foreign.zip")!
        let foreignStub = StubDownloadURLTask(
            request: URLRequest(url: foreignURL),
            initialState: .running
        )
        let harness = try StubDownloadHarness(
            label: "restore-foreign",
            preinstalledStubs: [foreignStub]
        )

        let probe = await harness.startDownload(
            url: URL(string: "https://example.invalid/probe.zip")!
        )
        await harness.manager.cancel(probe)

        #expect(foreignStub.cancelCount == 1)
    }

    @Test("An active record with only a canceling system task reports restoration failure")
    func cancelingSystemTaskWithoutTerminalIntentFailsClosed() async throws {
        let trackedID = "canceling-task-\(UUID().uuidString)"
        let trackedURL = URL(string: "https://example.invalid/canceling.zip")!
        let persistedRecord = DownloadTaskPersistence.Record(
            id: trackedID,
            url: trackedURL,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-canceling.zip")
        )
        let cancelingStub = StubDownloadURLTask(
            request: URLRequest(url: trackedURL),
            initialState: .canceling
        )
        let harness = try StubDownloadHarness(
            label: "restore-canceling-url",
            prepopulatedRecords: [persistedRecord],
            preinstalledStubs: [cancelingStub]
        )

        #expect(await harness.manager.waitForRestoration())
        #expect(await harness.persistence.record(forID: trackedID) == nil)
        let restoredTask = try #require(await harness.manager.task(withId: trackedID))
        #expect(await restoredTask.state == .failed)
        guard case .some(.restorationMissingSystemTask) = await restoredTask.error else {
            Issue.record("Expected restorationMissingSystemTask for an unowned canceling transport")
            await harness.manager.shutdown()
            return
        }
        #expect(cancelingStub.cancelCount == 0)
        await harness.manager.shutdown()
    }

    @Test("Canceling pause transport preserves an explicitly paused record without resume data")
    func cancelingPauseTransportPreservesPausedRecord() async throws {
        let taskID = "canceling-paused-\(UUID().uuidString)"
        let url = URL(string: "https://example.invalid/canceling-paused.zip")!
        let record = DownloadTaskPersistence.Record(
            id: taskID,
            url: url,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-canceling-paused.zip"),
            resumeData: nil,
            lifecycle: .paused
        )
        let cancelingStub = StubDownloadURLTask(
            request: URLRequest(url: url),
            initialState: .canceling
        )
        cancelingStub.taskDescription = taskID
        let harness = try StubDownloadHarness(
            label: "restore-canceling-paused",
            prepopulatedRecords: [record],
            preinstalledStubs: [cancelingStub]
        )

        let restored = try #require(await harness.manager.task(withId: taskID))
        #expect(await restored.state == .paused)
        #expect(await restored.resumeData == nil)
        #expect(await harness.persistence.record(forID: taskID)?.lifecycle == .paused)
        await harness.manager.cancel(restored)
    }

    @Test("Canceling predecessor never deletes the row for a viable replacement attempt")
    func cancelingPredecessorPreservesViableAttempt() async throws {
        for reverseOrder in [false, true] {
            let taskID = "canceling-with-live-\(reverseOrder)-\(UUID().uuidString)"
            let url = URL(string: "https://example.invalid/canceling-with-live.zip")!
            let record = DownloadTaskPersistence.Record(
                id: taskID,
                url: url,
                destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-live.zip")
            )
            let canceling = StubDownloadURLTask(
                taskIdentifier: 20_000 + (reverseOrder ? 2 : 0),
                request: URLRequest(url: url),
                initialState: .canceling
            )
            let live = StubDownloadURLTask(
                taskIdentifier: 20_001 + (reverseOrder ? 2 : 0),
                request: URLRequest(url: url),
                initialState: .running
            )
            canceling.taskDescription = taskID
            live.taskDescription = taskID
            let installed = reverseOrder ? [live, canceling] : [canceling, live]
            let harness = try StubDownloadHarness(
                label: "restore-canceling-with-live-\(reverseOrder)",
                prepopulatedRecords: [record],
                preinstalledStubs: installed
            )

            let restored = try #require(await harness.manager.task(withId: taskID))
            #expect(await restored.state == .downloading)
            #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == live.taskIdentifier)
            #expect(await harness.persistence.record(forID: taskID) != nil)
            await harness.manager.shutdown()
        }
    }

    @Test("Multiple viable attempts for one logical ID keep only the newest identifier")
    func duplicateViableAttemptsKeepNewest() async throws {
        let taskID = "duplicate-live-\(UUID().uuidString)"
        let url = URL(string: "https://example.invalid/duplicate-live.zip")!
        let record = DownloadTaskPersistence.Record(
            id: taskID,
            url: url,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-duplicate-live.zip")
        )
        let older = StubDownloadURLTask(
            taskIdentifier: 30_000,
            request: URLRequest(url: url),
            initialState: .running
        )
        let newer = StubDownloadURLTask(
            taskIdentifier: 30_001,
            request: URLRequest(url: url),
            initialState: .running
        )
        older.taskDescription = taskID
        newer.taskDescription = taskID
        let harness = try StubDownloadHarness(
            label: "restore-duplicate-live",
            prepopulatedRecords: [record],
            preinstalledStubs: [newer, older]
        )

        let restored = try #require(await harness.manager.task(withId: taskID))
        #expect(older.cancelCount == 1)
        #expect(newer.cancelCount == 0)
        #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == newer.taskIdentifier)
        await harness.manager.shutdown()
    }

    @Test("Legacy URL fallback refuses to guess between duplicate persisted records")
    func legacyURLFallbackRejectsAmbiguousRecords() async throws {
        let url = URL(string: "https://example.invalid/ambiguous-legacy.zip")!
        let records = (0..<2).map { index in
            DownloadTaskPersistence.Record(
                id: "ambiguous-\(index)-\(UUID().uuidString)",
                url: url,
                destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\(index).zip")
            )
        }
        let live = StubDownloadURLTask(
            request: URLRequest(url: url),
            initialState: .running
        )
        let harness = try StubDownloadHarness(
            label: "restore-ambiguous-legacy",
            prepopulatedRecords: records,
            preinstalledStubs: [live]
        )

        #expect(await harness.manager.waitForRestoration())
        #expect(live.cancelCount == 1)
        #expect(live.taskDescription == nil)
        for record in records {
            let failed = try #require(await harness.manager.task(withId: record.id))
            #expect(await failed.state == .failed)
            guard case .restorationMissingSystemTask? = await failed.error else {
                Issue.record("Expected an explicit missing-system-task failure for \(record.id)")
                continue
            }
        }
        await harness.manager.shutdown()
    }

    @Test("Legacy URL fallback ignores non-live phases when one live candidate remains")
    func legacyURLFallbackFiltersNonLiveCandidates() async throws {
        let url = URL(string: "https://example.invalid/live-legacy.zip")!
        let active = DownloadTaskPersistence.Record(
            id: "active-\(UUID().uuidString)",
            url: url,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-active.zip"),
            lifecycle: .active
        )
        let terminal = DownloadTaskPersistence.Record(
            id: "terminal-\(UUID().uuidString)",
            url: url,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-terminal.zip"),
            lifecycle: .terminal
        )
        let paused = DownloadTaskPersistence.Record(
            id: "paused-\(UUID().uuidString)",
            url: url,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-paused.zip"),
            resumeData: Data("paused".utf8),
            lifecycle: .paused
        )
        let retryPending = DownloadTaskPersistence.Record(
            id: "retry-\(UUID().uuidString)",
            url: url,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-retry.zip"),
            lifecycle: .retryPending,
            retryCount: 1,
            totalRetryCount: 1
        )
        let live = StubDownloadURLTask(
            request: URLRequest(url: url),
            initialState: .running
        )
        let harness = try StubDownloadHarness(
            label: "restore-live-legacy-filter",
            prepopulatedRecords: [active, terminal, paused, retryPending],
            preinstalledStubs: [live]
        )

        #expect(await harness.manager.waitForRestoration())
        #expect(live.cancelCount == 0)
        #expect(live.taskDescription == active.id)
        let restored = try #require(await harness.manager.task(withId: active.id))
        #expect(await restored.state == .downloading)
        #expect(await harness.manager.task(withId: terminal.id) == nil)
        #expect(await harness.persistence.record(forID: terminal.id) == nil)
        let restoredPaused = try #require(await harness.manager.task(withId: paused.id))
        #expect(await restoredPaused.state == .paused)
        let restartedRetry = try #require(
            await harness.manager.task(withId: retryPending.id)
        )
        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: restartedRetry
            )
        )
        #expect(await restartedRetry.state == .downloading)
        await harness.manager.shutdown()
    }

    @Test("Restore adopts an existing URL task whose taskDescription matches a persisted id")
    func restoreAdoptsExistingURLTask() async throws {
        let trackedID = "persisted-task-\(UUID().uuidString)"
        let trackedURL = URL(string: "https://example.invalid/persisted.zip")!
        let persistedRecord = DownloadTaskPersistence.Record(
            id: trackedID,
            url: trackedURL,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-persisted.zip")
        )
        let existingStub = StubDownloadURLTask(
            request: URLRequest(url: trackedURL),
            initialState: .running
        )
        existingStub.taskDescription = trackedID

        // Preinstall the existing task on the session so `allDownloadTasks()`
        // surfaces it to the restore coordinator *before* any
        // `makeDownloadTask(...)` call happens. Harness init performs the
        // preinstall before constructing the manager, so the restore task
        // (spawned on manager init) sees the task immediately.
        let harness = try StubDownloadHarness(
            label: "restore-adopt",
            prepopulatedRecords: [persistedRecord],
            preinstalledStubs: [existingStub]
        )

        // First `download()` call waits on the restore barrier, so once it
        // returns we know restore has finished. Issue it against a throwaway
        // URL so the persisted task stays separately registered.
        let probe = await harness.startDownload(
            url: URL(string: "https://example.invalid/probe.zip")!
        )

        let restoredTask = await harness.manager.task(withId: trackedID)
        #expect(restoredTask != nil)
        if let restoredTask {
            #expect(await restoredTask.state == .downloading)
            #expect(restoredTask.url == trackedURL)
        }

        await harness.manager.cancel(probe)
    }

    @Test("Restore resumes one suspended active attempt in place")
    func restoreResumesSuspendedActiveAttemptInPlace() async throws {
        let taskID = "suspended-active-\(UUID().uuidString)"
        let url = URL(string: "https://example.invalid/suspended-active.zip")!
        let record = DownloadTaskPersistence.Record(
            id: taskID,
            url: url,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-suspended.zip"),
            lifecycle: .active
        )
        let existing = StubDownloadURLTask(
            request: URLRequest(url: url),
            initialState: .suspended
        )
        existing.taskDescription = taskID
        let harness = try StubDownloadHarness(
            label: "restore-suspended-active",
            prepopulatedRecords: [record],
            preinstalledStubs: [existing]
        )

        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: taskID))
        #expect(existing.resumeCount == 1)
        #expect(await restored.state == .downloading)
        #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == existing.taskIdentifier)
        #expect(harness.stubSession.createdTasks.isEmpty)

        await harness.manager.resume(restored)
        #expect(existing.resumeCount == 1)
        #expect(harness.stubSession.createdTasks.isEmpty)
        await harness.manager.shutdown()
    }

    @Test("Intermediate pause phases without a system attempt recover as paused")
    func intermediatePausePhasesRecoverWithoutSystemAttempt() async throws {
        for lifecycle in [
            DownloadTaskPersistence.Record.Lifecycle.pausing,
            .resuming,
        ] {
            let taskID = "recover-\(lifecycle.rawValue)-\(UUID().uuidString)"
            let record = DownloadTaskPersistence.Record(
                id: taskID,
                url: URL(string: "https://example.invalid/\(lifecycle.rawValue).zip")!,
                destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip"),
                lifecycle: lifecycle
            )
            let harness = try StubDownloadHarness(
                label: "restore-\(lifecycle.rawValue)-without-system",
                prepopulatedRecords: [record]
            )

            #expect(await harness.manager.waitForRestoration())
            let restored = try #require(await harness.manager.task(withId: taskID))
            #expect(await restored.state == .paused)
            #expect(await harness.persistence.record(forID: taskID)?.lifecycle == .paused)
            #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == nil)
            await harness.manager.shutdown()
        }
    }

    @Test("Persisted pause intent cancels suspended crash residue before one clean resume")
    func persistedPauseIntentCancelsSuspendedResidue() async throws {
        for lifecycle in [
            DownloadTaskPersistence.Record.Lifecycle.pausing,
            .paused,
        ] {
            let taskID = "pause-residue-\(lifecycle.rawValue)-\(UUID().uuidString)"
            let url = URL(string: "https://example.invalid/pause-residue-\(lifecycle.rawValue).zip")!
            let record = DownloadTaskPersistence.Record(
                id: taskID,
                url: url,
                destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip"),
                lifecycle: lifecycle
            )
            let residue = StubDownloadURLTask(
                request: URLRequest(url: url),
                initialState: .suspended
            )
            residue.taskDescription = taskID
            let harness = try StubDownloadHarness(
                label: "restore-pause-residue-\(lifecycle.rawValue)",
                prepopulatedRecords: [record],
                preinstalledStubs: [residue]
            )

            #expect(await harness.manager.waitForRestoration())
            let restored = try #require(await harness.manager.task(withId: taskID))
            #expect(residue.cancelCount == 1)
            #expect(await restored.state == .paused)
            #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == nil)

            await harness.manager.resume(restored)
            #expect(harness.stubSession.createdTasks.count == 1)
            #expect(await restored.state == .downloading)
            await harness.manager.shutdown()
        }
    }

    @Test("A newer foreign taskDescription collision cannot displace a valid attempt")
    func foreignDescriptionCollisionCannotDisplaceValidAttempt() async throws {
        let taskID = "description-collision-\(UUID().uuidString)"
        let validURL = URL(string: "https://example.invalid/valid.zip")!
        let record = DownloadTaskPersistence.Record(
            id: taskID,
            url: validURL,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip"),
            lifecycle: .active
        )
        let valid = StubDownloadURLTask(
            taskIdentifier: 92_001,
            request: URLRequest(url: validURL),
            initialState: .running
        )
        let foreign = StubDownloadURLTask(
            taskIdentifier: 92_002,
            request: URLRequest(url: URL(string: "https://example.invalid/foreign.zip")!),
            initialState: .running
        )
        valid.taskDescription = taskID
        foreign.taskDescription = taskID
        let harness = try StubDownloadHarness(
            label: "restore-description-collision",
            prepopulatedRecords: [record],
            preinstalledStubs: [foreign, valid]
        )

        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: taskID))
        #expect(foreign.cancelCount == 1)
        #expect(valid.cancelCount == 0)
        #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == valid.taskIdentifier)
        await harness.manager.shutdown()
    }

    @Test("Restore adopts a live task after an admitted redirect")
    func restoreAdoptsAdmittedRedirectedAttempt() async throws {
        let taskID = "restored-redirect-\(UUID().uuidString)"
        let source = URL(string: "https://example.invalid/start.zip")!
        let redirected = URL(string: "https://cdn.example.invalid/archive.zip")!
        let record = DownloadTaskPersistence.Record(
            id: taskID,
            url: source,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip"),
            lifecycle: .active
        )
        let live = StubDownloadURLTask(
            request: URLRequest(url: source),
            currentRequest: URLRequest(url: redirected),
            initialState: .running
        )
        live.taskDescription = taskID
        let harness = try StubDownloadHarness(
            label: "restore-admitted-redirect",
            prepopulatedRecords: [record],
            preinstalledStubs: [live]
        )

        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: taskID))
        #expect(await restored.state == .downloading)
        #expect(live.cancelCount == 0)
        #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == live.taskIdentifier)
        await harness.manager.shutdown()
    }

    @Test("Restore barrier unblocks cancel path without state leakage")
    func restoreBarrierUnblocksCancelPath() async throws {
        let harness = try StubDownloadHarness(label: "restore-cancel")

        let task = await harness.startDownload()

        await harness.manager.cancelAll()
        #expect(await harness.manager.allTasks().isEmpty)
        _ = task
    }

    @Test("Missing-system terminal marker survives remove failure before failure publication")
    func removeFailureKeepsTerminalRestoreMarker() async throws {
        let orphanID = "orphan-\(UUID().uuidString)"
        let orphanRecord = DownloadTaskPersistence.Record(
            id: orphanID,
            url: URL(string: "https://example.invalid/orphan.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-orphan.zip")
        )
        let harness = try StubDownloadHarness(
            label: "restore-prune-fail",
            failsRemovesInitially: true,
            prepopulatedRecords: [orphanRecord]
        )

        // Make sure restore has run by issuing a probe and then awaiting the
        // event stream for the orphan task. The first subscription drains the
        // pending-restore queue.
        let probe = await harness.startDownload()
        await harness.manager.cancel(probe)

        let orphanTask = try #require(await harness.manager.task(withId: orphanID))
        #expect(await harness.persistence.record(forID: orphanID)?.lifecycle == .terminal)
        let stream = await harness.manager.events(for: orphanTask)
        var sawFailure = false
        for await event in stream {
            if case .failed(.restorationMissingSystemTask) = event {
                sawFailure = true
                break
            }
        }
        #expect(sawFailure)

        // The marker was written before remove and before publication, so a
        // failed prune can never leave an active orphan that restarts later.
        #expect(await harness.persistence.record(forID: orphanID)?.lifecycle == .terminal)
        await harness.store.setRemoveFailure(false)
        await harness.manager.shutdown()
    }

    @Test("Missing-system seal failure stays unpublished and retains the active row for next launch")
    func sealFailureRetainsActiveRestoreRecord() async throws {
        let orphanID = "orphan-seal-failure-\(UUID().uuidString)"
        let orphanRecord = DownloadTaskPersistence.Record(
            id: orphanID,
            url: URL(string: "https://example.invalid/orphan-seal-failure.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-orphan-seal-failure.zip"),
            lifecycle: .active
        )
        let firstLaunch = try StubDownloadHarness(
            label: "restore-seal-fail-first-launch",
            suspendsAllDownloadTasks: true,
            prepopulatedRecords: [orphanRecord]
        )
        #expect(
            await waitForRestoreCondition {
                firstLaunch.stubSession.pendingAllDownloadTaskQueryCount == 1
            }
        )

        // Restore no longer mutates an active orphan before the FIFO boundary,
        // so injecting the failure while enumeration is suspended precisely
        // targets the post-boundary terminal-marker write.
        let observed = ObservedFailure()
        await firstLaunch.manager.setOnFailedHandler { task, error in
            await observed.record(taskID: task.id, error: error)
        }
        await firstLaunch.store.setUpsertFailure(true)
        firstLaunch.stubSession.completeAllDownloadTasks()

        #expect(await firstLaunch.manager.waitForRestoration())
        #expect(await firstLaunch.manager.task(withId: orphanID) == nil)
        #expect(await firstLaunch.manager.allTasks().contains { $0.id == orphanID } == false)
        let retained = try #require(await firstLaunch.persistence.record(forID: orphanID))
        #expect(retained.lifecycle == .active)
        #expect(await firstLaunch.store.singleRemoveCallCount == 0)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await observed.snapshot().isEmpty)

        // With no public handle remaining in this process, an attempted stream
        // subscription for the durable ID finishes without replaying the
        // synthetic terminal event.
        let inaccessibleHandle = DownloadTask(
            url: retained.url,
            destinationURL: retained.destinationURL,
            id: retained.id
        )
        let unpublishedEvents = await firstLaunch.manager.events(for: inaccessibleHandle)
        var eventIterator = unpublishedEvents.makeAsyncIterator()
        if case .some = await eventIterator.next() {
            Issue.record("The unsealed synthetic failure leaked through an event stream")
        }

        // Model a fresh process by seeding a second manager with the durable row
        // that survived the failed seal. It must be reconciled again rather than
        // having disappeared through an unconditional remove.
        let nextLaunch = try StubDownloadHarness(
            label: "restore-seal-fail-next-launch",
            prepopulatedRecords: [retained]
        )
        #expect(await nextLaunch.manager.waitForRestoration())
        let nextFailure = try #require(await nextLaunch.manager.task(withId: orphanID))
        #expect(await nextFailure.state == .failed)
        guard case .restorationMissingSystemTask? = await nextFailure.error else {
            Issue.record("Expected the retained active row to be reconciled on the next launch")
            await nextLaunch.manager.shutdown()
            await firstLaunch.store.setUpsertFailure(false)
            await firstLaunch.manager.shutdown()
            return
        }
        #expect(await nextLaunch.persistence.record(forID: orphanID) == nil)

        await nextLaunch.manager.shutdown()
        await firstLaunch.store.setUpsertFailure(false)
        await firstLaunch.manager.shutdown()
    }

    @Test("Restore failure replays to onFailed handler when set after restore")
    func restoreFailureReplaysToHandlerSubscriber() async throws {
        let orphanID = "orphan-handler-\(UUID().uuidString)"
        let orphanRecord = DownloadTaskPersistence.Record(
            id: orphanID,
            url: URL(string: "https://example.invalid/orphan-handler.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-orphan-handler.zip")
        )
        let harness = try StubDownloadHarness(
            label: "restore-handler",
            prepopulatedRecords: [orphanRecord]
        )

        // Wait for restore by issuing a probe.
        let probe = await harness.startDownload()
        await harness.manager.cancel(probe)

        let observed = ObservedFailure()
        await harness.manager.setOnFailedHandler { task, error in
            await observed.record(taskID: task.id, error: error)
        }

        // Setting the handler admits the pending failure to the per-task
        // callback queue. Delivery is intentionally asynchronous so user code
        // never holds the restoration actor; wait for that queue boundary.
        let deadline = Date().addingTimeInterval(2)
        var matched = false
        while Date() < deadline, !matched {
            let recorded = await observed.snapshot()
            matched = recorded.contains { taskID, error in
                guard taskID == orphanID else { return false }
                if case .restorationMissingSystemTask = error { return true }
                return false
            }
            if !matched {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(matched)
    }
}

private actor ObservedFailure {
    private var entries: [(String, DownloadError)] = []

    func record(taskID: String, error: DownloadError) {
        entries.append((taskID, error))
    }

    func snapshot() -> [(String, DownloadError)] {
        entries
    }
}

private func waitForRestoreCondition(
    timeout: TimeInterval = 2,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
