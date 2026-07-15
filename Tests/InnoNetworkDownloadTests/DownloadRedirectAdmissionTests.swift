import Foundation
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkDownload

@Suite("Download redirect admission", .serialized)
struct DownloadRedirectAdmissionTests {
    @Test("Same-origin HTTPS redirect is admitted")
    func sameOriginHTTPSRedirectIsAdmitted() throws {
        let source = URL(string: "https://downloads.example.com/start")!
        let target = URL(string: "https://downloads.example.com/files/archive.zip")!
        let context = makeDelegateContext()
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: source)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        context.delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(url: source, statusCode: 302, target: target),
            newRequest: URLRequest(url: target),
            completionHandler: context.redirects.record
        )

        let decision = try #require(context.redirects.decisions.first)
        guard case .follow(let request) = decision else {
            Issue.record("Expected the same-origin HTTPS redirect to be followed")
            return
        }
        #expect(request.url == target)
        #expect(context.completions.records.isEmpty)
    }

    @Test("Plain HTTP redirect requires the download configuration opt-in")
    func plainHTTPRedirectRequiresOptIn() throws {
        let source = URL(string: "http://downloads.example.com/start")!
        let target = URL(string: "http://downloads.example.com/files/archive.zip")!

        let denied = makeDelegateContext(allowsInsecureHTTP: false)
        let deniedSession = URLSession(configuration: .ephemeral)
        let deniedTask = deniedSession.downloadTask(with: source)
        defer {
            deniedTask.cancel()
            deniedSession.invalidateAndCancel()
        }
        denied.delegate.urlSession(
            deniedSession,
            task: deniedTask,
            willPerformHTTPRedirection: redirectResponse(url: source, statusCode: 302, target: target),
            newRequest: URLRequest(url: target),
            completionHandler: denied.redirects.record
        )

        guard case .reject = try #require(denied.redirects.decisions.first) else {
            Issue.record("Expected HTTP redirect admission to fail without opt-in")
            return
        }
        #expect(denied.completions.records.first?.error?.domain == DownloadRedirectAdmissionFailure.domain)

        let allowed = makeDelegateContext(allowsInsecureHTTP: true)
        let allowedSession = URLSession(configuration: .ephemeral)
        let allowedTask = allowedSession.downloadTask(with: source)
        defer {
            allowedTask.cancel()
            allowedSession.invalidateAndCancel()
        }
        allowed.delegate.urlSession(
            allowedSession,
            task: allowedTask,
            willPerformHTTPRedirection: redirectResponse(url: source, statusCode: 302, target: target),
            newRequest: URLRequest(url: target),
            completionHandler: allowed.redirects.record
        )

        guard case .follow(let request) = try #require(allowed.redirects.decisions.first) else {
            Issue.record("Expected HTTP redirect admission with explicit opt-in")
            return
        }
        #expect(request.url == target)
        #expect(allowed.completions.records.isEmpty)
    }

    @Test("HTTPS downgrade and cross-origin unsafe replay are rejected")
    func unsafeRedirectPoliciesAreRejected() throws {
        let cases: [(source: URL, target: URL, statusCode: Int)] = [
            (
                URL(string: "https://downloads.example.com/start")!,
                URL(string: "http://downloads.example.com/archive.zip")!,
                302
            ),
            (
                URL(string: "https://downloads.example.com/start")!,
                URL(string: "https://cdn.example.net/archive.zip")!,
                307
            ),
        ]

        for testCase in cases {
            let context = makeDelegateContext(allowsInsecureHTTP: true)
            let session = URLSession(configuration: .ephemeral)
            var request = URLRequest(url: testCase.source)
            request.httpMethod = "POST"
            let task = session.downloadTask(with: request)
            defer {
                task.cancel()
                session.invalidateAndCancel()
            }
            var redirectedRequest = URLRequest(url: testCase.target)
            redirectedRequest.httpMethod = "POST"

            context.delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: redirectResponse(
                    url: testCase.source,
                    statusCode: testCase.statusCode,
                    target: testCase.target
                ),
                newRequest: redirectedRequest,
                completionHandler: context.redirects.record
            )

            guard case .reject = try #require(context.redirects.decisions.first) else {
                Issue.record("Expected unsafe redirect to be rejected: \(testCase.target)")
                continue
            }
            #expect(context.completions.records.count == 1)
            #expect(context.completions.records.first?.error?.domain == DownloadRedirectAdmissionFailure.domain)
        }
    }

    @Test("Redirect fails closed when a resumed task has no retained origin")
    func missingRetainedOriginIsRejected() throws {
        let source = URL(string: "https://downloads.example.com/start")!
        let target = URL(string: "https://downloads.example.com/archive.zip")!
        let context = makeDelegateContext()
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(withResumeData: Data())
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        #expect(task.originalRequest?.url == nil)
        #expect(task.currentRequest?.url == nil)

        context.delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(url: source, statusCode: 302, target: target),
            newRequest: URLRequest(url: target),
            completionHandler: context.redirects.record
        )

        guard case .reject = try #require(context.redirects.decisions.first) else {
            Issue.record("Expected missing retained origin to fail closed")
            return
        }
        #expect(context.completions.records.count == 1)
        #expect(context.completions.records.first?.error?.domain == DownloadRedirectAdmissionFailure.domain)
    }

    @Test("Traversal redirect reports one typed failure and suppresses later URLSession completions")
    func traversalRedirectProducesOneTypedFailure() throws {
        let source = URL(string: "https://downloads.example.com/start")!
        let target = URL(string: "https://downloads.example.com/files/%252e%252e/private.zip")!
        let context = makeDelegateContext()
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: source)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        context.delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(url: source, statusCode: 302, target: target),
            newRequest: URLRequest(url: target),
            completionHandler: context.redirects.record
        )

        guard case .reject = try #require(context.redirects.decisions.first) else {
            Issue.record("Expected traversal redirect to be rejected")
            return
        }
        let redirectFailure = try #require(context.completions.records.first?.error)
        #expect(redirectFailure.domain == DownloadRedirectAdmissionFailure.domain)
        #expect(redirectFailure.code == DownloadRedirectAdmissionFailure.code)
        #expect(task.state == .canceling)

        let temporaryLocation = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rejected-download-\(UUID().uuidString).tmp"
        )
        try Data("redirect response".utf8).write(to: temporaryLocation)
        defer { try? FileManager.default.removeItem(at: temporaryLocation) }
        context.delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: temporaryLocation)
        context.delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))

        #expect(context.completions.records.count == 1)
        #expect(FileManager.default.fileExists(atPath: temporaryLocation.path))
    }

    @Test("Redirect admission failure becomes invalidURL without retry")
    func redirectAdmissionFailureDoesNotRetry() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 0,
            label: "redirect-admission"
        )
        let task = await harness.startDownload()
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        let target = URL(string: "https://downloads.example.com/%2e%2e/private.zip")!

        await harness.injectCompletion(
            taskIdentifier: identifier,
            originalRequestURL: task.url,
            currentRequestURL: target,
            usesLastRequestURLs: false,
            error: DownloadRedirectAdmissionFailure.make(
                targetURL: target,
                reason: "The redirect target failed network URL admission."
            )
        )

        #expect(await waitForTaskState(task) { $0 == .failed })
        guard case .invalidURL(let description) = await task.error else {
            Issue.record("Expected DownloadError.invalidURL")
            return
        }
        #expect(description.contains("Rejected redirect target"))
        #expect(await task.retryCount == 0)
        #expect(await task.totalRetryCount == 0)
        #expect(harness.stubSession.createdTasks.count == 1)
    }

    @Test("Mapped success fails closed when the final URL snapshot is missing")
    func mappedSuccessRejectsMissingFinalURL() async throws {
        let fileManager = FileManager.default
        let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(
            "mapped-missing-final-success-\(UUID().uuidString).tmp"
        )
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(
            "mapped-missing-final-success-\(UUID().uuidString).bin"
        )
        try Data("mapped-success".utf8).write(to: stagedURL)
        defer {
            try? fileManager.removeItem(at: stagedURL)
            try? fileManager.removeItem(at: destinationURL)
        }

        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            label: "mapped-missing-final-success"
        )
        let task = await harness.startDownload(destinationURL: destinationURL)
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )

        await harness.injectCompletion(
            taskIdentifier: identifier,
            originalRequestURL: task.url,
            currentRequestURL: nil,
            usesLastRequestURLs: false,
            location: stagedURL
        )

        #expect(await waitForTaskState(task) { $0 == .failed })
        guard case .invalidURL? = await task.error else {
            Issue.record("Expected missing mapped final URL to fail as invalidURL")
            await harness.manager.shutdown()
            return
        }
        #expect(await task.retryCount == 0)
        #expect(await task.totalRetryCount == 0)
        #expect(fileManager.fileExists(atPath: stagedURL.path) == false)
        #expect(fileManager.fileExists(atPath: destinationURL.path) == false)
        await harness.manager.shutdown()
    }

    @Test("Mapped transport error fails closed when the final URL snapshot is missing")
    func mappedErrorRejectsMissingFinalURL() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            label: "mapped-missing-final-error"
        )
        let task = await harness.startDownload()
        let identifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )

        await harness.injectCompletion(
            taskIdentifier: identifier,
            originalRequestURL: task.url,
            currentRequestURL: nil,
            usesLastRequestURLs: false,
            error: SendableUnderlyingError(URLError(.timedOut))
        )

        #expect(await waitForTaskState(task) { $0 == .failed })
        guard case .invalidURL? = await task.error else {
            Issue.record("Expected missing mapped final URL to replace the transport error")
            await harness.manager.shutdown()
            return
        }
        #expect(await task.retryCount == 0)
        #expect(await task.totalRetryCount == 0)
        await harness.manager.shutdown()
    }

    @Test("Restored fallback ignores an unsafe final URL without consuming restoration failure")
    func restoredFallbackIgnoresUnsafeFinalURL() async throws {
        let source = URL(string: "https://example.invalid/start.zip")!
        let unsafeFinal = URL(string: "http://example.invalid/final.zip")!
        let context = try await makeRestoredCompletionContext(
            label: "unsafe-final",
            sourceURL: source
        )
        defer { try? FileManager.default.removeItem(at: context.rootURL) }

        await context.harness.injectCompletion(
            taskIdentifier: 71_001,
            taskDescription: context.task.id,
            originalRequestURL: source,
            currentRequestURL: unsafeFinal,
            usesLastRequestURLs: false,
            location: context.stagedURL
        )

        #expect(await waitForTaskState(context.task) { $0 == .failed })
        guard case .restorationMissingSystemTask? = await context.task.error else {
            Issue.record("Expected the unsafe fallback to preserve restorationMissingSystemTask")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: context.stagedURL.path))
        #expect(!FileManager.default.fileExists(atPath: context.destinationURL.path))
        #expect(await context.harness.manager.runtimeTaskIdentifier(for: context.task) == nil)
        await context.harness.manager.shutdown()
    }

    @Test("Restored completion ignores an admitted redirected final URL after the restoration boundary")
    func restoredCompletionIgnoresAdmittedRedirectAfterBoundary() async throws {
        let source = URL(string: "https://example.invalid/start.zip")!
        let admittedFinal = URL(string: "https://cdn.example.invalid/archive.zip")!
        let context = try await makeRestoredCompletionContext(
            label: "admitted-final",
            sourceURL: source
        )
        defer { try? FileManager.default.removeItem(at: context.rootURL) }

        await context.harness.injectCompletion(
            taskIdentifier: 71_002,
            taskDescription: context.task.id,
            originalRequestURL: source,
            currentRequestURL: admittedFinal,
            usesLastRequestURLs: false,
            location: context.stagedURL
        )

        #expect(await context.task.state == .failed)
        guard case .restorationMissingSystemTask? = await context.task.error else {
            Issue.record("Expected the late admitted redirect to preserve restorationMissingSystemTask")
            await context.harness.manager.shutdown()
            return
        }
        #expect(!FileManager.default.fileExists(atPath: context.stagedURL.path))
        #expect(!FileManager.default.fileExists(atPath: context.destinationURL.path))
        #expect(await context.harness.manager.runtimeTaskIdentifier(for: context.task) == nil)
        await context.harness.manager.shutdown()
    }

    @Test("Restored fallback ignores a missing final URL without consuming restoration failure")
    func restoredFallbackIgnoresMissingFinalURL() async throws {
        let source = URL(string: "https://example.invalid/start.zip")!
        let context = try await makeRestoredCompletionContext(
            label: "missing-final",
            sourceURL: source
        )
        defer { try? FileManager.default.removeItem(at: context.rootURL) }

        await context.harness.injectCompletion(
            taskIdentifier: 71_003,
            taskDescription: context.task.id,
            originalRequestURL: source,
            currentRequestURL: nil,
            usesLastRequestURLs: false,
            location: context.stagedURL
        )

        #expect(await waitForTaskState(context.task) { $0 == .failed })
        guard case .restorationMissingSystemTask? = await context.task.error else {
            Issue.record("Expected the missing-URL fallback to preserve restorationMissingSystemTask")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: context.stagedURL.path))
        #expect(!FileManager.default.fileExists(atPath: context.destinationURL.path))
        #expect(await context.harness.manager.runtimeTaskIdentifier(for: context.task) == nil)
        await context.harness.manager.shutdown()
    }

    @Test("Rejected redirect diagnostics redact credentials, query, and fragment")
    func rejectedRedirectDiagnosticsRedactSecrets() throws {
        let target = try #require(
            URL(string: "https://alice:s3cr3t@downloads.example.com/file.zip?token=secret#oauth-state")
        )

        let failure = DownloadRedirectAdmissionFailure.make(
            targetURL: target,
            reason: "Rejected by policy."
        )

        #expect(failure.message.contains("downloads.example.com/file.zip"))
        #expect(failure.message.contains("alice") == false)
        #expect(failure.message.contains("s3cr3t") == false)
        #expect(failure.message.contains("token") == false)
        #expect(failure.message.contains("oauth-state") == false)
    }
}

