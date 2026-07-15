import Foundation
import Testing

@testable import InnoNetwork
@testable import InnoNetworkDownload

@Suite("Download terminal event admission", .serialized)
struct DownloadTerminalEventAdmissionTests {
    private let saturatedPolicy = EventDeliveryPolicy(
        maxBufferedEventsPerPartition: 1,
        maxBufferedEventsPerConsumer: 1,
        overflowPolicy: .dropNewest
    )

    @Test("Completed remains observable when dropNewest queues are saturated")
    func completedIsGuaranteed() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 0,
            maxTotalRetries: 0,
            eventDeliveryPolicy: saturatedPolicy,
            label: "terminal-completed"
        )
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-terminal-completed-\(UUID().uuidString).data",
            isDirectory: false
        )
        let task = await harness.startDownload(destinationURL: destinationURL)
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        let recorder = BlockingDownloadEventRecorder()
        await saturateConsumer(for: task, manager: harness.manager, recorder: recorder)

        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-terminal-source-\(UUID().uuidString).data",
            isDirectory: false
        )
        try Data("payload".utf8).write(to: temporaryURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }

        await harness.injectCompletion(taskIdentifier: taskIdentifier, location: temporaryURL)
        await recorder.release()

        #expect(await recorder.waitForTerminal(.completed))
        await harness.manager.shutdown()
    }

    @Test("Failed remains observable when dropNewest queues are saturated")
    func failedIsGuaranteed() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 0,
            maxTotalRetries: 0,
            eventDeliveryPolicy: saturatedPolicy,
            label: "terminal-failed"
        )
        let task = await harness.startDownload()
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        let recorder = BlockingDownloadEventRecorder()
        await saturateConsumer(for: task, manager: harness.manager, recorder: recorder)

        await harness.injectCompletion(
            taskIdentifier: taskIdentifier,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.timedOut.rawValue,
                message: "timed out"
            )
        )
        await recorder.release()

        #expect(await recorder.waitForTerminal(.failed))
        await harness.manager.shutdown()
    }

    @Test("Shutdown publishes cancelled before closing a saturated partition")
    func shutdownCancellationIsGuaranteed() async throws {
        let harness = try StubDownloadHarness(
            eventDeliveryPolicy: saturatedPolicy,
            label: "terminal-shutdown-cancelled"
        )
        let task = await harness.startDownload()
        let recorder = BlockingDownloadEventRecorder()
        await saturateConsumer(for: task, manager: harness.manager, recorder: recorder)

        await harness.manager.shutdown()
        await recorder.release()

        #expect(await recorder.waitForTerminal(.cancelled))
        #expect(await task.state == .cancelled)
        let taskError = await task.error
        let isCancelledError: Bool
        if case .cancelled = taskError {
            isCancelledError = true
        } else {
            isCancelledError = false
        }
        #expect(isCancelledError)
    }

    @Test("A subscriber attaching after completion receives the retained terminal event and end-of-stream")
    func lateCompletionSubscriberReceivesTerminalReplay() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 0,
            maxTotalRetries: 0,
            label: "terminal-late-subscriber"
        )
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-terminal-late-\(UUID().uuidString).data",
            isDirectory: false
        )
        let task = await harness.startDownload(destinationURL: destinationURL)
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-terminal-late-source-\(UUID().uuidString).data",
            isDirectory: false
        )
        try Data("payload".utf8).write(to: temporaryURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }

        await harness.injectCompletion(taskIdentifier: taskIdentifier, location: temporaryURL)
        #expect(await task.state == .completed)

        let stream = await harness.manager.events(for: task)
        var iterator = stream.makeAsyncIterator()
        let terminal = await iterator.next()
        if case .completed(let location) = terminal {
            #expect(location == destinationURL)
        } else {
            Issue.record("late subscriber did not receive the retained completed event")
        }
        if case .some = await iterator.next() {
            Issue.record("late subscriber stream did not finish after the terminal event")
        }

        await harness.manager.shutdown()
    }

    @Test("Late delegate progress and completion cannot mutate a cancelled task")
    func lateDelegateEventsCannotReopenCancelledTask() async throws {
        let harness = try StubDownloadHarness(label: "terminal-late-delegate")
        let task = await harness.startDownload()
        defer { try? FileManager.default.removeItem(at: task.destinationURL) }
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        await harness.manager.cancel(task)

        await harness.manager.handleProgress(
            taskIdentifier: taskIdentifier,
            bytesWritten: 9,
            totalBytesWritten: 9,
            totalBytesExpectedToWrite: 10
        )
        let progress = await task.progress
        #expect(progress.totalBytesWritten == 0)

        let lateLocation = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-terminal-late-delegate-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try Data("late".utf8).write(to: lateLocation)
        await harness.manager.handleCompletion(
            taskIdentifier: taskIdentifier,
            location: lateLocation,
            error: nil
        )

        #expect(await task.state == .cancelled)
        #expect(FileManager.default.fileExists(atPath: lateLocation.path) == false)
        #expect(FileManager.default.fileExists(atPath: task.destinationURL.path) == false)
        await harness.manager.shutdown()
    }

    private func saturateConsumer(
        for task: DownloadTask,
        manager: DownloadManager,
        recorder: BlockingDownloadEventRecorder
    ) async {
        #expect(await task.state == .downloading)
        _ = await manager.addEventListener(for: task) { event in
            await recorder.record(event)
        }
        #expect(await manager.listenerCount(for: task) == 1)

        let progress = DownloadProgress(
            bytesWritten: 1,
            totalBytesWritten: 1,
            totalBytesExpectedToWrite: 10
        )
        // Startup state events can still be draining when `startDownload`
        // returns. Guarantee this first test event's admission so a saturated
        // `.dropNewest` partition cannot make the synchronization point
        // scheduler-dependent.
        await manager.eventHub.publishTerminalAndWaitForEnqueue(
            .progress(progress),
            for: task.id
        )
        #expect(await recorder.waitUntilBlocked())

        // The listener is handling the first event. These events fill both
        // bounded stages (partition and listener) so a normal `.dropNewest`
        // terminal publish would be discarded.
        await manager.eventHub.publish(.progress(progress), for: task.id)
        await manager.eventHub.publish(.progress(progress), for: task.id)
    }
}


private enum ExpectedDownloadTerminal: Sendable {
    case completed
    case failed
    case cancelled

    func matches(_ event: DownloadEvent) -> Bool {
        switch (self, event) {
        case (.completed, .completed), (.failed, .failed), (.cancelled, .stateChanged(.cancelled)):
            return true
        default:
            return false
        }
    }
}


private actor BlockingDownloadEventRecorder {
    private var events: [DownloadEvent] = []
    private var hasBlockedFirstEvent = false
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func record(_ event: DownloadEvent) async {
        if !hasBlockedFirstEvent {
            hasBlockedFirstEvent = true
            await waitForRelease()
        }
        events.append(event)
    }

    func waitUntilBlocked(timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if hasBlockedFirstEvent { return true }
            await Task.yield()
        }
        return hasBlockedFirstEvent
    }

    func release() {
        isReleased = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }

    func waitForTerminal(
        _ expected: ExpectedDownloadTerminal,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if events.contains(where: expected.matches) {
                return true
            }
            await Task.yield()
        }
        return events.contains(where: expected.matches)
    }

    private func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}
