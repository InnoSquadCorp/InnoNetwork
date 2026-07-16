import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download Callback Delivery Queue Tests", .serialized)
struct DownloadCallbackDeliveryQueueTests {

    @Test("callbacks for one task retain enqueue order behind a suspended callback")
    func perTaskCallbacksRetainOrder() async throws {
        let runtimeRegistry = DownloadRuntimeRegistry()
        let queue = DownloadCallbackDeliveryQueue(runtimeRegistry: runtimeRegistry)
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/callback-order.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-callback-order.bin")
        )
        let recorder = CallbackOrderRecorder()
        let progressGate = CallbackBlocker()

        await runtimeRegistry.setOnProgress { _, _ in
            await recorder.append("progress-start")
            await progressGate.block()
            await recorder.append("progress-end")
        }
        await runtimeRegistry.setOnStateChanged { _, state in
            await recorder.append("state-\(state.rawValue)")
        }
        await runtimeRegistry.setOnCompleted { _, _ in
            await recorder.append("completed")
        }

        await queue.enqueueProgress(task, .zero)
        await queue.enqueueStateChanged(task, .completed)
        await queue.enqueueCompleted(task, task.destinationURL)

        #expect(await waitForCallbackCondition { await progressGate.isStarted })
        #expect(await recorder.entries == ["progress-start"])

        await progressGate.release()
        await queue.finishAndDrain()

