import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkDownload

/// HTTP status validation for finished download attempts.
///
/// `URLSessionDownloadTask` does not fail on 4xx/5xx: Foundation writes the
/// error body to its temporary file and reports `didFinishDownloadingTo`.
/// These tests pin that the library never stages or publishes such a body as
/// a completed download.
@Suite("Download HTTP status validation", .serialized)
struct DownloadHTTPStatusValidationTests {

    // MARK: End to end through a real URLSession

    @Test("A 403 response fails with a typed status error instead of completing with the error body")
    func forbiddenResponseFailsInsteadOfCompleting() async throws {
        let errorBody = Data("<Error><Code>AccessDenied</Code></Error>".utf8)
        let context = try ScriptedDownloadContext(
            label: "status-403",
            steps: [
                .init(
                    statusCode: 403,
                    headers: ["Content-Type": "application/xml"],
                    body: errorBody
                )
            ]
        )

        let task = await context.startDownload()

        #expect(await waitForTaskState(task, timeout: 20.0) { $0.isTerminal })
        #expect(await task.state == .failed)
        let failure = await task.error
        if case .unacceptableStatusCode(let statusCode)? = failure {
            #expect(statusCode == 403)
            #expect(failure?.httpStatusCode == 403)
        } else {
            Issue.record("Expected a typed HTTP status failure, got \(String(describing: failure))")
        }
        #expect(!FileManager.default.fileExists(atPath: context.destinationURL.path))
        // A 403 is deterministic for this request: no retry budget is spent
        // and the transport is not contacted a second time.
        #expect(await task.retryCount == 0)
        #expect(await task.totalRetryCount == 0)
        #expect(context.transportRequests.count == 1)
        #expect(await context.store.record(forID: task.id) == nil)

        await context.tearDown()
    }

    @Test("A transient 503 is retried and the following 200 completes the download")
    func transientStatusIsRetriedUntilSuccess() async throws {
        let payload = Data("the-requested-file".utf8)
        let context = try ScriptedDownloadContext(
            label: "status-503-then-200",
            steps: [
                .init(statusCode: 503, body: Data("Service Unavailable".utf8)),
                .init(statusCode: 200, body: payload),
            ],
            maxRetryCount: 2
        )

        let task = await context.startDownload()

        #expect(await waitForTaskState(task, timeout: 20.0) { $0.isTerminal })
        #expect(await task.state == .completed)
        #expect(try Data(contentsOf: context.destinationURL) == payload)
        #expect(context.transportRequests.count == 2)
        #expect(await task.retryCount == 1)

        await context.tearDown()
    }

    @Test("A persistent 503 exhausts the retry budget without ever saving an error body")
    func persistentTransientStatusExhaustsRetryBudget() async throws {
        let step = ScriptedDownloadURLProtocol.Step(
            statusCode: 503,
            body: Data("Service Unavailable".utf8)
        )
        let context = try ScriptedDownloadContext(
            label: "status-503-exhausted",
            steps: [step, step, step, step],
            maxRetryCount: 2
        )

        let task = await context.startDownload()

        #expect(await waitForTaskState(task, timeout: 20.0) { $0.isTerminal })
        #expect(await task.state == .failed)
        guard case .maxRetriesExceeded? = await task.error else {
            Issue.record("Expected maxRetriesExceeded, got \(String(describing: await task.error))")
            await context.tearDown()
            return
        }
        // Initial attempt plus `maxRetryCount` retries.
        #expect(context.transportRequests.count == 3)
        #expect(!FileManager.default.fileExists(atPath: context.destinationURL.path))

        await context.tearDown()
    }

    // MARK: Delegate admission

