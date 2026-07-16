import Foundation
import Testing

@testable import InnoNetwork
@testable import InnoNetworkDownload

@Suite("Download Manager Hardening Tests")
struct DownloadManagerHardeningTests {

    @Test("A manager ignores a DownloadTask owned by another manager")
    func managerRejectsForeignTaskHandles() async throws {
        let owner = try StubDownloadHarness(label: "ownership-owner")
        let foreign = try StubDownloadHarness(label: "ownership-foreign")
        let task = await owner.startDownload()
        let originalIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: owner.manager, task: task)
        )

        await foreign.manager.pause(task)
        await foreign.manager.resume(task)
        await foreign.manager.retry(task)
        await foreign.manager.cancel(task)
        let stream = await foreign.manager.events(for: task)
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == nil)
        #expect(await task.state == .downloading)
        #expect(await owner.manager.runtimeTaskIdentifier(for: task) == originalIdentifier)
        #expect(await foreign.manager.task(withId: task.id) == nil)

        await owner.manager.cancel(task)
        await owner.manager.shutdown()
        await foreign.manager.shutdown()
    }

    @Test("shutdown() invalidates the URLSession and cancels in-flight tasks")
    func shutdownCancelsInFlightAndInvalidates() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-cancel")
        let task = await harness.startDownload()

        await harness.manager.shutdown()

        #expect(harness.stubSession.didInvalidateAndCancel)
        // After shutdown, the in-flight stub task receives a cancel call so
        // the URLSession can drain.
        #expect(harness.stubTask.cancelCount >= 1)
        #expect(await harness.store.record(forID: task.id) == nil)
    }

    @Test("shutdown() is idempotent")
    func shutdownIsIdempotent() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-idem")
        _ = await harness.startDownload()
        await harness.manager.shutdown()
        // Second call is a no-op — must not re-invalidate or trap.
        await harness.manager.shutdown()
        #expect(harness.stubSession.didInvalidateAndCancel)
    }

    @Test("shutdown() finishes the per-task event stream so listeners observe end-of-stream")
    func shutdownFinishesEventStream() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-events")
        let task = await harness.startDownload()
        let stream = await harness.manager.events(for: task)

        await harness.manager.shutdown()

        // Drain the stream — once shutdown finishes the partition the
        // iterator returns nil rather than hanging. The for-await terminating
        // is the assertion: a regression where shutdown leaves the stream
        // open would cause the test to hang and then time out.
        var observed = 0
        for await _ in stream {
            observed += 1
            if observed > 100 { break }
        }
        #expect(observed <= 100)
    }

    @Test("shutdown() waits for URLSession invalidation before returning")
    func shutdownWaitsForInvalidationCallback() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-barrier")
        harness.stubSession.setAutomaticallyCompletesInvalidation(false)
        let probe = ShutdownCompletionProbe()

        let shutdownTask = Task {
            await harness.manager.shutdown()
            await probe.markCompleted()
        }

        #expect(await waitForCondition { harness.stubSession.didInvalidateAndCancel })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await probe.isCompleted == false)

        harness.stubSession.completeInvalidation()
        await shutdownTask.value
        #expect(await probe.isCompleted)
    }

    @Test("shutdown() waits for an in-progress delegate handler")
    func shutdownWaitsForInProgressDelegateHandler() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-delegate-drain")
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        let delegateProbe = DelegateDrainProbe()
        let shutdownProbe = ShutdownCompletionProbe()

        await harness.manager.setOnProgressHandler { _, _ in
            await delegateProbe.handle()
        }

        harness.injectDelegateProgress(
            taskIdentifier: taskIdentifier,
            bytesWritten: 1,
            totalBytesWritten: 1,
            totalBytesExpectedToWrite: 10
        )
        #expect(await waitForCondition { await delegateProbe.isStarted })

        let shutdownTask = Task {
            await harness.manager.shutdown()
            await shutdownProbe.markCompleted()
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await shutdownProbe.isCompleted == false)
        #expect(await delegateProbe.isFinished == false)

        await delegateProbe.release()
        await shutdownTask.value
        #expect(await delegateProbe.isFinished)
        #expect(await shutdownProbe.isCompleted)
    }

    @Test("Terminal failure admission does not hold background completion behind app callbacks")
    func terminalFailureAdmissionDoesNotBlockBackgroundCompletion() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 0,
            backgroundTransfers: true,
            label: "failure-admission-background"
        )
        let task = await harness.startDownload()
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        let callbackProbe = DelegateDrainProbe()
        let completionProbe = ShutdownCompletionProbe()

        await harness.manager.setOnFailedHandler { _, _ in
            await callbackProbe.handle()
        }
        harness.handleBackgroundSessionCompletion {
            Task { await completionProbe.markCompleted() }
        }

        harness.injectDelegateCompletion(
            taskIdentifier: identifier,
            error: SendableUnderlyingError(URLError(.timedOut))
        )
        harness.injectBackgroundEventsFinished()

        #expect(await waitForCondition { await callbackProbe.isStarted })
        #expect(await waitForCondition { await completionProbe.isCompleted })
        #expect(await task.state == .failed)
        #expect(await harness.persistence.record(forID: task.id) == nil)
        #expect(await callbackProbe.isFinished == false)

        await callbackProbe.release()
        await harness.manager.shutdown()
    }

    @Test("a failure callback can retry through nested waiting and downloading callbacks")
    func failureCallbackRetryDoesNotSelfDeadlock() async throws {
        let retryStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            maxRetryCount: 0,
            maxTotalRetries: 1,
            label: "failure-callback-retry",
            prequeuedStubs: [retryStub]
        )
        let task = await harness.startDownload()
        let firstIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        let states = DownloadStateRecorder()
        let retryReturned = ShutdownCompletionProbe()

        await harness.manager.setOnStateChangedHandler { _, state in
            await states.record(state)
        }
        await harness.manager.setOnFailedHandler { failedTask, _ in
            await harness.manager.retry(failedTask)
            await retryReturned.markCompleted()
        }

        harness.injectDelegateCompletion(
            taskIdentifier: firstIdentifier,
            error: SendableUnderlyingError(URLError(.networkConnectionLost))
        )

        #expect(
            await waitForCondition(timeout: 2.0) {
                guard await retryReturned.isCompleted else { return false }
                return await harness.manager.runtimeTaskIdentifier(for: task)
                    == retryStub.taskIdentifier
            }
        )
        #expect(await states.snapshot() == [.failed, .waiting, .downloading])
        #expect(await task.state == .downloading)
        #expect(retryStub.resumeCount == 1)

        await harness.manager.cancel(task)
        await harness.manager.shutdown()
    }

    @Test("shutdown waits for admitted persistence work and prevents a late URL task start")
    func shutdownPreventsLateStartAfterSuspendedUpsert() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-upsert-race")
        await harness.store.suspendUpserts()

        let downloadWork = Task {
            await harness.startDownload()
        }
        let reachedUpsert = await waitForCondition {
            await harness.store.pendingUpsertCount == 1
        }
        #expect(reachedUpsert)

        let shutdownProbe = ShutdownCompletionProbe()
        let shutdownWork = Task {
            await harness.manager.shutdown()
            await shutdownProbe.markCompleted()
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await shutdownProbe.isCompleted == false)
        #expect(harness.stubSession.didInvalidateAndCancel == false)

        await harness.store.resumeUpserts()
        let task = await downloadWork.value
        await shutdownWork.value

        #expect(await task.state == .cancelled)
        #expect(harness.stubSession.createdTasks.isEmpty)
        #expect(harness.stubSession.didInvalidateAndCancel)
        #expect(await shutdownProbe.isCompleted)
    }

    @Test("shutdown is not held hostage by a suspended pause resume-data callback")
    func shutdownEscapesSuspendedPauseCallback() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-suspended-pause")
        let task = await harness.startDownload()
        harness.stubTask.suspendCancelByProducingResumeData()

        let pauseWork = Task {
            await harness.manager.pause(task)
        }
        #expect(
            await waitForCondition {
                harness.stubTask.pendingCancelByProducingResumeDataCount == 1
            }
        )

        let shutdownProbe = ShutdownCompletionProbe()
        let shutdownWork = Task {
            await harness.manager.shutdown()
            await shutdownProbe.markCompleted()
        }

        let completedWithoutResumeData = await waitForCondition(timeout: 2.0) {
            await shutdownProbe.isCompleted
        }
        #expect(completedWithoutResumeData)
        #expect(harness.stubSession.didInvalidateAndCancel)
        #expect(await task.state == .cancelled)

        // Release the deliberately non-cooperative operation task so the test
        // leaves no suspended continuation behind.
        harness.stubTask.completeCancelByProducingResumeData(with: nil)
        await pauseWork.value
        await shutdownWork.value
    }

    @Test("cancel wins while resume is suspended in persistence without resurrecting work")
    func cancelWinsSuspendedResumeUpsert() async throws {
        let harness = try StubDownloadHarness(label: "cancel-resume-upsert-race")
        let resumeData = Data("resume-upsert-race".utf8)
        harness.stubTask.scriptCancelResumeData(resumeData)
        let task = await harness.startDownload()
        await harness.manager.pause(task)
        #expect(await task.state == .paused)

        await harness.store.suspendUpserts()
        let resumeWork = Task {
            await harness.manager.resume(task)
        }
        #expect(
            await waitForCondition {
                await harness.store.pendingUpsertCount == 1
            }
        )

        await harness.manager.cancel(task)
        await harness.store.resumeUpserts()
        await resumeWork.value

        #expect(await task.state == .cancelled)
        #expect(harness.stubSession.createdTasks.count == 1)
        #expect(harness.stubSession.lastResumeData == nil)
        #expect(await harness.persistence.record(forID: task.id) == nil)
        await harness.manager.shutdown()
    }

    @Test("shutdown escapes a retry monitor that ignores task cancellation")
    func shutdownEscapesUncooperativeRetryMonitor() async throws {
        let monitor = SuspendedDownloadNetworkMonitor()
        let harness = try StubDownloadHarness(
            maxRetryCount: 1,
            maxTotalRetries: 1,
            networkMonitor: monitor,
            waitsForNetworkChanges: true,
            networkChangeTimeout: nil,
            label: "shutdown-retry-monitor"
        )
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        let completionWork = Task {
            await harness.injectCompletion(
                taskIdentifier: taskIdentifier,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "network lost"
                )
            )
        }
        #expect(
            await waitForCondition {
                await monitor.waitForChangeCallCount == 1
            }
        )

        let shutdownProbe = ShutdownCompletionProbe()
        let shutdownWork = Task {
            await harness.manager.shutdown()
            await shutdownProbe.markCompleted()
        }
        #expect(
            await waitForCondition(timeout: 2.0) {
                await shutdownProbe.isCompleted
            }
        )
        #expect(harness.stubSession.didInvalidateAndCancel)

        await monitor.release()
        await completionWork.value
        await shutdownWork.value
    }

    @Test("a waiting callback can cancel without startDownload resurrecting the task")
    func waitingCallbackCancellationWinsStart() async throws {
        let harness = try StubDownloadHarness(label: "waiting-callback-cancel")
        await harness.manager.setOnStateChangedHandler { task, state in
            guard state == .waiting else { return }
            await harness.manager.cancel(task)
        }

        let task = await harness.startDownload()

        #expect(await task.state == .cancelled)
        #expect(harness.stubSession.createdTasks.isEmpty)
        #expect(await harness.persistence.record(forID: task.id) == nil)
        await harness.manager.shutdown()
    }

    @Test("a downloading callback can cancel before the URL task is resumed")
    func downloadingCallbackCancellationWinsResume() async throws {
        let harness = try StubDownloadHarness(label: "downloading-callback-cancel")
        await harness.manager.setOnStateChangedHandler { task, state in
            guard state == .downloading else { return }
            await harness.manager.cancel(task)
        }

        let task = await harness.startDownload()

        #expect(await task.state == .cancelled)
        #expect(harness.stubTask.resumeCount == 0)
        #expect(harness.stubTask.cancelCount >= 1)
        #expect(await harness.persistence.record(forID: task.id) == nil)
        await harness.manager.shutdown()
    }

    @Test("shutdown() drains a staged completion buffered behind an in-progress delegate handler")
    func shutdownDrainsBufferedStagedCompletion() async throws {
        let fileManager = FileManager.default
        let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
            "download-shutdown-buffered-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try Data("buffered-completion".utf8).write(to: stagedURL)
        defer { try? fileManager.removeItem(at: stagedURL) }

        let harness = try StubDownloadHarness(label: "shutdown-buffered-completion")
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        let delegateProbe = DelegateDrainProbe()
        await harness.manager.setOnProgressHandler { _, _ in
            await delegateProbe.handle()
        }

        harness.injectDelegateProgress(
            taskIdentifier: taskIdentifier,
            bytesWritten: 1,
            totalBytesWritten: 1,
            totalBytesExpectedToWrite: 10
        )
        #expect(await waitForCondition { await delegateProbe.isStarted })

        // This completion is queued behind the blocked progress callback.
        // Its unknown task id makes the expected drain action unambiguously
        // file cleanup rather than a transfer state transition.
        harness.injectDelegateCompletion(taskIdentifier: Int.max, location: stagedURL)
        let shutdownTask = Task {
            await harness.manager.shutdown()
        }
        #expect(await waitForCondition { harness.stubSession.didInvalidateAndCancel })

        await delegateProbe.release()
        await shutdownTask.value

        #expect(fileManager.fileExists(atPath: stagedURL.path) == false)
    }

    @Test("concurrent shutdown() calls all wait for URLSession invalidation")
    func concurrentShutdownCallsWaitForInvalidationCallback() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-concurrent-barrier")
        harness.stubSession.setAutomaticallyCompletesInvalidation(false)
        let firstProbe = ShutdownCompletionProbe()
        let secondProbe = ShutdownCompletionProbe()

        let firstShutdown = Task {
            await firstProbe.markStarted()
            await harness.manager.shutdown()
            await firstProbe.markCompleted()
        }

        #expect(await waitForCondition { harness.stubSession.didInvalidateAndCancel })

        let secondShutdown = Task {
            await secondProbe.markStarted()
            await harness.manager.shutdown()
            await secondProbe.markCompleted()
        }

        #expect(await waitForCondition { await secondProbe.isStarted })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await firstProbe.isCompleted == false)
        #expect(await secondProbe.isCompleted == false)

        harness.stubSession.completeInvalidation()
        await firstShutdown.value
        await secondShutdown.value
        #expect(await firstProbe.isCompleted)
        #expect(await secondProbe.isCompleted)
    }

    @Test("a cancellation callback can reenter shutdown without self-waiting")
    func cancellationCallbackCanReenterShutdown() async throws {
        let harness = try StubDownloadHarness(label: "shutdown-callback-reentrant")
        _ = await harness.startDownload()
        let callbackProbe = ShutdownCompletionProbe()

        await harness.manager.setOnStateChangedHandler { _, state in
            guard state == .cancelled else { return }
            await harness.manager.shutdown()
            await callbackProbe.markCompleted()
        }

        let externalShutdown = Task {
            await harness.manager.shutdown()
        }
        let completed = await waitForCondition(timeout: 2.0) {
            await callbackProbe.isCompleted && harness.stubSession.didInvalidateAndCancel
        }
        #expect(completed)
        if completed {
            await externalShutdown.value
        } else {
            externalShutdown.cancel()
        }
    }

    @Test("a restoration failure callback can initiate shutdown without restoration self-join")
    func restorationCallbackCanInitiateShutdown() async throws {
        let record = DownloadTaskPersistence.Record(
            id: "restore-callback-reentrant",
            url: URL(string: "https://example.invalid/missing.zip")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let harness = try StubDownloadHarness(
            label: "restore-callback-reentrant",
            suspendsAllDownloadTasks: true,
            prepopulatedRecords: [record]
        )
        let callbackProbe = ShutdownCompletionProbe()

        await harness.manager.setOnStateChangedHandler { _, state in
            guard state == .failed else { return }
            await harness.manager.shutdown()
            await callbackProbe.markCompleted()
        }
        #expect(
            await waitForCondition {
                harness.stubSession.pendingAllDownloadTaskQueryCount == 1
            }
        )

        harness.stubSession.completeAllDownloadTasks()
        let callbackReturned = await waitForCondition(timeout: 2.0) {
            await callbackProbe.isCompleted
        }
        #expect(callbackReturned)
        if callbackReturned {
            await harness.manager.shutdown()
            #expect(harness.stubSession.didInvalidateAndCancel)
        }
    }

    @Test("shutdown() releases the session identifier before returning")
    func shutdownAllowsImmediateSessionIdentifierReuse() async throws {
        let first = try StubDownloadHarness(label: "shutdown-reuse")
        let identifier = first.sessionIdentifier

        await first.manager.shutdown()

        let second = try StubDownloadHarness(
            label: "shutdown-reuse-second",
            sessionIdentifier: identifier
        )
        await second.manager.shutdown()
    }

    @Test("directory downloads preserve safe single-component filenames")
    func directoryDownloadPreservesSafeFileName() async throws {
        let harness = try StubDownloadHarness(label: "safe-filename")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = await harness.manager.download(
            url: URL(string: "https://example.invalid/archive.zip")!,
            toDirectory: directory,
            fileName: " archive.zip "
        )

        #expect(task.destinationURL == directory.appendingPathComponent("archive.zip", isDirectory: false))
        await harness.manager.shutdown()
    }

    @Test("Download source admission rejects insecure and ambiguous URLs before URLSession")
    func downloadURLAdmissionRejectsBeforeTransport() async throws {
        let rejectedURLs = [
            URL(string: "http://example.invalid/archive.zip")!,
            URL(string: "https://user:secret@example.invalid/archive.zip")!,
            URL(string: "https://example.invalid/a/%2e%2e/archive.zip")!,
            URL(string: "https://example.invalid/archive.zip#fragment")!,
        ]

        for (index, url) in rejectedURLs.enumerated() {
            let harness = try StubDownloadHarness(label: "url-admission-\(index)")
            let task = await harness.manager.download(
                url: url,
                to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            )

            #expect(await task.state == .failed)
            guard case .invalidURL(let reason) = await task.error else {
                Issue.record("Expected a sanitized invalidURL failure")
                await harness.manager.shutdown()
                continue
            }
            #expect(reason == "Rejected by URL admission policy")
            #expect(harness.stubSession.lastURL == nil)
            #expect(harness.stubSession.createdTasks.isEmpty)
            await harness.manager.shutdown()
        }
    }

    @Test("Download configuration can explicitly opt into plain HTTP")
    func downloadHTTPOptIn() async throws {
        let harness = try StubDownloadHarness(allowsInsecureHTTP: true, label: "http-opt-in")
        let url = URL(string: "http://localhost/archive.zip")!
        let task = await harness.manager.download(
            url: url,
            to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        #expect(await task.state == .downloading)
        #expect(harness.stubSession.lastURL == url)
        #expect(harness.stubSession.createdTasks.count == 1)
        await harness.manager.shutdown()
    }

    @Test("Rejected download tasks cannot bypass URL admission through retry")
    func rejectedDownloadRetryRemainsTransportFree() async throws {
        let harness = try StubDownloadHarness(label: "rejected-retry")
        let task = await harness.manager.download(
            url: URL(string: "http://example.invalid/archive.zip")!,
            to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        await harness.manager.retry(task)

        #expect(await task.state == .failed)
        #expect(harness.stubSession.lastURL == nil)
        #expect(harness.stubSession.createdTasks.isEmpty)
        await harness.manager.shutdown()
    }

    @Test("Paused tasks are re-admitted before opaque resume data reaches URLSession")
    func resumeDataCannotBypassURLAdmission() async throws {
        let harness = try StubDownloadHarness(label: "rejected-resume")
        let task = DownloadTask(
            url: URL(string: "http://example.invalid/archive.zip")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resumeData: Data("opaque-resume-data".utf8)
        )
        await task.restoreState(.paused)
        // `resume(_:)` intentionally ignores handles owned by another manager.
        // Register this synthetic restored handle so the assertion exercises
        // URL re-admission rather than the ownership boundary.
        await harness.manager.runtimeRegistry.add(task)

        await harness.manager.resume(task)

        #expect(await task.state == .failed)
        guard case .invalidURL(let reason) = await task.error else {
            Issue.record("Expected a sanitized invalidURL failure")
            await harness.manager.shutdown()
            return
        }
        #expect(reason == "Rejected by URL admission policy")
        #expect(harness.stubSession.lastResumeData == nil)
        #expect(harness.stubSession.createdTasks.isEmpty)
        await harness.manager.shutdown()
    }

    @Test(
        "directory downloads fall back for unsafe filenames",
        arguments: [
            "../escape.zip",
            "nested/file.zip",
            "nested\\file.zip",
            "bad:name.zip",
            "\u{FF0E}\u{FF0E}",
            "",
            "   ",
            ".",
            "..",
        ]
    )
    func directoryDownloadFallsBackForUnsafeFileNames(fileName: String) async throws {
        let harness = try StubDownloadHarness(label: "unsafe-filename")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = await harness.manager.download(
            url: URL(string: "https://example.invalid/archive.zip")!,
            toDirectory: directory,
            fileName: fileName
        )

        #expect(task.destinationURL.deletingLastPathComponent() == directory)
        #expect(task.destinationURL.lastPathComponent.hasPrefix("download-"))
        await harness.manager.shutdown()
    }

    @Test("directory downloads fall back for NUL-containing filenames")
    func directoryDownloadFallsBackForNULFileName() async throws {
        let harness = try StubDownloadHarness(label: "nul-filename")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = await harness.manager.download(
            url: URL(string: "https://example.invalid/archive.zip")!,
            toDirectory: directory,
            fileName: "bad\u{0}name"
        )

        #expect(task.destinationURL.deletingLastPathComponent() == directory)
        #expect(task.destinationURL.lastPathComponent.hasPrefix("download-"))
        await harness.manager.shutdown()
    }

    @Test("directory downloads fall back when URL has no file name")
    func directoryDownloadFallsBackWhenURLHasNoFileName() async throws {
        let harness = try StubDownloadHarness(label: "empty-url-filename")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = await harness.manager.download(
            url: URL(string: "https://example.invalid/")!,
            toDirectory: directory
        )

        #expect(task.destinationURL.deletingLastPathComponent() == directory)
        #expect(task.destinationURL.lastPathComponent.hasPrefix("download-"))
        await harness.manager.shutdown()
    }

    private func waitForCondition(
        timeout: TimeInterval = 1.0,
        predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }
}


private actor ShutdownCompletionProbe {
    private var started = false
    private var completed = false

    var isStarted: Bool { started }
    var isCompleted: Bool { completed }

    func markStarted() {
        started = true
    }

    func markCompleted() {
        completed = true
    }
}


private actor DelegateDrainProbe {
    private var started = false
    private var released = false
    private var finished = false

    var isStarted: Bool { started }
    var isFinished: Bool { finished }

    func handle() async {
        started = true
        while !released {
            try? await Task.sleep(for: .milliseconds(10))
        }
        finished = true
    }

    func release() {
        released = true
    }
}


/// Deliberately ignores task cancellation until the test releases its checked
/// continuation. The manager lifecycle race must therefore stop awaiting it
/// without relying on a well-behaved custom monitor implementation.
private actor SuspendedDownloadNetworkMonitor: NetworkMonitoring {
    private let snapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi])
    private var continuation: CheckedContinuation<NetworkSnapshot?, Never>?
    private(set) var waitForChangeCallCount = 0

    func currentSnapshot() async -> NetworkSnapshot? {
        snapshot
    }

    func waitForChange(
        from snapshot: NetworkSnapshot?,
        timeout: TimeInterval?
    ) async -> NetworkSnapshot? {
        _ = (snapshot, timeout)
        waitForChangeCallCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: snapshot)
    }
}