private struct RestoredCompletionContext {
    let harness: StubDownloadHarness
    let task: DownloadTask
    let rootURL: URL
    let stagedURL: URL
    let destinationURL: URL
}

private func makeRestoredCompletionContext(
    label: String,
    sourceURL: URL
) async throws -> RestoredCompletionContext {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "download-restored-completion-\(label)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let destinationURL = rootURL.appendingPathComponent("destination.zip")
    let stagedURL = rootURL.appendingPathComponent("staged.tmp")
    try Data("restored payload".utf8).write(to: stagedURL)
    let taskID = "restored-completion-\(label)-\(UUID().uuidString)"
    let record = DownloadTaskPersistence.Record(
        id: taskID,
        url: sourceURL,
        destinationURL: destinationURL,
        lifecycle: .active
    )
    let harness = try StubDownloadHarness(
        maxRetryCount: 0,
        label: "restored-completion-\(label)",
        prepopulatedRecords: [record]
    )
    #expect(await harness.manager.waitForRestoration())
    let task = try #require(await harness.manager.task(withId: taskID))
    #expect(await task.state == .failed)
    return RestoredCompletionContext(
        harness: harness,
        task: task,
        rootURL: rootURL,
        stagedURL: stagedURL,
        destinationURL: destinationURL
    )
}


