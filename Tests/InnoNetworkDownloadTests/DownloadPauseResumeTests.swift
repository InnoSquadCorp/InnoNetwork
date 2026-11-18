import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetworkDownload

/// Pause / resume lifecycle verified through `StubDownloadURLSession`.
/// Each test drives state transitions by injecting synthetic delegate
/// callbacks; no `.invalid` URL races and no wall-clock polling. Serialized
/// because pause→resume transitions and the manager's `waitForRestore`
/// barrier share cooperative pool slots with the concurrent retry suite.
@Suite("Download Pause/Resume Tests", .serialized)
struct DownloadPauseResumeTests {

    @Test("Pause on idle task is a no-op")
    func pauseOnIdleIsNoOp() async throws {
        let harness = try StubDownloadHarness(label: "pause-idle")
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/file.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        await harness.manager.pause(task)

        #expect(await task.state == .idle)
    }

    @Test("Resume on non-paused task is a no-op")
    func resumeOnNonPausedIsNoOp() async throws {
        let harness = try StubDownloadHarness(label: "resume-idle")
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/file.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        await harness.manager.resume(task)

        #expect(await task.state == .idle)
    }

    @Test("Pause transitions downloading task to paused and captures resumeData")
    func pauseDownloadingTaskTransitionsToPaused() async throws {
        let harness = try StubDownloadHarness(label: "pause-downloading")
        let expectedResumeData = Data("resume-stub".utf8)
        harness.stubTask.scriptCancelResumeData(expectedResumeData)

        let task = await harness.startDownload()

        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                timeout: 5.0
            ))
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        await harness.manager.pause(task)

        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .paused })
        #expect(harness.stubTask.cancelByProducingResumeDataCount == 1)
        #expect(await task.resumeData == expectedResumeData)
        await harness.manager.cancel(task)
    }

    @Test("Completion while pause awaits resume data does not revive the completed task")
    func completionInterleavingPauseDoesNotEmitPausedOrPersistResumeData() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "inno-pause-completion-race-\(UUID().uuidString)",
            isDirectory: true
        )
        let temporaryLocation = rootURL.appendingPathComponent("download.tmp", isDirectory: false)
        let destinationURL = rootURL.appendingPathComponent("download.bin", isDirectory: false)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("completed-payload".utf8).write(to: temporaryLocation)
        defer { try? fileManager.removeItem(at: rootURL) }

        let harness = try StubDownloadHarness(label: "pause-completion-race")
        let stateRecorder = PauseStateRecorder()
        await harness.manager.setOnStateChangedHandler { _, state in
            await stateRecorder.record(state)
        }
        harness.stubTask.suspendCancelByProducingResumeData()

        let task = await harness.startDownload(destinationURL: destinationURL)
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 5.0)
        )
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        let pauseTask = Task {
            await harness.manager.pause(task)
        }
        #expect(
            await waitForPauseCondition {
                harness.stubTask.pendingCancelByProducingResumeDataCount == 1
            }
        )

        await harness.injectCompletion(taskIdentifier: taskIdentifier, location: temporaryLocation)
        #expect(await task.state == .completed)

        harness.stubTask.completeCancelByProducingResumeData(with: Data("stale-resume-data".utf8))
        await pauseTask.value

        #expect(await task.state == .completed)
        #expect(await task.resumeData == nil)
        #expect(await harness.store.record(forID: task.id) == nil)
        #expect(await stateRecorder.contains(.paused) == false)
        #expect(try Data(contentsOf: destinationURL) == Data("completed-payload".utf8))
        await harness.manager.shutdown()
    }

    @Test("A synchronously journaled completion wins before pause finalizes resume data")
    func journaledCompletionWinsPauseFinalization() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "inno-pause-journal-race-\(UUID().uuidString)",
            isDirectory: true
        )
        let temporaryLocation = rootURL.appendingPathComponent("download.tmp", isDirectory: false)
        let destinationURL = rootURL.appendingPathComponent("download.bin", isDirectory: false)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("journal-wins-pause".utf8).write(to: temporaryLocation)
        defer { try? fileManager.removeItem(at: rootURL) }

        let harness = try StubDownloadHarness(label: "pause-journal-race")
        harness.stubTask.suspendCancelByProducingResumeData()
        let task = await harness.startDownload(destinationURL: destinationURL)
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 5.0)
        )

        let pauseTask = Task {
            await harness.manager.pause(task)
        }
        #expect(
            await waitForPauseCondition {
                harness.stubTask.pendingCancelByProducingResumeDataCount == 1
            }
        )

        let admissionGate = await harness.manager.completionAdmissionGate
        #expect(
            admissionGate.beginStaging(
                taskID: task.id,
                taskIdentifier: taskIdentifier
            )
        )
        admissionGate.finishStaging(
            taskID: task.id,
            taskIdentifier: taskIdentifier,
            journaled: true
        )
        harness.stubTask.completeCancelByProducingResumeData(
            with: Data("must-not-be-persisted".utf8)
        )
        await pauseTask.value

        #expect(await task.state == .downloading)
        #expect(await task.resumeData == nil)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == taskIdentifier)

        await harness.injectCompletion(
            taskIdentifier: taskIdentifier,
            location: temporaryLocation
        )
        #expect(await task.state == .completed)
        #expect(try Data(contentsOf: destinationURL) == Data("journal-wins-pause".utf8))
        await harness.manager.shutdown()
    }

    @Test("Pause cancellation callback before resume data preserves the pausing attempt")
    func cancellationBeforeResumeDataDoesNotOrphanPause() async throws {
        let harness = try StubDownloadHarness(label: "pause-cancellation-before-resume-data")
        let resumeData = Data("resume-after-early-cancellation".utf8)
        harness.stubTask.suspendCancelByProducingResumeData()

        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 5.0)
        )
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        let pauseTask = Task {
            await harness.manager.pause(task)
        }
        #expect(
            await waitForPauseCondition {
                harness.stubTask.pendingCancelByProducingResumeDataCount == 1
            }
        )

        await harness.injectCompletion(
            taskIdentifier: taskIdentifier,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.cancelled.rawValue,
                message: "pause cancellation"
            )
        )

        #expect(await task.state == .downloading)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == taskIdentifier)

        harness.stubTask.completeCancelByProducingResumeData(with: resumeData)
        await pauseTask.value

        #expect(await task.state == .paused)
        #expect(await task.resumeData == resumeData)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == nil)
        await harness.manager.cancel(task)
    }

    @Test("Caller cancellation cannot abandon an irreversible pause transition")
    func callerCancellationStillFinalizesPause() async throws {
        let harness = try StubDownloadHarness(label: "pause-caller-cancellation")
        harness.stubTask.suspendCancelByProducingResumeData()
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 5.0)
        )

        let pauseTask = Task {
            await harness.manager.pause(task)
        }
        #expect(
            await waitForPauseCondition {
                guard harness.stubTask.pendingCancelByProducingResumeDataCount == 1 else {
                    return false
                }
                return await harness.persistence.record(forID: task.id)?.lifecycle == .pausing
            }
        )

        pauseTask.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await task.state == .downloading)

        harness.stubTask.completeCancelByProducingResumeData(with: nil)
        await pauseTask.value

        #expect(await task.state == .paused)
        #expect(await harness.persistence.record(forID: task.id)?.lifecycle == .paused)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == nil)

        await harness.injectCompletion(
            taskIdentifier: taskIdentifier,
            taskDescription: task.id,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.cancelled.rawValue,
                message: "late cancellation after caller-cancelled pause"
            )
        )
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await task.state == .paused)
        #expect(harness.stubSession.createdTasks.count == 1)
        await harness.manager.cancel(task)
    }

    @Test("Late cancellation from paused attempt does not remove resumed runtime")
    func lateCancellationFromPausedAttemptPreservesResumedRuntime() async throws {
        let downloadURL = URL(string: "https://example.invalid/file.zip")!
        let resumedStub = StubDownloadURLTask(request: URLRequest(url: downloadURL))
        let harness = try StubDownloadHarness(
            label: "pause-late-cancellation-after-resume",
            prequeuedStubs: [resumedStub]
        )
        harness.stubTask.scriptCancelResumeData(Data("resume-before-late-cancellation".utf8))

        let task = await harness.startDownload(url: downloadURL)
        let pausedAttemptIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 5.0)
        )
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        await harness.manager.pause(task)
        #expect(await task.state == .paused)

        await harness.manager.resume(task)
        let resumedIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                excluding: pausedAttemptIdentifier,
                timeout: 5.0
            )
        )
        #expect(resumedIdentifier == resumedStub.taskIdentifier)

        await harness.injectCompletion(
            taskIdentifier: pausedAttemptIdentifier,
            taskDescription: task.id,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.cancelled.rawValue,
                message: "late pause cancellation"
            )
        )

        #expect(await task.state == .downloading)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == resumedIdentifier)
        #expect(resumedStub.state == .running)
        await harness.manager.cancel(task)
    }

    @Test("Resume from paused with resumeData creates a new task via withResumeData:")
    func resumeFromPausedUsesResumeData() async throws {
        let downloadURL = URL(string: "https://example.invalid/file.zip")!
        let resumedStub = StubDownloadURLTask(request: URLRequest(url: downloadURL))
        let harness = try StubDownloadHarness(
            label: "resume-with-data",
            prequeuedStubs: [resumedStub]
        )
        let resumeData = try makeRetryResumeData("resume-payload")
        harness.stubTask.scriptCancelResumeData(resumeData)

        let task = await harness.startDownload(url: downloadURL)
        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                timeout: 5.0
            ))
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        await harness.manager.pause(task)
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .paused })
        #expect(await task.generation == 0)
        #expect(await task.attempt == 0)

        await harness.manager.resume(task)

        #expect(harness.stubSession.lastResumeData == resumeData)
        #expect(
            await waitForTaskState(task, timeout: 5.0) {
                $0 == .downloading || $0 == .waiting
            })
        let secondIdentifier = await harness.manager.runtimeTaskIdentifier(for: task)
        #expect(secondIdentifier == resumedStub.taskIdentifier)
        #expect(await task.generation == 0)
        #expect(await task.attempt == 1)
        await harness.manager.cancel(task)
    }

    @Test("Resume without resumeData falls back to fresh makeDownloadTask(with:)")
    func resumeWithoutResumeDataFallsBackToFreshDownload() async throws {
        let freshStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            label: "resume-fresh",
            prequeuedStubs: [freshStub]
        )
        harness.stubTask.scriptCancelResumeData(nil)

        let task = await harness.startDownload()
        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                timeout: 5.0
            ))
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        await harness.manager.pause(task)
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .paused })
        await task.setResumeData(nil)
        #expect(await task.generation == 0)
        #expect(await task.attempt == 0)

        await harness.manager.resume(task)

        #expect(harness.stubSession.lastResumeData == nil)
        #expect(
            await waitForTaskState(task, timeout: 5.0) {
                $0 == .downloading || $0 == .waiting
            })
        let secondIdentifier = await harness.manager.runtimeTaskIdentifier(for: task)
        #expect(secondIdentifier == freshStub.taskIdentifier)
        #expect(await task.generation == 0)
        #expect(await task.attempt == 1)
        await harness.manager.cancel(task)
    }

    @Test("Concurrent resume calls create only one replacement attempt")
    func concurrentResumeCallsAreSerialized() async throws {
        let resumedStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            label: "resume-concurrent",
            prequeuedStubs: [resumedStub]
        )
        harness.stubTask.scriptCancelResumeData(nil)
        let task = await harness.startDownload()
        await harness.manager.pause(task)
        #expect(await task.state == .paused)

        await harness.store.suspendUpserts()
        let firstResume = Task { await harness.manager.resume(task) }
        #expect(
            await waitForPauseCondition {
                await harness.store.pendingUpsertCount == 1
            }
        )
        let secondResume = Task { await harness.manager.resume(task) }
        await Task.yield()
        #expect(await harness.store.pendingUpsertCount == 1)

        await harness.store.resumeUpserts()
        await firstResume.value
        await secondResume.value

        #expect(harness.stubSession.createdTasks.count == 2)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == resumedStub.taskIdentifier)
        #expect(await task.state == .downloading)
        #expect(await harness.persistence.record(forID: task.id) != nil)
        await harness.manager.cancel(task)
    }

    @Test("Resume with persistence failure transitions paused → failed")
    func resumePersistenceFailureTransitionsPausedToFailed() async throws {
        let resumedStub = StubDownloadURLTask()
        let harness = try StubDownloadHarness(
            label: "resume-persistence-fails",
            prequeuedStubs: [resumedStub]
        )
        harness.stubTask.scriptCancelResumeData(Data("resume-persistence-fail".utf8))

        let task = await harness.startDownload()
        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                timeout: 5.0
            ))
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        await harness.manager.pause(task)
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .paused })

        await harness.store.setUpsertFailure(true)
        await harness.manager.resume(task)

        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .failed })
        await harness.store.setUpsertFailure(false)
    }

    @Test("Persistence failure keeps the failed handle registered until stale row cleanup succeeds")
    func persistenceFailureWithCleanupFailureRemainsRecoverable() async throws {
        let harness = try StubDownloadHarness(label: "resume-persistence-cleanup-fails")
        harness.stubTask.scriptCancelResumeData(Data("durable-paused-row".utf8))
        let task = await harness.startDownload()
        await harness.manager.pause(task)
        #expect(await task.state == .paused)
        #expect(await harness.persistence.record(forID: task.id) != nil)

        await harness.store.setUpsertFailure(true)
        await harness.store.setRemoveFailure(true)
        await harness.manager.resume(task)

        #expect(await task.state == .failed)
        #expect(await harness.manager.task(withId: task.id) === task)
        #expect(await harness.persistence.record(forID: task.id) != nil)

        await harness.store.setUpsertFailure(false)
        await harness.store.setRemoveFailure(false)
        await harness.manager.cancel(task)
        #expect(await harness.manager.task(withId: task.id) == nil)
        #expect(await harness.persistence.record(forID: task.id) == nil)
    }

    @Test("Cancel from paused state clears runtime registration")
    func cancelFromPausedClearsRuntime() async throws {
        let harness = try StubDownloadHarness(label: "cancel-paused")
        harness.stubTask.scriptCancelResumeData(Data("cancel-after-pause".utf8))

        let task = await harness.startDownload()
        _ = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                timeout: 5.0
            ))
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })

        await harness.manager.pause(task)
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .paused })

        await harness.manager.cancel(task)

        #expect(await task.state == .cancelled)
        #expect(await harness.manager.task(withId: task.id) == nil)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == nil)
    }

    // MARK: Failure of a resumed attempt

    @Test(
        "An attempt that fails before resume records it as active is retried instead of stranded",
        arguments: ResumeStart.allCases
    )
    func failureBeforeResumeIsRecordedIsRetried(start: ResumeStart) async throws {
        let fixture = try await PausedDownloadFixture(label: "resume-failure-before-recorded", start: start)
        let harness = fixture.harness
        let task = fixture.task
        let failureResumeData = try makeRetryResumeData("failed-before-recorded")
        await harness.store.setBeforeResumeFinalized { _ in
            // The resumed attempt is running, and its record still says
            // `.resuming`.
            await harness.injectCompletion(
                taskIdentifier: fixture.resumedStub.taskIdentifier,
                error: retryWaitConnectionLost,
                resumeData: failureResumeData
            )
        }

        await harness.manager.resume(task)

        // The failure scheduled a retry, and the resume did not record the
        // finished attempt as active or fail the task over the lost write.
        #expect(await fixture.clock.waitForEnqueuedCount(atLeast: 1, timeout: 10.0))
        let waiting = await harness.store.record(forID: task.id)
        #expect(waiting?.lifecycle == .retryPending)
        #expect(waiting?.resumeData == failureResumeData)
        #expect(await harness.manager.runtimeTaskIdentifier(for: task) == nil)
        #expect(await task.state == .downloading)
        #expect(await task.error == nil)
        #expect(await task.retryCount == 1)

        // When the backoff ends, the retry continues the transfer.
        fixture.clock.advance(by: .seconds(60))
        #expect(await waitForResumeCount(fixture.retryStub, atLeast: 1, timeout: 10.0))
        #expect(harness.stubSession.lastResumeData == failureResumeData)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .active)

        await harness.manager.shutdown()
    }

    @Test(
        "Resume data that a failure leaves just after resume records its attempt survives for the retry",
        arguments: ResumeStart.allCases
    )
    func failureAfterResumeIsRecordedKeepsItsResumeData(start: ResumeStart) async throws {
        let fixture = try await PausedDownloadFixture(label: "resume-failure-after-recorded", start: start)
        let harness = fixture.harness
        let task = fixture.task
        let failureResumeData = try makeRetryResumeData("failed-after-recorded")
        await harness.store.setAfterResumeFinalized { _ in
            // The attempt is recorded as active, and resume has not yet
            // dropped the resume data it started from.
            await harness.injectCompletion(
                taskIdentifier: fixture.resumedStub.taskIdentifier,
                error: retryWaitConnectionLost,
                resumeData: failureResumeData
            )
        }

        await harness.manager.resume(task)

        #expect(await fixture.clock.waitForEnqueuedCount(atLeast: 1, timeout: 10.0))
        #expect(await task.resumeData == failureResumeData)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .retryPending)

        fixture.clock.advance(by: .seconds(60))
        #expect(await waitForResumeCount(fixture.retryStub, atLeast: 1, timeout: 10.0))
        #expect(harness.stubSession.lastResumeData == failureResumeData)

        await harness.manager.shutdown()
    }

    @Test("A failure's resume data with the consumed blob's bytes survives for the retry")
    func failureAfterResumeIsRecordedKeepsResumeDataWithTheConsumedBytes() async throws {
        let fixture = try await PausedDownloadFixture(label: "resume-failure-same-bytes", start: .fromResumeData)
        let harness = fixture.harness
        let task = fixture.task
        // The failed attempt received nothing new, so its resume data has the
        // same bytes as the blob the attempt was resumed from. It is still a
        // newer write than the one resume consumed.
        let failureResumeData = try #require(await task.resumeData)
        await harness.store.setAfterResumeFinalized { _ in
            await harness.injectCompletion(
                taskIdentifier: fixture.resumedStub.taskIdentifier,
                error: retryWaitConnectionLost,
                resumeData: failureResumeData
            )
        }

        await harness.manager.resume(task)

        #expect(await fixture.clock.waitForEnqueuedCount(atLeast: 1, timeout: 10.0))
        #expect(await task.resumeData == failureResumeData)
        #expect(await harness.store.record(forID: task.id)?.lifecycle == .retryPending)

        // A pause during the retry wait keeps the checkpoint for the next
        // resume instead of recording a pause without one.
        await harness.manager.pause(task)
        #expect(await task.state == .paused)
        let paused = await harness.store.record(forID: task.id)
        #expect(paused?.lifecycle == .paused)
        #expect(paused?.resumeData == failureResumeData)

        await harness.manager.shutdown()
    }
}