@Suite("Download Persistence Hardening Tests")
struct DownloadPersistenceHardeningTests {

    @Test("Safe reverse-DNS session identifiers preserve their storage directory")
    func safeSessionIdentifierKeepsExistingLayout() {
        let identifier = "com.example.downloads_2"
        #expect(DownloadSessionStorageKey.component(for: identifier) == identifier)
    }

    @Test("Session storage components are bounded and case-distinct")
    func sessionStorageComponentBoundaries() {
        let maximumRawIdentifier = String(repeating: "a", count: 128)
        let oversizedIdentifier = String(repeating: "a", count: 129)
        let lowercaseIdentifier = "com.example.downloads"
        let mixedCaseIdentifier = "com.Example.downloads"

        #expect(DownloadSessionStorageKey.component(for: maximumRawIdentifier) == maximumRawIdentifier)

        for identifier in ["", oversizedIdentifier, mixedCaseIdentifier] {
            let component = DownloadSessionStorageKey.component(for: identifier)
            #expect(component.hasPrefix("~"))
            #expect(component.utf8.count == 65)
        }

        let lowercaseComponent = DownloadSessionStorageKey.component(for: lowercaseIdentifier)
        let mixedCaseComponent = DownloadSessionStorageKey.component(for: mixedCaseIdentifier)
        #expect(lowercaseComponent == lowercaseIdentifier)
        #expect(lowercaseComponent != mixedCaseComponent)
        #expect(lowercaseComponent.lowercased() != mixedCaseComponent.lowercased())
    }

