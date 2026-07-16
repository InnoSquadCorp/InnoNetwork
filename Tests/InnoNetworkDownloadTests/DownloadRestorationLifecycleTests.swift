import Foundation
import Testing
import os

@testable import InnoNetworkDownload

@Suite("Download restoration lifecycle", .serialized)
struct DownloadRestorationLifecycleTests {
    @Test("A matching staged success completes an active orphan before the restoration boundary")
    func stagedSuccessCompletesMissingSystemTaskInsideBoundary() async throws {
        let fileManager = FileManager.default
        let id = "restored-missing-system-success-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/restored-success.zip")!
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(
            "restored-missing-system-success-\(UUID().uuidString).zip"
        )
        let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
            "restored-missing-system-staged-\(UUID().uuidString).tmp"
        )
        let payload = Data("completed-before-missing-system-boundary".utf8)
        try payload.write(to: stagedURL)
        defer {
            try? fileManager.removeItem(at: stagedURL)
            try? fileManager.removeItem(at: destinationURL)
        }

        let record = DownloadTaskPersistence.Record(
            id: id,
            url: sourceURL,
            destinationURL: destinationURL,
            lifecycle: .active
        )
        let harness = try StubDownloadHarness(
            label: "missing-system-staged-success",
            suspendsAllDownloadTasks: true,
            prepopulatedRecords: [record]
        )
        #expect(
            await waitForLifecycleCondition {
                harness.stubSession.pendingAllDownloadTaskQueryCount == 1
            }
        )

        harness.injectDelegateCompletion(
            taskIdentifier: 8_901,
            taskDescription: id,
            originalRequestURL: sourceURL,
            currentRequestURL: sourceURL,
            usesLastRequestURLs: false,
            location: stagedURL
        )
        harness.stubSession.completeAllDownloadTasks()

        #expect(await harness.manager.waitForRestoration())
        #expect(try Data(contentsOf: destinationURL) == payload)
        #expect(await harness.persistence.record(forID: id) == nil)
        #expect(await harness.manager.task(withId: id) == nil)
        await harness.manager.shutdown()
    }

    @Test("A matching staged error never reopens a missing-system restoration failure")
    func stagedErrorDoesNotReopenMissingSystemTask() async throws {
        let id = "restored-missing-system-error-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/restored-error.zip")!
        let record = DownloadTaskPersistence.Record(
            id: id,
            url: sourceURL,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "restored-missing-system-error-\(UUID().uuidString).zip"
            ),
            lifecycle: .active
        )
        let harness = try StubDownloadHarness(
            label: "missing-system-staged-error",
            suspendsAllDownloadTasks: true,
            prepopulatedRecords: [record]
        )
        #expect(
            await waitForLifecycleCondition {
                harness.stubSession.pendingAllDownloadTaskQueryCount == 1
            }
        )

        harness.injectDelegateCompletion(
            taskIdentifier: 8_902,
            taskDescription: id,
            originalRequestURL: sourceURL,
            currentRequestURL: sourceURL,
            usesLastRequestURLs: false,
            error: SendableUnderlyingError(URLError(.timedOut))
        )
        harness.stubSession.completeAllDownloadTasks()

        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: id))
        #expect(await restored.state == .failed)
        guard case .restorationMissingSystemTask? = await restored.error else {
            Issue.record("The matching transport error replaced restorationMissingSystemTask")
            await harness.manager.shutdown()
            return
        }
        #expect(await restored.retryCount == 0)
        #expect(await restored.totalRetryCount == 0)
        #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == nil)
        #expect(await harness.persistence.record(forID: id) == nil)
        await harness.manager.shutdown()
    }

    @Test("Matching success and error after the restoration boundary are ignored and staged files are removed")
    func postBoundaryCompletionsCannotReopenMissingSystemTask() async throws {
        enum CompletionKind: String {
            case success
            case error
        }

        for kind in [CompletionKind.success, .error] {
            let fileManager = FileManager.default
            let id = "post-boundary-missing-system-\(kind.rawValue)-\(UUID().uuidString)"
            let sourceURL = URL(string: "https://example.invalid/post-boundary-\(kind.rawValue).zip")!
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(
                "post-boundary-destination-\(UUID().uuidString).zip"
            )
            let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
                "post-boundary-staged-\(UUID().uuidString).tmp"
            )
            try Data("late staged payload".utf8).write(to: stagedURL)
            defer {
                try? fileManager.removeItem(at: stagedURL)
                try? fileManager.removeItem(at: destinationURL)
            }

            let record = DownloadTaskPersistence.Record(
                id: id,
                url: sourceURL,
                destinationURL: destinationURL,
                lifecycle: .active
            )
            let harness = try StubDownloadHarness(
                label: "post-boundary-missing-system-\(kind.rawValue)",
                prepopulatedRecords: [record]
            )
            #expect(await harness.manager.waitForRestoration())
            let restored = try #require(await harness.manager.task(withId: id))

            await harness.manager.handleCompletion(
                taskIdentifier: kind == .success ? 8_903 : 8_904,
                taskDescription: id,
                originalRequestURL: sourceURL,
                currentRequestURL: sourceURL,
                location: stagedURL,
                error: kind == .error
                    ? SendableUnderlyingError(URLError(.timedOut))
                    : nil
            )

            #expect(fileManager.fileExists(atPath: stagedURL.path) == false)
            #expect(fileManager.fileExists(atPath: destinationURL.path) == false)
            #expect(await restored.state == .failed)
            guard case .restorationMissingSystemTask? = await restored.error else {
                Issue.record("A post-boundary \(kind.rawValue) rewrote restorationMissingSystemTask")
                await harness.manager.shutdown()
                continue
            }
            #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == nil)
            #expect(await harness.persistence.record(forID: id) == nil)
            await harness.manager.shutdown()
        }
    }

    @Test("A background completion after the task snapshot is admitted until didFinishEvents")
    func backgroundDidFinishEventsIsTheRestorationBoundary() async throws {
        let fileManager = FileManager.default
        let id = "background-official-boundary-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/background-boundary.zip")!
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(
            "background-boundary-destination-\(UUID().uuidString).zip"
        )
        let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
            "background-boundary-staged-\(UUID().uuidString).tmp"
        )
        let payload = Data("arrived-before-did-finish-events".utf8)
        try payload.write(to: stagedURL)
        defer {
            try? fileManager.removeItem(at: stagedURL)
            try? fileManager.removeItem(at: destinationURL)
        }

        let record = DownloadTaskPersistence.Record(
            id: id,
            url: sourceURL,
            destinationURL: destinationURL,
            lifecycle: .active
        )
        let harness = try StubDownloadHarness(
            maxRetryCount: 0,
            backgroundTransfers: true,
            label: "background-official-boundary",
            prepopulatedRecords: [record]
        )
        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: id))
        #expect(await restored.state == .failed)

        let events = RestorationEventRecorder()
        _ = await harness.manager.addEventListener(for: restored) { event in
            await events.record(event)
        }
        #expect(await events.values.isEmpty)

        harness.injectDelegateCompletion(
            taskIdentifier: 9_801,
            taskDescription: id,
            originalRequestURL: sourceURL,
            currentRequestURL: sourceURL,
            usesLastRequestURLs: false,
            location: stagedURL
        )
        harness.injectBackgroundEventsFinished()

        #expect(
            await waitForLifecycleCondition {
                await events.containsCompleted(at: destinationURL)
            }
        )
        #expect(try Data(contentsOf: destinationURL) == payload)
        #expect(await harness.persistence.record(forID: id) == nil)
        await harness.manager.shutdown()
    }

    @Test("A provisional background orphan is published only at didFinishEvents")
    func backgroundFailureWaitsForOfficialBoundary() async throws {
        let id = "background-provisional-failure-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/background-orphan.zip")!
        let record = DownloadTaskPersistence.Record(
            id: id,
            url: sourceURL,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "background-provisional-failure-\(UUID().uuidString).zip"
            ),
            lifecycle: .active
        )
        let harness = try StubDownloadHarness(
            maxRetryCount: 0,
            backgroundTransfers: true,
            label: "background-provisional-failure",
            prepopulatedRecords: [record]
        )
        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: id))
        let events = RestorationEventRecorder()
        _ = await harness.manager.addEventListener(for: restored) { event in
            await events.record(event)
        }
        #expect(await events.values.isEmpty)

        harness.injectBackgroundEventsFinished()

        #expect(
            await waitForLifecycleCondition {
                await events.containsRestorationFailure
            }
        )
        #expect(await harness.persistence.record(forID: id) == nil)
        await harness.manager.shutdown()
    }

    @Test(
        "A staged success wins over a recovered intermediate pause phase",
        arguments: [
            DownloadTaskPersistence.Record.Lifecycle.pausing,
            DownloadTaskPersistence.Record.Lifecycle.resuming,
        ]
    )
    func stagedSuccessCompletesRecoveredIntermediatePause(
        lifecycle: DownloadTaskPersistence.Record.Lifecycle
    ) async throws {
        let id = "restored-intermediate-success-\(lifecycle.rawValue)-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/finished.zip")!
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "restored-intermediate-success-\(UUID().uuidString).zip"
        )
        let stagedURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "restored-intermediate-staged-\(UUID().uuidString).tmp"
        )
        let payload = Data("completed-before-restoration-boundary".utf8)
        try payload.write(to: stagedURL)
        defer {
            try? FileManager.default.removeItem(at: stagedURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }

        let record = DownloadTaskPersistence.Record(
            id: id,
            url: sourceURL,
            destinationURL: destinationURL,
            lifecycle: lifecycle
        )
        let harness = try StubDownloadHarness(
            label: "intermediate-success-\(lifecycle.rawValue)",
            suspendsAllDownloadTasks: true,
            prepopulatedRecords: [record]
        )
        #expect(
            await waitForLifecycleCondition {
                harness.stubSession.pendingAllDownloadTaskQueryCount == 1
            }
        )

        harness.injectDelegateCompletion(
            taskIdentifier: 9_001,
            taskDescription: id,
            originalRequestURL: sourceURL,
            currentRequestURL: sourceURL,
            usesLastRequestURLs: false,
            location: stagedURL
        )
        harness.stubSession.completeAllDownloadTasks()

        #expect(await harness.manager.waitForRestoration())
        #expect(try Data(contentsOf: destinationURL) == payload)
        #expect(await harness.persistence.record(forID: id) == nil)
        #expect(await harness.manager.task(withId: id) == nil)
        await harness.manager.shutdown()
    }

    @Test(
        "A staged cancellation leaves a recovered intermediate pause phase paused",
        arguments: [
            DownloadTaskPersistence.Record.Lifecycle.pausing,
            DownloadTaskPersistence.Record.Lifecycle.resuming,
        ]
    )
    func stagedCancellationPreservesRecoveredPause(
        lifecycle: DownloadTaskPersistence.Record.Lifecycle
    ) async throws {
        let id = "restored-intermediate-cancel-\(lifecycle.rawValue)-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/cancelled-pause.zip")!
        let record = DownloadTaskPersistence.Record(
            id: id,
            url: sourceURL,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "restored-intermediate-cancel-\(UUID().uuidString).zip"
            ),
            lifecycle: lifecycle
        )
        let harness = try StubDownloadHarness(
            label: "intermediate-cancel-\(lifecycle.rawValue)",
            suspendsAllDownloadTasks: true,
            prepopulatedRecords: [record]
        )
        #expect(
            await waitForLifecycleCondition {
                harness.stubSession.pendingAllDownloadTaskQueryCount == 1
            }
        )

        harness.injectDelegateCompletion(
            taskIdentifier: 9_002,
            taskDescription: id,
            originalRequestURL: sourceURL,
            currentRequestURL: sourceURL,
            usesLastRequestURLs: false,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.cancelled.rawValue,
                message: "pause cancellation"
            )
        )
        harness.stubSession.completeAllDownloadTasks()

        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: id))
        #expect(await restored.state == .paused)
        #expect(await harness.persistence.record(forID: id)?.lifecycle == .paused)
        #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == nil)
        await harness.manager.shutdown()
    }

    @Test(
        "A late staged success cannot reopen an intermediate pause after the restoration boundary",
        arguments: [
            DownloadTaskPersistence.Record.Lifecycle.pausing,
            DownloadTaskPersistence.Record.Lifecycle.resuming,
        ]
    )
    func lateStagedSuccessCannotReopenRecoveredPause(
        lifecycle: DownloadTaskPersistence.Record.Lifecycle
    ) async throws {
        let fileManager = FileManager.default
        let id = "late-restored-success-\(lifecycle.rawValue)-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/late-finished.zip")!
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(
            "late-restored-success-\(UUID().uuidString).zip"
        )
        let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
            "late-restored-staged-\(UUID().uuidString).tmp"
        )
        try Data("arrived-after-restoration-boundary".utf8).write(to: stagedURL)
        defer {
            try? fileManager.removeItem(at: stagedURL)
            try? fileManager.removeItem(at: destinationURL)
        }

        let record = DownloadTaskPersistence.Record(
            id: id,
            url: sourceURL,
            destinationURL: destinationURL,
            lifecycle: lifecycle
        )
        let harness = try StubDownloadHarness(
            label: "late-intermediate-success-\(lifecycle.rawValue)",
            prepopulatedRecords: [record]
        )

        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: id))
        #expect(await restored.state == .paused)
        #expect(await harness.persistence.record(forID: id)?.lifecycle == .paused)

        harness.injectDelegateCompletion(
            taskIdentifier: 9_100,
            taskDescription: id,
            originalRequestURL: sourceURL,
            currentRequestURL: sourceURL,
            usesLastRequestURLs: false,
            location: stagedURL
        )

        #expect(
            await waitForLifecycleCondition {
                !FileManager.default.fileExists(atPath: stagedURL.path)
            }
        )
        #expect(fileManager.fileExists(atPath: destinationURL.path) == false)
        #expect(await restored.state == .paused)
        #expect(await harness.persistence.record(forID: id)?.lifecycle == .paused)
        #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == nil)

        await harness.manager.shutdown()
    }

    @Test(
        "Uncorrelated staged success cannot consume intermediate-pause restoration admission",
        arguments: [
            DownloadTaskPersistence.Record.Lifecycle.pausing,
            DownloadTaskPersistence.Record.Lifecycle.resuming,
        ]
    )
    func uncorrelatedSuccessPreservesRecoveredPauseAdmission(
        lifecycle: DownloadTaskPersistence.Record.Lifecycle
    ) async throws {
        enum CorrelationCase: String {
            case foreign
            case missing
        }

        for correlationCase in [CorrelationCase.foreign, .missing] {
            let fileManager = FileManager.default
            let id = "uncorrelated-success-\(lifecycle.rawValue)-\(correlationCase.rawValue)-\(UUID().uuidString)"
            let sourceURL = URL(string: "https://example.invalid/source.zip")!
            let foreignURL = URL(string: "https://foreign.example.invalid/payload.zip")!
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(
                "uncorrelated-destination-\(UUID().uuidString).zip"
            )
            let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
                "uncorrelated-staged-\(UUID().uuidString).tmp"
            )
            try Data("uncorrelated-restoration-payload".utf8).write(to: stagedURL)
            defer {
                try? fileManager.removeItem(at: stagedURL)
                try? fileManager.removeItem(at: destinationURL)
            }

            let record = DownloadTaskPersistence.Record(
                id: id,
                url: sourceURL,
                destinationURL: destinationURL,
                lifecycle: lifecycle
            )
            let harness = try StubDownloadHarness(
                label: "uncorrelated-\(lifecycle.rawValue)-\(correlationCase.rawValue)",
                suspendsAllDownloadTasks: true,
                prepopulatedRecords: [record]
            )
            #expect(
                await waitForLifecycleCondition {
                    harness.stubSession.pendingAllDownloadTaskQueryCount == 1
                }
            )

            let completionURL: URL? = correlationCase == .foreign ? foreignURL : nil
            harness.injectDelegateCompletion(
                taskIdentifier: 9_200,
                taskDescription: id,
                originalRequestURL: completionURL,
                currentRequestURL: completionURL,
                usesLastRequestURLs: false,
                location: stagedURL
            )
            harness.stubSession.completeAllDownloadTasks()

            #expect(await harness.manager.waitForRestoration())
            let restored = try #require(await harness.manager.task(withId: id))
            #expect(await restored.state == .paused)
            #expect(await harness.persistence.record(forID: id)?.lifecycle == .paused)
            #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == nil)
            #expect(fileManager.fileExists(atPath: stagedURL.path) == false)
            #expect(fileManager.fileExists(atPath: destinationURL.path) == false)
            await harness.manager.shutdown()
        }
    }

    @Test("An uncorrelated error cannot rewrite a missing-system restoration failure")
    func uncorrelatedErrorPreservesMissingSystemFailure() async throws {
        let id = "uncorrelated-error-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/source.zip")!
        let record = DownloadTaskPersistence.Record(
            id: id,
            url: sourceURL,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "uncorrelated-error-\(UUID().uuidString).zip"
            ),
            lifecycle: .active
        )
        let harness = try StubDownloadHarness(
            label: "uncorrelated-error",
            prepopulatedRecords: [record]
        )

        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: id))
        guard case .restorationMissingSystemTask? = await restored.error else {
            Issue.record("Expected the active orphan to retain its restoration failure")
            await harness.manager.shutdown()
            return
        }

        let foreignURL = URL(string: "https://foreign.example.invalid/source.zip")!
        await harness.manager.handleCompletion(
            taskIdentifier: 9_201,
            taskDescription: id,
            originalRequestURL: foreignURL,
            currentRequestURL: foreignURL,
            location: nil,
            error: SendableUnderlyingError(URLError(.timedOut))
        )

        #expect(await restored.state == .failed)
        guard case .restorationMissingSystemTask? = await restored.error else {
            Issue.record("The uncorrelated error rewrote restorationMissingSystemTask")
            await harness.manager.shutdown()
            return
        }
        #expect(await harness.manager.runtimeTaskIdentifier(for: restored) == nil)
        await harness.manager.shutdown()
    }

    @Test("Shutdown cancels a suspended restoration query and releases waiting callers")
    func shutdownCancelsSuspendedRestoration() async throws {
        let strandedRecord = DownloadTaskPersistence.Record(
            id: "shutdown-stranded-restore-\(UUID().uuidString)",
            url: URL(string: "https://example.invalid/stranded.zip")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "stranded-\(UUID().uuidString).zip"
            ),
            resumeData: Data("stranded-resume-data".utf8)
        )
        let harness = try StubDownloadHarness(
            label: "shutdown-suspended-restoration",
            suspendsAllDownloadTasks: true,
            prepopulatedRecords: [strandedRecord]
        )

        #expect(
            await waitForLifecycleCondition {
                harness.stubSession.pendingAllDownloadTaskQueryCount == 1
            }
        )

        let pendingDownload = Task {
            await harness.manager.download(
                url: URL(string: "https://example.invalid/waiting.zip")!,
                to: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "waiting-\(UUID().uuidString).zip"
                )
            )
        }
        await Task.yield()

        let shutdownProbe = DownloadLifecycleProbe()
        let shutdownTask = Task {
            await harness.manager.shutdown()
            await shutdownProbe.markCompleted()
        }

        let shutdownCompleted = await waitForLifecycleCondition {
            await shutdownProbe.isCompleted
        }
        if !shutdownCompleted {
            Issue.record("shutdown() remained suspended behind allDownloadTasks()")
            // Ensure a failing implementation can still unwind instead of
            // wedging the remainder of the test process.
            harness.stubSession.completeAllDownloadTasks()
        }

        await shutdownTask.value
        _ = await pendingDownload.value

        #expect(shutdownCompleted)
        #expect(harness.stubSession.didInvalidateAndCancel)
        #expect(harness.stubSession.createdTasks.isEmpty)
        #expect(harness.stubSession.lastURL == nil)
        #expect(await harness.manager.waitForRestoration() == false)
        #expect(await harness.manager.allTasks().isEmpty)
        #expect(await harness.persistence.record(forID: strandedRecord.id) == nil)
    }

    @Test("Shutdown seals an active orphan when restoration is cancelled before the boundary")
    func shutdownSealsActiveOrphanDuringRestorationCancellation() async throws {
        let orphan = DownloadTaskPersistence.Record(
            id: "shutdown-active-orphan-\(UUID().uuidString)",
            url: URL(string: "https://example.invalid/shutdown-active-orphan.zip")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "shutdown-active-orphan-\(UUID().uuidString).zip"
            ),
            lifecycle: .active
        )
        let harness = try StubDownloadHarness(
            label: "shutdown-active-orphan",
            suspendsAllDownloadTasks: true,
            failsRemovesInitially: true,
            prepopulatedRecords: [orphan]
        )
        #expect(
            await waitForLifecycleCondition {
                harness.stubSession.pendingAllDownloadTaskQueryCount == 1
            }
        )

        await harness.manager.shutdown()

        #expect(harness.stubSession.didInvalidateAndCancel)
        #expect(await harness.manager.allTasks().isEmpty)
        // Removal was deliberately failed. The shutdown sweep must still
        // replace the active row with an absorbing terminal marker.
        #expect(await harness.persistence.record(forID: orphan.id)?.lifecycle == .terminal)
    }

    @Test("Opaque resume task with a foreign URL is cancelled before safe fresh restart")
    func foreignResumeTaskFallsBackToPersistedURL() async throws {
        let expectedURL = URL(string: "https://downloads.example.invalid/archive.zip")!
        let foreignURL = URL(string: "https://attacker.example.invalid/archive.zip")!
        let resumeData = Data("opaque-resume-data".utf8)
        let foreignTask = StubDownloadURLTask(
            request: URLRequest(url: foreignURL),
            currentRequest: URLRequest(url: foreignURL)
        )
        let safeFreshTask = StubDownloadURLTask(
            request: URLRequest(url: expectedURL),
            currentRequest: URLRequest(url: expectedURL)
        )
        let harness = try StubDownloadHarness(
            label: "foreign-resume-task",
            prequeuedStubs: [foreignTask, safeFreshTask]
        )
        harness.stubTask.scriptCancelResumeData(resumeData)

        let logicalTask = await harness.startDownload(url: expectedURL)
        await harness.manager.pause(logicalTask)
        #expect(await logicalTask.state == .paused)
        #expect(await logicalTask.resumeData == resumeData)

        await harness.manager.resume(logicalTask)

        #expect(foreignTask.cancelCount == 1)
        #expect(foreignTask.resumeCount == 0)
        #expect(safeFreshTask.resumeCount == 1)
        #expect(harness.stubSession.lastResumeData == resumeData)
        #expect(harness.stubSession.lastURL == expectedURL)
        #expect(await logicalTask.state == .downloading)
        #expect(await logicalTask.resumeData == nil)
        #expect(
            await harness.manager.runtimeTaskIdentifier(for: logicalTask)
                == safeFreshTask.taskIdentifier
        )
        #expect(await harness.persistence.record(forID: logicalTask.id)?.resumeData == nil)

        await harness.manager.shutdown()
    }

    @Test("Opaque resume task without retained requests is cancelled before safe fresh restart")
    func requestlessResumeTaskFallsBackToPersistedURL() async throws {
        let expectedURL = URL(string: "https://downloads.example.invalid/requestless.zip")!
        let resumeData = Data("requestless-resume-data".utf8)
        let requestlessTask = StubDownloadURLTask(
            request: nil,
            currentRequest: nil
        )
        let safeFreshTask = StubDownloadURLTask(
            request: URLRequest(url: expectedURL),
            currentRequest: URLRequest(url: expectedURL)
        )
        let harness = try StubDownloadHarness(
            label: "requestless-resume-task",
            prequeuedStubs: [requestlessTask, safeFreshTask]
        )
        harness.stubTask.scriptCancelResumeData(resumeData)

        let logicalTask = await harness.startDownload(url: expectedURL)
        await harness.manager.pause(logicalTask)
        await harness.manager.resume(logicalTask)

        #expect(requestlessTask.cancelCount == 1)
        #expect(requestlessTask.resumeCount == 0)
        #expect(safeFreshTask.resumeCount == 1)
        #expect(harness.stubSession.lastURL == expectedURL)
        #expect(await logicalTask.state == .downloading)
        #expect(await logicalTask.resumeData == nil)

        await harness.manager.shutdown()
    }

    @Test("Restore rejects foreign, unsafe, or missing current requests without adopting the system task")
    func restoreRejectsMismatchedOrUnadmittedCurrentRequest() async throws {
        let currentRequests: [URLRequest?] = [
            URLRequest(url: URL(string: "https://other.example.invalid/archive.zip")!),
            URLRequest(url: URL(string: "http://downloads.example.invalid/archive.zip")!),
            nil,
        ]

        for (index, currentRequest) in currentRequests.enumerated() {
            let taskID = "unsafe-current-\(index)-\(UUID().uuidString)"
            let expectedURL = URL(string: "https://downloads.example.invalid/archive.zip")!
            let resumeData = Data("persisted-safe-resume-\(index)".utf8)
            let record = DownloadTaskPersistence.Record(
                id: taskID,
                url: expectedURL,
                destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "restore-current-\(index)-\(UUID().uuidString).zip"
                ),
                resumeData: resumeData
            )
            let systemTask = StubDownloadURLTask(
                request: URLRequest(url: expectedURL),
                currentRequest: currentRequest,
                initialState: .running
            )
            systemTask.taskDescription = taskID
            let harness = try StubDownloadHarness(
                label: "unsafe-current-\(index)",
                prepopulatedRecords: [record],
                preinstalledStubs: [systemTask]
            )

            #expect(await harness.manager.waitForRestoration())
            #expect(systemTask.cancelCount == 1)

            let restoredTask = try #require(await harness.manager.task(withId: taskID))
            #expect(await restoredTask.state == .paused)
            #expect(await restoredTask.resumeData == resumeData)
            #expect(await harness.manager.runtimeTaskIdentifier(for: restoredTask) == nil)
            #expect(await harness.persistence.record(forID: taskID) != nil)

            await harness.manager.shutdown()
        }
    }

    @Test("A finish without a handler is not carried into the next background batch")
    func backgroundCompletionIsScopedToRegisteredBatch() throws {
        let store = BackgroundCompletionStore()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        // An unscoped finish from ordinary app activity must be discarded.
        #expect(store.take().map { _ in true } == nil)
        store.set {
            callCount.withLock { $0 += 1 }
        }
        #expect(callCount.withLock { $0 } == 0)

        // Only the next finish event paired with this registered UIKit batch
        // may consume and invoke the handler.
        let completion = try #require(store.take())
        completion()
        #expect(callCount.withLock { $0 } == 1)
        #expect(store.take().map { _ in true } == nil)
    }
}

private actor RestorationEventRecorder {
    private(set) var values: [DownloadEvent] = []

    func record(_ event: DownloadEvent) {
        values.append(event)
    }

    func containsCompleted(at location: URL) -> Bool {
        values.contains { event in
            guard case .completed(let observedLocation) = event else { return false }
            return observedLocation == location
        }
    }

    var containsRestorationFailure: Bool {
        values.contains { event in
            guard case .failed(.restorationMissingSystemTask) = event else { return false }
            return true
        }
    }
}


private actor DownloadLifecycleProbe {
    private var completed = false

    var isCompleted: Bool { completed }

    func markCompleted() {
        completed = true
    }
}


private func waitForLifecycleCondition(
    timeout: Duration = .seconds(2),
    predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}
