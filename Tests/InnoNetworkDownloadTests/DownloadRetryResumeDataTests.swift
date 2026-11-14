import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkDownload

/// Automatic retries must continue from the resume data Foundation attaches
/// to a failed attempt instead of re-downloading from byte 0.
@Suite("Download retry resume data", .serialized)
struct DownloadRetryResumeDataTests {

    // MARK: End to end through a real URLSession

    @Test("An interrupted transfer's automatic retry sends a Range request and completes the same file")
    func automaticRetryResumesInterruptedTransfer() async throws {
        let payload = makeScriptedPayload()
        let deliveredBeforeFailure = 200 * 1024
        let failureGate = ScriptedGate()
        let context = try ScriptedDownloadContext(
            label: "retry-resume-data",
            maxRetryCount: 2,
            retryDelay: 0
        ) { request, index in
            scriptedResumableStep(
                for: request,
                index: index,
                payload: payload,
                deliveredBeforeFailure: deliveredBeforeFailure,
                failureGate: failureGate
            )
        }
        await context.dropConnection(through: failureGate, afterWriting: deliveredBeforeFailure)

        let task = await context.startDownload()

        #expect(await waitForTaskState(task, timeout: 30.0) { $0.isTerminal })
        #expect(await task.state == .completed)
        #expect(try Data(contentsOf: context.destinationURL) == payload)

        let requests = context.transportRequests
        #expect(requests.count == 2)
        #expect(requests.first?.value(forHTTPHeaderField: "Range") == nil)
        // The retry continues where the failed attempt stopped. Foundation
        // owns the exact offset, so only assert that it is a resumed range.
        let retryRange = requests.last?.value(forHTTPHeaderField: "Range")
        let retryOffset = retryRange.flatMap(scriptedRangeOffset)
        #expect(retryOffset != nil, "retry restarted from byte 0 (Range: \(retryRange ?? "none"))")
        if let retryOffset {
            #expect(retryOffset > 0)
            #expect(retryOffset <= deliveredBeforeFailure)
        }
        #expect(await task.retryCount == 1)

        await context.tearDown()
    }

    @Test("A resumed retry whose range the server rejects with 416 restarts from the source and completes")
    func rejectedResumeRangeFallsBackToFreshRequest() async throws {
        let payload = makeScriptedPayload()
        let deliveredBeforeFailure = 200 * 1024
        let failureGate = ScriptedGate()
        let context = try ScriptedDownloadContext(
            label: "retry-resume-416",
            maxRetryCount: 3,
            retryDelay: 0
        ) { request, index in
            if request.value(forHTTPHeaderField: "Range") != nil {
                // The resume point is no longer satisfiable on the origin.
                return .init(
                    statusCode: 416,
                    headers: ["Content-Range": "bytes */\(payload.count)"],
                    body: Data("Requested Range Not Satisfiable".utf8)
                )
            }
            return scriptedResumableStep(
                for: request,
                index: index,
                payload: payload,
                deliveredBeforeFailure: deliveredBeforeFailure,
                failureGate: failureGate
            )
        }
        await context.dropConnection(through: failureGate, afterWriting: deliveredBeforeFailure)

        let task = await context.startDownload()

        #expect(await waitForTaskState(task, timeout: 30.0) { $0.isTerminal })
        #expect(await task.state == .completed)
        #expect(try Data(contentsOf: context.destinationURL) == payload)
        // Interrupted attempt, rejected resumed attempt, fresh attempt.
        let ranges = context.transportRequests.map { $0.value(forHTTPHeaderField: "Range") }
        #expect(ranges.count == 3)
        #expect(ranges.first == .some(nil))
        #expect(ranges.dropFirst().first.flatMap { $0 } != nil)
        #expect(ranges.last == .some(nil))
        #expect(await task.retryCount == 2)

        await context.tearDown()
    }

    // MARK: Delegate extraction