    @Test("The delegate neither stages nor consumes a body whose status is unacceptable")
    func delegateDoesNotStageUnacceptableStatus() async throws {
        let fixture = try await StatusFixture(label: "status-delegate-404")

        fixture.finish(statusCode: 404)

        #expect(await waitForTaskState(fixture.task, timeout: 10.0) { $0.isTerminal })
        #expect(await fixture.task.state == .failed)
        let failure = await fixture.task.error
        if case .unacceptableStatusCode(let statusCode)? = failure {
            #expect(statusCode == 404)
        } else {
            Issue.record("Expected a typed HTTP status failure, got \(String(describing: failure))")
        }
        // The delegate must leave Foundation's temporary file alone and must
        // not create a completion journal for the rejected body.
        #expect(FileManager.default.fileExists(atPath: fixture.bodyURL.path))
        #expect(try fixture.harness.completionStager.hasArtifacts(forTaskID: fixture.task.id) == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        #expect(fixture.harness.stubSession.createdTasks.count == 1)

        await fixture.tearDown()
    }

    @Test(
        "Acceptable statuses, including the 206 of a resumed transfer, complete normally",
        arguments: [200, 204, 206]
    )
    func acceptableStatusCompletes(statusCode: Int) async throws {
        let fixture = try await StatusFixture(label: "status-delegate-\(statusCode)")

        fixture.finish(statusCode: statusCode)

        #expect(await waitForTaskState(fixture.task, timeout: 10.0) { $0.isTerminal })
        #expect(await fixture.task.state == .completed)
        #expect(try Data(contentsOf: fixture.destinationURL) == StatusFixture.body)

        await fixture.tearDown()
    }

    @Test("A non-HTTP response keeps the unvalidated completion behavior")
    func nonHTTPResponseIsNotValidated() async throws {
        let fixture = try await StatusFixture(label: "status-delegate-non-http")
        let attempt = fixture.finishedAttempt()
        attempt.scriptResponse(
            URLResponse(
                url: fixture.sourceURL,
                mimeType: "application/octet-stream",
                expectedContentLength: StatusFixture.body.count,
                textEncodingName: nil
            )
        )

        fixture.harness.delegate.handleFinishedDownload(attempt, location: fixture.bodyURL)

        #expect(await waitForTaskState(fixture.task, timeout: 10.0) { $0.isTerminal })
        #expect(await fixture.task.state == .completed)
        #expect(try Data(contentsOf: fixture.destinationURL) == StatusFixture.body)

        await fixture.tearDown()
    }

    @Test("A configured acceptable set can admit a status the default rejects")
    func configuredAcceptableSetWidensAdmission() async throws {
        let fixture = try await StatusFixture(
            label: "status-delegate-custom-accept",
            acceptableStatusCodes: [200, 404]
        )

        fixture.finish(statusCode: 404)

        #expect(await waitForTaskState(fixture.task, timeout: 10.0) { $0.isTerminal })
        #expect(await fixture.task.state == .completed)
        #expect(try Data(contentsOf: fixture.destinationURL) == StatusFixture.body)

        await fixture.tearDown()
    }

    @Test("A configured acceptable set can reject a status the default admits")
    func configuredAcceptableSetNarrowsAdmission() async throws {
        let fixture = try await StatusFixture(
            label: "status-delegate-custom-reject",
            acceptableStatusCodes: [200]
        )

        fixture.finish(statusCode: 206)

        #expect(await waitForTaskState(fixture.task, timeout: 10.0) { $0.isTerminal })
        #expect(await fixture.task.state == .failed)
        let failure = await fixture.task.error
        if case .unacceptableStatusCode(let statusCode)? = failure {
            #expect(statusCode == 206)
        } else {
            Issue.record("Expected a typed HTTP status failure, got \(String(describing: failure))")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))