        #expect(
            await recorder.entries
                == ["progress-start", "progress-end", "state-completed", "completed"]
        )
    }

    @Test("queued callbacks retain the handler snapshotted at enqueue time")
    func queuedCallbackRetainsHandlerSnapshot() async throws {
        let runtimeRegistry = DownloadRuntimeRegistry()
        let queue = DownloadCallbackDeliveryQueue(runtimeRegistry: runtimeRegistry)
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/callback-snapshot.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-callback-snapshot.bin")
        )
        let progressGate = CallbackBlocker()
        let recorder = CallbackOrderRecorder()

        await runtimeRegistry.setOnProgress { _, _ in
            await progressGate.block()
        }
        await runtimeRegistry.setOnStateChanged { _, _ in
            await recorder.append("old-handler")
        }

        await queue.enqueueProgress(task, .zero)
        #expect(await waitForCallbackCondition { await progressGate.isStarted })
        await queue.enqueueStateChanged(task, .paused)

        await runtimeRegistry.setOnStateChanged { _, _ in
            await recorder.append("new-handler")
        }
        await progressGate.release()
        await queue.finishAndDrain()

        #expect(await recorder.entries == ["old-handler"])
    }

    @Test("same-task admission reentrancy runs inline without self-deadlock")
    func sameTaskAdmissionCycleRunsInline() async throws {
        let runtimeRegistry = DownloadRuntimeRegistry()
        let queue = DownloadCallbackDeliveryQueue(runtimeRegistry: runtimeRegistry)
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/callback-self-cycle.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-callback-self-cycle.bin")
        )
        let recorder = CallbackOrderRecorder()

        await runtimeRegistry.setOnStateChanged { callbackTask, state in
            switch state {
            case .waiting:
                await recorder.append("outer-start")
                await queue.enqueueStateChangedAndWait(callbackTask, .downloading)
                await recorder.append("outer-end")
            case .downloading:
                await recorder.append("nested-admission")
            default:
                break
            }
        }

        await queue.enqueueStateChanged(task, .waiting)
        let completed = await waitForCallbackCondition {
            await recorder.entries == ["outer-start", "nested-admission", "outer-end"]
        }
        #expect(completed)
        if completed {
            await queue.finishAndDrain()
        }
    }

    @Test("cross-task admission cycle runs only the closing edge inline")
    func crossTaskAdmissionCycleDoesNotDeadlock() async throws {
        let runtimeRegistry = DownloadRuntimeRegistry()
        let queue = DownloadCallbackDeliveryQueue(runtimeRegistry: runtimeRegistry)
        let firstTask = DownloadTask(
            url: URL(string: "https://example.invalid/callback-cycle-a.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-callback-cycle-a.bin")
        )
        let secondTask = DownloadTask(
            url: URL(string: "https://example.invalid/callback-cycle-b.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-callback-cycle-b.bin")
        )
        let rendezvous = CallbackRendezvous(expectedCount: 2)
        let recorder = CallbackOrderRecorder()

        await runtimeRegistry.setOnStateChanged { callbackTask, state in
            let isFirst = callbackTask.id == firstTask.id
            let label = isFirst ? "A" : "B"
            switch state {
            case .waiting:
                await recorder.append("\(label)-outer-start")
                await rendezvous.arriveAndWait()
                await queue.enqueueStateChangedAndWait(
                    isFirst ? secondTask : firstTask,
                    .downloading
                )
                await recorder.append("\(label)-outer-end")
            case .downloading:
                await recorder.append("\(label)-nested-admission")
            default:
                break
            }
        }

        await queue.enqueueStateChanged(firstTask, .waiting)
        await queue.enqueueStateChanged(secondTask, .waiting)

        let expectedEntries: Set<String> = [
            "A-outer-start",
            "A-nested-admission",
            "A-outer-end",
            "B-outer-start",
            "B-nested-admission",
            "B-outer-end",
        ]
        let completed = await waitForCallbackCondition {
            let entries = await recorder.entries
            return entries.count == expectedEntries.count && Set(entries) == expectedEntries
        }
        #expect(completed)
        if completed {
            await queue.finishAndDrain()
        }
    }

    @Test("a blocked progress callback does not hold completion lifecycle or background completion")
    func blockedProgressDoesNotHoldDelegateFIFO() async throws {
        let fileManager = FileManager.default
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(
            "callback-progress-destination-\(UUID().uuidString).bin"
        )
        let temporaryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "callback-progress-source-\(UUID().uuidString).tmp"
        )
        try Data("callback-progress".utf8).write(to: temporaryURL)
        defer {
            try? fileManager.removeItem(at: temporaryURL)
            try? fileManager.removeItem(at: destinationURL)
        }

        let harness = try StubDownloadHarness(
            backgroundTransfers: true,
            label: "callback-progress-background"
        )
        let progressGate = CallbackBlocker()
        let completed = CallbackSignal()
        let backgroundCompleted = CallbackSignal()
        await harness.manager.setOnProgressHandler { _, _ in
            await progressGate.block()
        }
        await harness.manager.setOnCompletedHandler { _, _ in
            await completed.mark()
        }
        harness.handleBackgroundSessionCompletion {
            Task { await backgroundCompleted.mark() }
        }

        let task = await harness.startDownload(destinationURL: destinationURL)
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.injectDelegateProgress(
            taskIdentifier: taskIdentifier,
            bytesWritten: 1,
            totalBytesWritten: 1,
            totalBytesExpectedToWrite: 2
        )
        #expect(await waitForCallbackCondition { await progressGate.isStarted })

        harness.injectDelegateCompletion(
            taskIdentifier: taskIdentifier,
            location: temporaryURL
        )
        harness.injectBackgroundEventsFinished()

        #expect(await waitForCallbackCondition { await backgroundCompleted.isMarked })
        #expect(await waitForTaskState(task) { $0 == .completed })
        #expect(fileManager.fileExists(atPath: destinationURL.path))
        #expect(await completed.isMarked == false)
        #expect(await progressGate.isFinished == false)

        await progressGate.release()
        #expect(await waitForCallbackCondition { await completed.isMarked })
        await harness.manager.shutdown()
    }

    @Test("a blocked completed callback does not hold background completion")
    func blockedCompletedDoesNotHoldBackgroundCompletion() async throws {
        let fileManager = FileManager.default
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(
            "callback-completed-destination-\(UUID().uuidString).bin"
        )
        let temporaryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "callback-completed-source-\(UUID().uuidString).tmp"
        )
        try Data("callback-completed".utf8).write(to: temporaryURL)
        defer {
            try? fileManager.removeItem(at: temporaryURL)
            try? fileManager.removeItem(at: destinationURL)
        }

        let harness = try StubDownloadHarness(
            backgroundTransfers: true,
            label: "callback-completed-background"
        )
        let completedGate = CallbackBlocker()
        let backgroundCompleted = CallbackSignal()
        await harness.manager.setOnCompletedHandler { _, _ in
            await completedGate.block()
        }
        harness.handleBackgroundSessionCompletion {
            Task { await backgroundCompleted.mark() }
        }

        let task = await harness.startDownload(destinationURL: destinationURL)
        let taskIdentifier = try #require(
            await waitForRuntimeTaskIdentifier(manager: harness.manager, task: task)
        )
        harness.injectDelegateCompletion(
            taskIdentifier: taskIdentifier,
            location: temporaryURL
        )
        #expect(await waitForCallbackCondition { await completedGate.isStarted })

        harness.injectBackgroundEventsFinished()

        #expect(await waitForCallbackCondition { await backgroundCompleted.isMarked })
        #expect(await task.state == .completed)
        #expect(await completedGate.isFinished == false)

        await completedGate.release()
        await harness.manager.shutdown()
        #expect(await completedGate.isFinished)
    }
}

private actor CallbackBlocker {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isStarted = false
    private(set) var isFinished = false
    private var isReleased = false

    func block() async {
        isStarted = true
        if !isReleased {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        isFinished = true
    }

    func release() {
        isReleased = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private actor CallbackSignal {
    private(set) var isMarked = false

    func mark() {
        isMarked = true
    }
}

private actor CallbackRendezvous {
    private let expectedCount: Int
    private var arrivalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func arriveAndWait() async {
        arrivalCount += 1
        if arrivalCount == expectedCount {
            let waiters = waiters
            self.waiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor CallbackOrderRecorder {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

private func waitForCallbackCondition(
    timeout: TimeInterval = 2.0,
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