    @Test("The delegate lifts resume data out of the transport error and the retry resumes from it")
    func delegateResumeDataReachesTheRetryAttempt() async throws {
        let fixture = try await RetryResumeFixture(label: "retry-resume-delegate")
        let resumeData = try makeRetryResumeData("delegate")

        // Foundation reports the blob only in the NSError's userInfo.
        fixture.harness.delegate.handleCompletedAttempt(
            taskIdentifier: fixture.failedIdentifier,
            taskDescription: fixture.task.id,
            originalRequestURL: fixture.sourceURL,
            currentRequestURL: fixture.sourceURL,
            error: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNetworkConnectionLost,
                userInfo: [NSURLSessionDownloadTaskResumeData: resumeData]
            )
        )

        let retryIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: fixture.harness.manager,
                task: fixture.task,
                excluding: fixture.failedIdentifier,
                timeout: 10.0
            )
        )
        #expect(retryIdentifier == fixture.retryStub.taskIdentifier)
        #expect(await waitForResumeCount(fixture.retryStub, atLeast: 1, timeout: 10.0))
        #expect(fixture.harness.stubSession.resumeDataRequests == [resumeData])
        #expect(fixture.harness.stubSession.createdTasks.count == 2)
        // The blob seeded exactly one attempt and is gone from both stores.
        #expect(await fixture.task.resumeData == nil)
        let record = try #require(await fixture.harness.store.record(forID: fixture.task.id))
        #expect(record.lifecycle == .active)
        #expect(record.resumeData == nil)
        #expect(await fixture.task.retryCount == 1)
        #expect(await fixture.task.attempt == 1)

        await fixture.harness.manager.shutdown()
    }

    @Test("Resume data extraction ignores errors that carry no usable blob")
    func resumeDataExtraction() throws {
        let resumeData = try makeRetryResumeData("extraction")
        let carrying = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSURLSessionDownloadTaskResumeData: resumeData]
        )
        #expect(DownloadAttemptResumeData.extract(from: carrying) == resumeData)
        // The value projection used everywhere downstream cannot carry it.
        #expect(DownloadAttemptResumeData.extract(from: SendableUnderlyingError(carrying)) == nil)
        #expect(DownloadAttemptResumeData.extract(from: URLError(.timedOut)) == nil)
        #expect(
            DownloadAttemptResumeData.extract(
                from: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorTimedOut,
                    userInfo: [NSURLSessionDownloadTaskResumeData: Data()]
                )
            ) == nil
        )
        #expect(
            DownloadAttemptResumeData.extract(
                from: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorTimedOut,
                    userInfo: [NSURLSessionDownloadTaskResumeData: "not-data"]
                )
            ) == nil
        )
    }

    // MARK: Fallback to a fresh request

    @Test("A failure without resume data retries with a fresh request")
    func retryWithoutResumeDataStartsFresh() async throws {
        let fixture = try await RetryResumeFixture(label: "retry-resume-absent")

        await fixture.fail(resumeData: nil)

        let retryIdentifier = try #require(await fixture.waitForRetryAttempt())
        #expect(retryIdentifier == fixture.retryStub.taskIdentifier)
        #expect(fixture.harness.stubSession.resumeDataRequests.isEmpty)
        #expect(fixture.harness.stubSession.createdTasks.count == 2)

        await fixture.harness.manager.shutdown()
    }

    @Test("Resume data whose rebuilt task targets another URL is cancelled and replaced by a fresh request")
    func foreignResumedTaskFallsBackToFreshRequest() async throws {
        let foreignURL = try #require(URL(string: "https://attacker.invalid/other.bin"))
        let foreignStub = StubDownloadURLTask(request: URLRequest(url: foreignURL))
        let freshStub = StubDownloadURLTask()
        let fixture = try await RetryResumeFixture(
            label: "retry-resume-foreign",
            retryStubs: [foreignStub, freshStub]
        )
        let resumeData = try makeRetryResumeData("foreign")

        await fixture.fail(resumeData: resumeData)

        let retryIdentifier = try #require(await fixture.waitForRetryAttempt())
        #expect(retryIdentifier == freshStub.taskIdentifier)
        #expect(await waitForResumeCount(freshStub, atLeast: 1, timeout: 10.0))
        #expect(fixture.harness.stubSession.resumeDataRequests == [resumeData])
        #expect(foreignStub.cancelCount == 1)
        #expect(foreignStub.resumeCount == 0)
        #expect(fixture.harness.stubSession.lastURL == fixture.sourceURL)
        #expect(await fixture.task.resumeData == nil)

        await fixture.harness.manager.shutdown()
    }

    @Test(
        "Structurally unusable resume data is never handed to URLSession",
        arguments: UnusableResumeData.allCases
    )
    func unusableResumeDataFallsBackToFreshRequest(shape: UnusableResumeData) async throws {
        let fixture = try await RetryResumeFixture(label: "retry-resume-unusable-\(shape.rawValue)")

        await fixture.fail(resumeData: try shape.makeData())

        let retryIdentifier = try #require(await fixture.waitForRetryAttempt())
        #expect(retryIdentifier == fixture.retryStub.taskIdentifier)
        #expect(fixture.harness.stubSession.resumeDataRequests.isEmpty)
        #expect(fixture.harness.stubSession.createdTasks.count == 2)
        #expect(await fixture.task.resumeData == nil)

        await fixture.harness.manager.shutdown()
    }

    @Test("Only a property list rooted at a dictionary counts as usable resume data")
    func structuralUsability() throws {
        let binary = try makeRetryResumeData("binary")
        let xml = try PropertyListSerialization.data(
            fromPropertyList: ["NSURLSessionResumeBytesReceived": 1],
            format: .xml,
            options: 0
        )
        #expect(DownloadAttemptResumeData.isStructurallyUsable(binary))
        #expect(DownloadAttemptResumeData.isStructurallyUsable(xml))
        for shape in UnusableResumeData.allCases {
            #expect(!DownloadAttemptResumeData.isStructurallyUsable(try shape.makeData()))
        }
        #expect(!DownloadAttemptResumeData.isStructurallyUsable(Data()))
    }

    @Test("Each attempt consumes only the resume data of the failure that preceded it")
    func laterFailureWithoutResumeDataStartsFresh() async throws {
        let secondRetryStub = StubDownloadURLTask()
        let fixture = try await RetryResumeFixture(
            label: "retry-resume-consumed",
            extraStubs: [secondRetryStub]
        )
        let resumeData = try makeRetryResumeData("consumed")

        await fixture.fail(resumeData: resumeData)
        let firstRetry = try #require(await fixture.waitForRetryAttempt())
        #expect(firstRetry == fixture.retryStub.taskIdentifier)

        await fixture.harness.injectCompletion(
            taskIdentifier: firstRetry,
            error: retryWaitConnectionLost
        )
        let secondRetry = try #require(
            await waitForRuntimeTaskIdentifier(
                manager: fixture.harness.manager,
                task: fixture.task,
                excluding: firstRetry,
                timeout: 10.0
            )
        )
        #expect(secondRetry == secondRetryStub.taskIdentifier)
        // One resumed attempt, then a fresh request: the consumed blob is
        // not reused for the failure that carried none.
        #expect(fixture.harness.stubSession.resumeDataRequests == [resumeData])
        #expect(fixture.harness.stubSession.createdTasks.count == 3)

        await fixture.harness.manager.shutdown()
    }

    @Test("A failure that is not retried retains no resume data")
    func exhaustedBudgetRetainsNoResumeData() async throws {
        let fixture = try await RetryResumeFixture(label: "retry-resume-exhausted", maxRetryCount: 0)

        await fixture.fail(resumeData: try makeRetryResumeData("exhausted"))

        #expect(await waitForTaskState(fixture.task, timeout: 10.0) { $0 == .failed })
        #expect(await fixture.task.resumeData == nil)
        #expect(fixture.harness.stubSession.resumeDataRequests.isEmpty)
        #expect(fixture.harness.stubSession.createdTasks.count == 1)

        await fixture.harness.manager.shutdown()
    }

    // MARK: Durability

    @Test("Resume data stays on the durable retry marker across the network wait and the backoff rewrite")
    func resumeDataSurvivesRetryPlanRewrite() async throws {
        let clock = TestClock()
        let monitor = GatedNetworkMonitor()
        let fixture = try await RetryResumeFixture(
            label: "retry-resume-durable",
            retryDelay: 30,
            networkMonitor: monitor,
            clock: clock
        )
        let resumeData = try makeRetryResumeData("durable")

        await fixture.fail(resumeData: resumeData)

        #expect(await monitor.waitUntilWaiting())
        let waiting = try #require(await fixture.harness.store.record(forID: fixture.task.id))
        #expect(waiting.lifecycle == .retryPending)
        #expect(waiting.retryPlan?.phase == .waitingForNetwork)
        #expect(waiting.resumeData == resumeData)
        #expect(await fixture.task.resumeData == resumeData)

        await monitor.reportChange(NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi]))

        // The backoff sleeper is enqueued only after the plan rewrite and
        // the re-attached resume data are both durable.
        #expect(await clock.waitForEnqueuedCount(atLeast: 1, timeout: 10.0))
        let backingOff = try #require(await fixture.harness.store.record(forID: fixture.task.id))
        #expect(backingOff.lifecycle == .retryPending)
        #expect(backingOff.retryPlan?.phase == .backoff)
        #expect(backingOff.resumeData == resumeData)

        clock.advance(by: .seconds(30))

        let retryIdentifier = try #require(await fixture.waitForRetryAttempt())
        #expect(retryIdentifier == fixture.retryStub.taskIdentifier)
        #expect(fixture.harness.stubSession.resumeDataRequests == [resumeData])
        let active = try #require(await fixture.harness.store.record(forID: fixture.task.id))
        #expect(active.lifecycle == .active)
        #expect(active.resumeData == nil)

        await fixture.harness.manager.shutdown()
    }

    @Test("A retry restored after relaunch continues from the persisted resume data")
    func restoredRetryUsesPersistedResumeData() async throws {
        let id = "restored-retry-resume-\(UUID().uuidString)"
        let sourceURL = try #require(URL(string: "https://example.invalid/restored-retry-resume.bin"))
        let resumeData = try makeRetryResumeData("restored")
        let restoredAttempt = StubDownloadURLTask(request: URLRequest(url: sourceURL))
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            label: "restored-retry-resume",
            prepopulatedRecords: [
                DownloadTaskPersistence.Record(
                    id: id,
                    url: sourceURL,
                    destinationURL: makeRetryWaitDestinationURL(),
                    resumeData: resumeData,
                    lifecycle: .retryPending,
                    retryCount: 1,
                    totalRetryCount: 1,
                    retryPlan: .backoff(retryNotBefore: .distantPast)
                )
            ],
            initialStub: restoredAttempt
        )
        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: id))

        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: restored, timeout: 10.0)
        )
        #expect(identifier == restoredAttempt.taskIdentifier)
        #expect(await waitForResumeCount(restoredAttempt, atLeast: 1, timeout: 10.0))
        #expect(harness.stubSession.resumeDataRequests == [resumeData])
        #expect(await restored.retryCount == 1)
        #expect(await restored.resumeData == nil)

        await harness.manager.shutdown()
    }

    @Test("The append-log store replays resume data kept on a retry marker and on the pause taken from it")
    func appendLogRoundTripsRetryResumeData() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inno-retry-resume-data-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let sessionIdentifier = "retry-resume-data-roundtrip"
        let taskID = "retry-resume-data-\(UUID().uuidString)"
        let sourceURL = try #require(URL(string: "https://example.invalid/retry-resume-data.bin"))
        let resumeData = try makeRetryResumeData("append-log")
        let plan = DownloadTaskPersistence.RetryPlan.backoff(
            retryNotBefore: Date(timeIntervalSince1970: 456)
        )
        let writer = try DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        try await writer.upsert(
            id: taskID,
            url: sourceURL,
            destinationURL: baseDirectory.appendingPathComponent("payload.bin")
        )
        #expect(
            try await writer.updateRetryState(
                id: taskID,
                retryCount: 1,
                totalRetryCount: 1,
                retryPlan: plan
            )
        )
        // The same identity transition the failure coordinator performs.
        #expect(
            try await writer.transitionResumeState(
                id: taskID,
                from: .retryPending,
                to: .retryPending,
                resumeData: resumeData
            )
        )

        let retryReader = try DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        let replayedRetry = try #require(await retryReader.record(forID: taskID))
        #expect(replayedRetry.lifecycle == .retryPending)
        #expect(replayedRetry.resumeData == resumeData)
        #expect(replayedRetry.retryPlan == plan)
        #expect(replayedRetry.retryCount == 1)

        // The transition a pause issued during the retry wait performs.
        #expect(
            try await retryReader.transitionResumeState(
                id: taskID,
                from: .retryPending,
                to: .paused,
                resumeData: resumeData
            )
        )
        let pauseReader = try DownloadTaskPersistence(
            sessionIdentifier: sessionIdentifier,
            baseDirectoryURL: baseDirectory
        )
        let replayedPause = try #require(await pauseReader.record(forID: taskID))
        #expect(replayedPause.lifecycle == .paused)
        #expect(replayedPause.resumeData == resumeData)
    }

    // MARK: Interplay with pause

    @Test("Pausing a waiting retry keeps the failed attempt's resume data and resume continues from it")
    func pauseDuringRetryWaitKeepsResumeData() async throws {
        let clock = TestClock()
        let fixture = try await RetryResumeFixture(
            label: "retry-resume-pause",
            retryDelay: 30,
            clock: clock
        )
        let resumeData = try makeRetryResumeData("pause")

        await fixture.fail(resumeData: resumeData)
        #expect(await clock.waitForEnqueuedCount(atLeast: 1, timeout: 10.0))

        await fixture.harness.manager.pause(fixture.task)

        #expect(await fixture.task.state == .paused)
        #expect(await fixture.task.resumeData == resumeData)
        let paused = try #require(await fixture.harness.store.record(forID: fixture.task.id))
        #expect(paused.lifecycle == .paused)
        #expect(paused.resumeData == resumeData)

        clock.advance(by: .seconds(30))
        await fixture.harness.manager.drainDeferredFailureTasks()
        #expect(fixture.harness.stubSession.resumeDataRequests.isEmpty)
        #expect(await fixture.task.state == .paused)

        await fixture.harness.manager.resume(fixture.task)

        let resumedIdentifier = try #require(await fixture.waitForRetryAttempt())
        #expect(resumedIdentifier == fixture.retryStub.taskIdentifier)
        #expect(await waitForResumeCount(fixture.retryStub, atLeast: 1, timeout: 10.0))
        #expect(fixture.harness.stubSession.resumeDataRequests == [resumeData])
        #expect(await waitForTaskState(fixture.task, timeout: 10.0) { $0 == .downloading })
        let active = try #require(await fixture.harness.store.record(forID: fixture.task.id))
        #expect(active.lifecycle == .active)
        #expect(active.resumeData == nil)

        await fixture.harness.manager.shutdown()
    }
}