        await fixture.tearDown()
    }

    @Test("The 206 that answers a resumed range request is accepted even when the configured set omits it")
    func resumedPartialContentIsAlwaysAccepted() async throws {
        let fixture = try await StatusFixture(
            label: "status-resumed-partial-content",
            acceptableStatusCodes: [200]
        )

        fixture.finish(statusCode: 206, rangeRequested: true)

        #expect(await waitForTaskState(fixture.task, timeout: 10.0) { $0.isTerminal })
        #expect(await fixture.task.state == .completed)
        #expect(try Data(contentsOf: fixture.destinationURL) == StatusFixture.body)

        await fixture.tearDown()
    }

    // MARK: Configuration plumbing

    @Test("The transfer pack carries acceptableStatusCodes into the configuration and its copies")
    func transferPackPlumbsAcceptableStatusCodes() {
        let successRange = Set(200..<300)
        #expect(DownloadConfiguration.safeDefaults().acceptableStatusCodes == successRange)
        #expect(DownloadConfiguration.advanced().acceptableStatusCodes == successRange)
        #expect(DownloadConfiguration().acceptableStatusCodes == successRange)

        let custom = DownloadConfiguration.advanced(
            transfer: DownloadTransferPack(acceptableStatusCodes: [200, 206])
        )
        #expect(custom.acceptableStatusCodes == [200, 206])
        #expect(custom.cellularEnabled().acceptableStatusCodes == [200, 206])
        #expect(custom.backgroundTransfersEnabled().acceptableStatusCodes == [200, 206])
    }

    // MARK: Typed failure

    @Test("The typed failure has a stable domain, the status as its code, and a redacted URL")
    func typedFailureContract() throws {
        let signedURL = try #require(
            URL(string: "https://cdn.example.invalid/media/file.bin?X-Amz-Signature=secret&Expires=1")
        )
        let error = DownloadHTTPStatusFailure.make(statusCode: 403, url: signedURL)

        #expect(DownloadHTTPStatusFailure.domain == "InnoNetworkDownload.HTTPStatus")
        #expect(error.domain == DownloadHTTPStatusFailure.domain)
        #expect(error.code == 403)
        #expect(DownloadHTTPStatusFailure.statusCode(from: error) == 403)
        #expect(error.message.contains("https://cdn.example.invalid/media/file.bin"))
        #expect(!error.message.contains("secret"))
        #expect(!error.message.contains("X-Amz-Signature"))

        let transportError = SendableUnderlyingError(
            domain: NSURLErrorDomain,
            code: 403,
            message: "unrelated"
        )
        #expect(DownloadHTTPStatusFailure.statusCode(from: transportError) == nil)
    }

    @Test("A refusal of an attempt resumed at a redirect target keeps its status but is never final")
    func resumedRedirectTargetRefusalIsNotTerminal() throws {
        let target = try #require(URL(string: "https://cdn.example.invalid/objects/file.bin?sig=1"))
        let refusal = DownloadHTTPStatusFailure.make(statusCode: 403, url: target, resumedAtRedirectTarget: true)
        let ordinary = DownloadHTTPStatusFailure.make(statusCode: 403, url: target)

        #expect(DownloadHTTPStatusFailure.statusCode(from: refusal) == 403)
        #expect(DownloadHTTPStatusFailure.terminalStatusCode(from: refusal) == nil)
        #expect(DownloadHTTPStatusFailure.terminalStatusCode(from: ordinary) == 403)
        #expect(DownloadError.maxRetriesExceeded(lastError: refusal).httpStatusCode == 403)
    }

    @Test("Only a ranged attempt at a target other than its source is a resumed redirect target")
    func resumedRedirectTargetNeedsRangeAndRedirect() throws {
        let source = try #require(URL(string: "https://downloads.example.invalid/file.bin"))
        let target = try #require(URL(string: "https://cdn.example.invalid/objects/file.bin?sig=1"))
        func reportedDomain(currentURL: URL, range: String?) -> String? {
            var current = URLRequest(url: currentURL)
            current.setValue(range, forHTTPHeaderField: "Range")
            let task = StubDownloadURLTask(request: URLRequest(url: source), currentRequest: current)
            task.scriptHTTPStatus(403, url: currentURL)
            let reported = OSAllocatedUnfairLock<String?>(initialState: nil)
            let callbacks = DownloadSessionDelegateCallbacks()
            callbacks.setHandlers(
                onProgress: { _, _, _, _ in },
                onCompletion: { _, _, _, _, _, error, _ in reported.withLock { $0 = error?.domain } }
            )
            let delegate = DownloadSessionDelegate(
                callbacks: callbacks,
                backgroundCompletionStore: BackgroundCompletionStore()
            )
            delegate.handleFinishedDownload(task, location: FileManager.default.temporaryDirectory)
            return reported.withLock { $0 }
        }
        let retryable = DownloadHTTPStatusFailure.resumedRedirectTargetDomain
        let terminal = DownloadHTTPStatusFailure.domain

        #expect(reportedDomain(currentURL: target, range: "bytes=1024-") == retryable)
        // A fresh attempt that followed the redirect live sends no range.
        #expect(reportedDomain(currentURL: target, range: nil) == terminal)
        // A resumed attempt at the source itself is refused for good.
        #expect(reportedDomain(currentURL: source, range: "bytes=1024-") == terminal)
    }

    // MARK: Failure classification

    @Test(
        "A deterministic status fails immediately without spending retry budget",
        arguments: [301, 400, 401, 403, 404, 410, 412, 451]
    )
    func deterministicStatusFailsWithoutRetry(statusCode: Int) async throws {
        let (coordinator, task, persistence) = await makeStatusFailureCoordinator()
        let restarts = OSAllocatedUnfairLock<Int>(initialState: 0)
        let statusError = DownloadHTTPStatusFailure.make(statusCode: statusCode, url: task.url)

        await coordinator.handleError(
            task: task,
            error: statusError,
            restart: { _ in restarts.withLock { $0 += 1 } }
        )

        #expect(restarts.withLock { $0 } == 0)
        #expect(await task.state == .failed)
        #expect(await task.retryCount == 0)
        #expect(await task.totalRetryCount == 0)
        let failure = await task.error
        if case .unacceptableStatusCode(let failedStatusCode)? = failure {
            #expect(failedStatusCode == statusCode)
            #expect(DownloadHTTPStatusFailure.statusCode(from: statusError) == statusCode)
        } else {
            Issue.record("Expected unacceptableStatusCode, got \(String(describing: failure))")
        }
        #expect(await persistence.record(forID: task.id) == nil)
    }

    @Test(
        "408, 429, 5xx and a rejected resume range (416) go through the ordinary retry path",
        arguments: [408, 416, 429, 500, 502, 503, 504, 599]
    )
    func transientStatusUsesRetryPath(statusCode: Int) async throws {
        let (coordinator, task, persistence) = await makeStatusFailureCoordinator()
        let restarts = OSAllocatedUnfairLock<Int>(initialState: 0)

        await coordinator.handleError(
            task: task,
            error: DownloadHTTPStatusFailure.make(statusCode: statusCode, url: task.url),
            restart: { _ in restarts.withLock { $0 += 1 } }
        )

        #expect(restarts.withLock { $0 } == 1)
        #expect(await task.state == .downloading)
        #expect(await task.retryCount == 1)
        #expect(await task.totalRetryCount == 1)
        #expect(await persistence.record(forID: task.id)?.lifecycle == .retryPending)
    }

    // MARK: Restoration

    @Test("A restored background attempt that finished with 403 fails instead of committing the body")
    func restoredLiveAttemptWithForbiddenStatusFails() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeStatusTestRoot("restored-live")
        defer { try? fileManager.removeItem(at: rootURL) }
        let id = "restored-live-status-\(UUID().uuidString)"
        let sourceURL = try #require(URL(string: "https://example.invalid/restored-live-status.bin"))
        let destinationURL = rootURL.appendingPathComponent("destination.bin", isDirectory: false)
        let bodyURL = rootURL.appendingPathComponent("CFNetworkDownload.tmp", isDirectory: false)
        try Data("AccessDenied".utf8).write(to: bodyURL)

        // The system task outlived the previous process and already carries
        // the server's response when the relaunched session reattaches.
        let systemTask = StubDownloadURLTask(request: URLRequest(url: sourceURL), initialState: .running)
        systemTask.taskDescription = id
        systemTask.scriptHTTPStatus(403, url: sourceURL)
        let harness = try StubDownloadHarness(
            maxRetryCount: 2,
            backgroundTransfers: true,
            label: "restored-live-status",
            persistenceBaseDirectoryURL: rootURL,
            prepopulatedRecords: [
                DownloadTaskPersistence.Record(
                    id: id,
                    url: sourceURL,
                    destinationURL: destinationURL,
                    lifecycle: .active
                )
            ],
            preinstalledStubs: [systemTask]
        )
        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: id))
        #expect(await restored.state == .downloading)

        harness.delegate.handleFinishedDownload(systemTask, location: bodyURL)

        #expect(await waitForTaskState(restored, timeout: 10.0) { $0.isTerminal })
        #expect(await restored.state == .failed)
        let failure = await restored.error
        if case .unacceptableStatusCode(let statusCode)? = failure {
            #expect(statusCode == 403)
        } else {
            Issue.record("Expected a typed HTTP status failure, got \(String(describing: failure))")
        }
        #expect(!fileManager.fileExists(atPath: destinationURL.path))
        #expect(try harness.completionStager.hasArtifacts(forTaskID: id) == false)
        #expect(harness.stubSession.createdTasks.isEmpty)

        await harness.manager.shutdown()
    }

    @Test("A 403 delivered for a restored task with no surviving system task never completes it")
    func restoredOrphanWithForbiddenStatusIsNotCompleted() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeStatusTestRoot("restored-orphan")
        defer { try? fileManager.removeItem(at: rootURL) }
        let id = "restored-orphan-status-\(UUID().uuidString)"
        let sourceURL = try #require(URL(string: "https://example.invalid/restored-orphan-status.bin"))
        let destinationURL = rootURL.appendingPathComponent("destination.bin", isDirectory: false)
        let bodyURL = rootURL.appendingPathComponent("CFNetworkDownload.tmp", isDirectory: false)
        try Data("AccessDenied".utf8).write(to: bodyURL)

        let harness = try StubDownloadHarness(
            maxRetryCount: 0,
            backgroundTransfers: true,
            label: "restored-orphan-status",
            persistenceBaseDirectoryURL: rootURL,
            prepopulatedRecords: [
                DownloadTaskPersistence.Record(
                    id: id,
                    url: sourceURL,
                    destinationURL: destinationURL,
                    lifecycle: .active
                )
            ]
        )
        #expect(await harness.manager.waitForRestoration())
        let restored = try #require(await harness.manager.task(withId: id))
        #expect(await restored.state == .failed)

        // Background relaunch: Foundation redelivers the finished attempt
        // before `didFinishEvents`. A staged success would reopen and commit
        // the provisional orphan, so the 403 must not be staged at all.
        let finished = StubDownloadURLTask(request: URLRequest(url: sourceURL))
        finished.taskDescription = id
        finished.scriptHTTPStatus(403, url: sourceURL)
        harness.delegate.handleFinishedDownload(finished, location: bodyURL)
        harness.injectBackgroundEventsFinished()

        #expect(
            await waitForStatusCondition {
                await harness.persistence.record(forID: id) == nil
            }
        )
        #expect(await restored.state == .failed)
        guard case .restorationMissingSystemTask? = await restored.error else {
            Issue.record("Unexpected restored failure: \(String(describing: await restored.error))")
            await harness.manager.shutdown()
            return
        }
        #expect(!fileManager.fileExists(atPath: destinationURL.path))
        #expect(try harness.completionStager.hasArtifacts(forTaskID: id) == false)

        await harness.manager.shutdown()
    }
}