private struct DelegateCompletionRecord: Sendable {
    let taskIdentifier: Int
    let location: URL?
    let error: SendableUnderlyingError?
}


private final class DelegateCompletionRecorder: Sendable {
    private let lock = OSAllocatedUnfairLock<[DelegateCompletionRecord]>(initialState: [])

    var records: [DelegateCompletionRecord] { lock.withLock { $0 } }

    func record(
        taskIdentifier: Int,
        taskDescription _: String?,
        originalRequestURL _: URL?,
        currentRequestURL _: URL?,
        payload: DownloadCompletionPayload?,
        error: SendableUnderlyingError?
    ) {
        lock.withLock {
            $0.append(
                DelegateCompletionRecord(
                    taskIdentifier: taskIdentifier,
                    location: payload?.locationURL,
                    error: error
                )
            )
        }
    }
}


private final class RedirectDecisionRecorder: Sendable {
    enum Decision: Sendable {
        case follow(URLRequest)
        case reject
    }

    private let lock = OSAllocatedUnfairLock<[Decision]>(initialState: [])

    var decisions: [Decision] { lock.withLock { $0 } }

    func record(_ request: URLRequest?) {
        lock.withLock {
            $0.append(request.map(Decision.follow) ?? .reject)
        }
    }
}


private struct DelegateContext {
    let delegate: DownloadSessionDelegate
    let completions: DelegateCompletionRecorder
    let redirects: RedirectDecisionRecorder
}


private func makeDelegateContext(allowsInsecureHTTP: Bool = false) -> DelegateContext {
    let callbacks = DownloadSessionDelegateCallbacks()
    let completions = DelegateCompletionRecorder()
    callbacks.setHandlers(
        onProgress: { _, _, _, _ in },
        onCompletion: completions.record
    )
    let redirects = RedirectDecisionRecorder()
    return DelegateContext(
        delegate: DownloadSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: BackgroundCompletionStore(),
            allowsInsecureHTTP: allowsInsecureHTTP
        ),
        completions: completions,
        redirects: redirects
    )
}


private func redirectResponse(url: URL, statusCode: Int, target: URL) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.absoluteString]
    )!
}