// MARK: - Helpers

/// Shapes Foundation would crash on or silently reject if they reached
/// `downloadTask(withResumeData:)`.
enum UnusableResumeData: String, CaseIterable, Sendable {
    case notAPropertyList
    case stringPropertyList
    case arrayPropertyList

    func makeData() throws -> Data {
        switch self {
        case .notAPropertyList:
            return Data([0xFF, 0x00, 0xAB, 0x13, 0x37, 0x80, 0x81])
        case .stringPropertyList:
            return Data("garbage".utf8)
        case .arrayPropertyList:
            return try PropertyListSerialization.data(
                fromPropertyList: ["a", "b"],
                format: .binary,
                options: 0
            )
        }
    }
}


/// Stand-in for Foundation's opaque blob: a property list rooted at a
/// dictionary, distinguishable per test through `marker`.
func makeRetryResumeData(_ marker: String) throws -> Data {
    try PropertyListSerialization.data(
        fromPropertyList: ["NSURLSessionResumeInfoMarker": marker],
        format: .binary,
        options: 0
    )
}


/// One started download plus the stub the next attempt will consume. The
/// retry stub retains the source request, as a task Foundation rebuilds from
/// genuine resume data does, so it passes resumed-task admission.
private struct RetryResumeFixture {
    let harness: StubDownloadHarness
    let task: DownloadTask
    let failedIdentifier: Int
    let sourceURL: URL
    let retryStub: StubDownloadURLTask