// MARK: - Helpers

/// One started download whose attempt is reported finished through the
/// production delegate with a scripted HTTP status.
private struct StatusFixture {
    static let body = Data("scripted-download-body".utf8)

    let harness: StubDownloadHarness
    let task: DownloadTask
    let attemptIdentifier: Int
    let rootURL: URL
    let sourceURL: URL
    let destinationURL: URL
    let bodyURL: URL

    init(
        label: String,
        acceptableStatusCodes: Set<Int> = DownloadHTTPStatusFailure.defaultAcceptableStatusCodes
    ) async throws {
        let rootURL = try makeStatusTestRoot(label)
        self.rootURL = rootURL
        self.sourceURL = try #require(URL(string: "https://example.invalid/\(label).bin"))
        self.destinationURL = rootURL.appendingPathComponent("destination.bin", isDirectory: false)
        self.bodyURL = rootURL.appendingPathComponent("CFNetworkDownload.tmp", isDirectory: false)
        try Self.body.write(to: bodyURL)

        let harness = try StubDownloadHarness(
            maxRetryCount: 2,
            acceptableStatusCodes: acceptableStatusCodes,
            label: label,
            persistenceBaseDirectoryURL: rootURL
        )
        self.harness = harness
        let task = await harness.startDownload(url: sourceURL, destinationURL: destinationURL)
        self.task = task
        self.attemptIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task, timeout: 10.0)
        )
        #expect(await waitForTaskState(task, timeout: 10.0) { $0 == .downloading })
    }

    /// A stand-in for the registered attempt as Foundation would present it
    /// to the delegate: same identifier, retained request, and task id.
    func finishedAttempt(rangeRequested: Bool = false) -> StubDownloadURLTask {
        var request = URLRequest(url: sourceURL)
        if rangeRequested {
            // A task Foundation rebuilds from resume data asks for the rest.
            request.setValue("bytes=1024-", forHTTPHeaderField: "Range")
        }
        let attempt = StubDownloadURLTask(
            taskIdentifier: attemptIdentifier,
            request: request
        )
        attempt.taskDescription = task.id
        return attempt
    }

    func finish(statusCode: Int, rangeRequested: Bool = false) {
        let attempt = finishedAttempt(rangeRequested: rangeRequested)
        attempt.scriptHTTPStatus(statusCode, url: sourceURL)
        harness.delegate.handleFinishedDownload(attempt, location: bodyURL)
    }

    func tearDown() async {
        await harness.manager.shutdown()
        try? FileManager.default.removeItem(at: rootURL)
    }
}