/// How the next attempt of a paused task starts: from the resume data its
/// pause produced, or as a fresh request when the pause produced none.
enum ResumeStart: CaseIterable, Sendable, CustomTestStringConvertible {
    case fromResumeData
    case freshRequest

    var testDescription: String {
        switch self {
        case .fromResumeData: "from resume data"
        case .freshRequest: "as a fresh request"
        }
    }
}


/// A download that was started and paused once. Resuming it consumes
/// `resumedStub`, and the retry after that attempt fails consumes
/// `retryStub`. A 30-second backoff on a virtual clock holds the retry until
/// the test advances it.
private struct PausedDownloadFixture {
    let harness: StubDownloadHarness
    let clock: TestClock
    let task: DownloadTask
    let resumedStub: StubDownloadURLTask
    let retryStub: StubDownloadURLTask

    init(label: String, start: ResumeStart) async throws {
        let downloadURL = try #require(URL(string: "https://example.invalid/file.zip"))
        // Both stubs retain the source request, as a task Foundation rebuilds
        // from genuine resume data does, so either passes resumed-task
        // admission.
        let resumedStub = StubDownloadURLTask(request: URLRequest(url: downloadURL))
        let retryStub = StubDownloadURLTask(request: URLRequest(url: downloadURL))
        let clock = TestClock()
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            retryDelay: 30,
            clock: clock,
            label: label,
            prequeuedStubs: [resumedStub, retryStub]
        )
        let pauseResumeData: Data?
        switch start {
        case .fromResumeData:
            pauseResumeData = try makeRetryResumeData("produced-by-pause")
        case .freshRequest:
            pauseResumeData = nil
        }
        harness.stubTask.scriptCancelResumeData(pauseResumeData)

        let task = await harness.startDownload(url: downloadURL)
        _ = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 5.0)
        )
        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .downloading })
        await harness.manager.pause(task)
        #expect(await task.state == .paused)
        #expect(await task.resumeData == pauseResumeData)

        self.harness = harness
        self.clock = clock
        self.task = task
        self.resumedStub = resumedStub
        self.retryStub = retryStub
    }
}


private actor PauseStateRecorder {
    private var states: [DownloadState] = []

    func record(_ state: DownloadState) {
        states.append(state)
    }

    func contains(_ state: DownloadState) -> Bool {
        states.contains(state)
    }
}


private func waitForPauseCondition(
    timeout: TimeInterval = 2.0,
    predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(TestWaitBudget.upperBound(timeout))
    while Date() < deadline {
        if await predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}