    init(
        label: String,
        maxRetryCount: Int = 3,
        retryDelay: TimeInterval = 0,
        networkMonitor: (any NetworkMonitoring)? = nil,
        clock: any InnoNetworkClock = SystemClock(),
        retryStubs: [StubDownloadURLTask]? = nil,
        extraStubs: [StubDownloadURLTask] = []
    ) async throws {
        let sourceURL = try #require(URL(string: "https://example.invalid/\(label).bin"))
        self.sourceURL = sourceURL
        let defaultRetryStub = StubDownloadURLTask(request: URLRequest(url: sourceURL))
        let queued = (retryStubs ?? [defaultRetryStub]) + extraStubs
        self.retryStub = queued.first ?? defaultRetryStub
        let harness = try StubDownloadHarness(
            maxRetryCount: maxRetryCount,
            maxTotalRetries: maxRetryCount,
            retryDelay: retryDelay,
            networkMonitor: networkMonitor,
            waitsForNetworkChanges: networkMonitor != nil,
            networkChangeTimeout: nil,
            clock: clock,
            label: label,
            prequeuedStubs: queued
        )
        self.harness = harness
        let task = await harness.startDownload(
            url: sourceURL,
            destinationURL: makeRetryWaitDestinationURL()
        )
        self.task = task
        self.failedIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
    }