    @Test(
        "Path-like session identifiers map both stores to one bounded component",
        arguments: ["..", "../escape", "../../escape", "a/b", "~encoded", "com.Example", "세션"]
    )
    func pathLikeSessionIdentifiersStayInsideStorageRoot(sessionIdentifier: String) throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("inno-session-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: baseDirectory) }

        let component = DownloadSessionStorageKey.component(for: sessionIdentifier)
        #expect(component != sessionIdentifier)
        #expect(!component.contains("/"))
        #expect(component != ".")
        #expect(component != "..")

        _ = AppendLogDownloadTaskStore(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )

        let storageRoot = baseDirectory.appendingPathComponent("InnoNetworkDownload", isDirectory: true)
        let expectedSessionDirectory = storageRoot.appendingPathComponent(component, isDirectory: true)
        var isDirectory: ObjCBool = false
        #expect(fileManager.fileExists(atPath: expectedSessionDirectory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(
            try fileManager.contentsOfDirectory(atPath: storageRoot.path) == [component]
        )

        let configuration = DownloadConfiguration(
            sessionIdentifier: sessionIdentifier,
            persistenceBaseDirectoryURL: baseDirectory
        )
        #expect(
            DownloadCompletionStager.directoryURL(for: configuration)
                == expectedSessionDirectory.appendingPathComponent("CompletionStaging", isDirectory: true)
        )
    }

    @Test("stale empty store removes a record written later by another instance")
    func staleEmptyStoreRemoveUsesLockedDiskState() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-stale-empty-remove-\(UUID().uuidString)", isDirectory: true)
        let sessionIdentifier = "stale-empty-remove"
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let staleRemover = AppendLogDownloadTaskStore(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        let writer = AppendLogDownloadTaskStore(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        try await writer.upsert(
            id: "task",
            url: URL(string: "https://example.invalid/file.zip")!,
            destinationURL: baseDirectory.appendingPathComponent("file.zip"),
            resumeData: nil
        )

        try await staleRemover.remove(id: "task")

        let verifier = AppendLogDownloadTaskStore(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        #expect(await verifier.record(forID: "task") == nil)
    }

    @Test("stale store instance cannot resurrect a task while updating resume data")
    func staleResumeDataUpdateDoesNotResurrectRemovedRecord() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-stale-resume-update-\(UUID().uuidString)", isDirectory: true)
        let sessionIdentifier = "stale-resume-update"
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let writer = AppendLogDownloadTaskStore(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        try await writer.upsert(
            id: "task",
            url: URL(string: "https://example.invalid/file.zip")!,
            destinationURL: baseDirectory.appendingPathComponent("file.zip"),
            resumeData: nil
        )

        // Both actors load the record before one removes it, leaving the
        // other actor's in-memory state intentionally stale.
        let staleUpdater = AppendLogDownloadTaskStore(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        let remover = AppendLogDownloadTaskStore(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        try await remover.remove(id: "task")
        try await staleUpdater.updateResumeData(
            id: "task",
            resumeData: Data("stale".utf8),
            lifecycle: .paused
        )

        let verifier = AppendLogDownloadTaskStore(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        #expect(await verifier.record(forID: "task") == nil)
    }

    @Test("id(forURL:) returns the most recently upserted task for that URL")
    func urlReverseIndexReturnsLatestUpsert() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-persist-hardening-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let persistence = DownloadTaskPersistence(
            sessionIdentifier: "url-index-test",
            baseDirectoryURL: baseDir
        )
        let url = URL(string: "https://example.invalid/a.bin")!
        let dest = URL(fileURLWithPath: "/tmp/a.bin")

        try await persistence.upsert(id: "first", url: url, destinationURL: dest)
        #expect(await persistence.id(forURL: url) == "first")

        // Re-upserting the same id keeps the same reverse-index entry.
        try await persistence.upsert(id: "first", url: url, destinationURL: dest, resumeData: Data([0x01]))
        #expect(await persistence.id(forURL: url) == "first")

        // Removing the record clears the reverse-index entry.
        try await persistence.remove(id: "first")
        #expect(await persistence.id(forURL: url) == nil)
    }

    @Test("id(forURL:) is rebuilt from the on-disk log on init")
    func urlReverseIndexRebuiltOnReload() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-persist-hardening-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let url = URL(string: "https://example.invalid/b.bin")!
        let dest = URL(fileURLWithPath: "/tmp/b.bin")

        let first = DownloadTaskPersistence(
            sessionIdentifier: "url-reload-test",
            baseDirectoryURL: baseDir
        )
        try await first.upsert(id: "persisted", url: url, destinationURL: dest)

        // Reopening the same directory must reload the reverse index.
        let reloaded = DownloadTaskPersistence(
            sessionIdentifier: "url-reload-test",
            baseDirectoryURL: baseDir
        )
        #expect(await reloaded.id(forURL: url) == "persisted")
    }

    @Test("checkpoint preserves same-URL reverse-index ordering")
    func checkpointPreservesSameURLLatestID() async throws {
        let sessionIdentifier = "url-checkpoint-order-test"
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-persist-hardening-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let compactionPolicy = DownloadConfiguration.PersistenceCompactionPolicy(
            maxEvents: 2,
            maxLogBytes: UInt64.max,
            tombstoneRatio: 1
        )
        let url = URL(string: "https://example.invalid/shared.bin")!
        let firstDest = URL(fileURLWithPath: "/tmp/first.bin")
        let secondDest = URL(fileURLWithPath: "/tmp/second.bin")

        let writer = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDir,
            compactionPolicy: compactionPolicy
        )
        try await writer.upsert(id: "older", url: url, destinationURL: firstDest)
        try await writer.upsert(id: "newer", url: url, destinationURL: secondDest)

        let checkpointURL =
            baseDir
            .appendingPathComponent("InnoNetworkDownload", isDirectory: true)
            .appendingPathComponent(
                DownloadSessionStorageKey.component(for: sessionIdentifier),
                isDirectory: true
            )
            .appendingPathComponent("checkpoint.json", isDirectory: false)
        let checkpointData = try Data(contentsOf: checkpointURL)
        let checkpoint = try #require(
            JSONSerialization.jsonObject(with: checkpointData) as? [String: Any]
        )
        let orderedRecordIDs = try #require(checkpoint["orderedRecordIDs"] as? [String])
        #expect(orderedRecordIDs == ["newer", "older"])

        let reloaded = DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDir,
            compactionPolicy: compactionPolicy
        )
        #expect(await reloaded.id(forURL: url) == "newer")
    }
}