private func makeStatusTestRoot(_ label: String) throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "inno-download-status-\(label)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return rootURL
}


/// A failure coordinator with zero retry delay around one task whose
/// in-memory state and durable phase the caller chooses.
func makeStatusFailureCoordinator(
    state: DownloadState = .downloading,
    lifecycle: DownloadTaskPersistence.Record.Lifecycle = .active
) async -> (
    DownloadFailureCoordinator, DownloadTask, DownloadTaskPersistence
) {
    let configuration = DownloadConfiguration(
        maxRetryCount: 3,
        maxTotalRetries: 3,
        retryDelay: 0,
        sessionIdentifier: makeDownloadTestSessionIdentifier("status-coordinator"),
        networkMonitor: nil
    )
    let runtimeRegistry = DownloadRuntimeRegistry()
    let task = DownloadTask(
        url: URL(string: "https://example.invalid/status.bin")!,
        destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).bin")
    )
    let persistence = DownloadTaskPersistence(
        store: InMemoryDownloadTaskStore(
            seed: [
                DownloadTaskPersistence.Record(
                    id: task.id,
                    url: task.url,
                    destinationURL: task.destinationURL,
                    lifecycle: lifecycle
                )
            ]
        )
    )
    let coordinator = DownloadFailureCoordinator(
        configuration: configuration,
        runtimeRegistry: runtimeRegistry,
        persistence: persistence,
        eventHub: TaskEventHub<DownloadEvent>(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .downloadTask
        ),
        clock: TestClock()
    )
    await runtimeRegistry.add(task)
    await task.restoreState(state)
    return (coordinator, task, persistence)
}


private func waitForStatusCondition(
    timeout: Duration = .seconds(10),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