    /// Fails the first attempt with a retryable transport error.
    func fail(resumeData: Data?) async {
        await harness.injectCompletion(
            taskIdentifier: failedIdentifier,
            error: retryWaitConnectionLost,
            resumeData: resumeData
        )
    }

    func waitForRetryAttempt() async -> Int? {
        await waitForRuntimeTaskIdentifier(
            manager: harness.manager,
            task: task,
            excluding: failedIdentifier,
            timeout: 10.0
        )
    }
}


func makeScriptedPayload() -> Data {
    Data((0..<(512 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
}


extension ScriptedDownloadContext {
    /// Opens `gate` once the session reports `byteCount` bytes as written to
    /// its temporary file, so the scripted connection drop leaves Foundation
    /// with a resume point at a known non-zero offset.
    func dropConnection(through gate: ScriptedGate, afterWriting byteCount: Int) async {
        await manager.setOnProgressHandler { _, progress in
            if progress.totalBytesWritten >= Int64(byteCount) {
                gate.open()
            }
        }
    }
}


/// Serves `payload` like a range-capable origin: the first request delivers
/// a prefix and then drops the connection, later requests honour `Range`.
func scriptedResumableStep(
    for request: URLRequest,
    index: Int,
    payload: Data,
    deliveredBeforeFailure: Int,
    failureGate: ScriptedGate? = nil
) -> ScriptedDownloadURLProtocol.Step {
    let validators = [
        "ETag": "\"scripted-v1\"",
        "Accept-Ranges": "bytes",
        "Content-Type": "application/octet-stream",
    ]
    if let offset = request.value(forHTTPHeaderField: "Range").flatMap(scriptedRangeOffset),
        offset < payload.count
    {
        let remainder = payload.suffix(from: payload.startIndex + offset)
        var headers = validators
        headers["Content-Length"] = "\(remainder.count)"
        headers["Content-Range"] = "bytes \(offset)-\(payload.count - 1)/\(payload.count)"
        return .init(statusCode: 206, headers: headers, body: Data(remainder))
    }
    var headers = validators
    headers["Content-Length"] = "\(payload.count)"
    if index == 0 {
        return .init(
            statusCode: 200,
            headers: headers,
            body: Data(payload.prefix(deliveredBeforeFailure)),
            failure: .networkConnectionLost,
            failureGate: failureGate
        )
    }
    return .init(statusCode: 200, headers: headers, body: payload)
}


func scriptedRangeOffset(_ rangeHeader: String) -> Int? {
    guard rangeHeader.hasPrefix("bytes=") else { return nil }
    return rangeHeader.dropFirst("bytes=".count).split(separator: "-").first.flatMap { Int($0) }
}
