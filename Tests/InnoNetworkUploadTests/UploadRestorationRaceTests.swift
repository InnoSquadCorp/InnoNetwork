import Foundation
import Testing

@testable import InnoNetworkUpload

@Suite("Upload restoration races", .serialized, .timeLimit(.minutes(1)))
struct UploadRestorationRaceTests {
    @Test(
        "A stale enumeration cannot re-adopt a completed physical upload",
        arguments: [false, true]
    )
    func completedDuringEnumeration(completesWhileEnumerating: Bool) async throws {
        let gate = UploadSnapshotGate()
        var request = URLRequest(url: URL(string: "https://upload.example.test/file")!)
        request.httpMethod = "POST"
        let physical = StubUploadURLTask(
            taskIdentifier: 81,
            request: request,
            taskDescription: "once",
            state: .running
        )
        let channel = UploadDelegateEventChannel()
        let session = UploadSnapshotSession(channel: channel, task: physical, gate: gate)
        let manager = UploadManager(
            configuration: .background(sessionIdentifier: "test.snapshot.race"),
            session: session,
            channel: channel
        )

        let restoration = Task { await manager.restoreTasks() }
        await gate.waitUntilEntered()
        if completesWhileEnumerating {
            Self.complete(channel, request: request)
            await Self.drain(manager, channel)
            #expect(await manager.task(withId: "once")?.state == .completed)
        }
        await gate.open()
        _ = await restoration.value
        if !completesWhileEnumerating {
            Self.complete(channel, request: request)
            await Self.drain(manager, channel)
        }

        let tasks = await manager.allTasks()
        #expect(tasks.count == 1)
        #expect(tasks.first?.id == "once")
        #expect(await tasks.first?.state == .completed)
        await manager.shutdown()
    }

    private static func complete(_ channel: UploadDelegateEventChannel, request: URLRequest) {
        channel.send(
            .completed(
                taskIdentifier: 81,
                taskDescription: "once",
                originalRequest: request,
                currentRequest: request,
                response: HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                ),
                error: nil
            )
        )
    }

    private static func drain(_ manager: UploadManager, _ channel: UploadDelegateEventChannel) async {
        await withCheckedContinuation { continuation in
            manager.handleBackgroundEvents { continuation.resume() }
            channel.send(.backgroundEventsFinished)
        }
    }
}

private actor UploadSnapshotGate {
    private var entered = false
    private var opened = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        if !opened {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func waitUntilEntered() async {
        if !entered {
            await withCheckedContinuation { entryWaiters.append($0) }
        }
    }

    func open() {
        opened = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private final class UploadSnapshotSession: UploadURLSession, Sendable {
    let channel: UploadDelegateEventChannel
    let task: StubUploadURLTask
    let gate: UploadSnapshotGate

    init(channel: UploadDelegateEventChannel, task: StubUploadURLTask, gate: UploadSnapshotGate) {
        self.channel = channel
        self.task = task
        self.gate = gate
    }

    func makeUploadTask(with request: URLRequest, fromFile fileURL: URL) -> any UploadURLTask {
        StubUploadURLTask(taskIdentifier: 82, request: request)
    }

    func allUploadTasks() async -> [any UploadURLTask] {
        let snapshot: [any UploadURLTask] = [task]
        await gate.hold()
        return snapshot
    }

    func invalidateAndCancel() {
        task.cancel()
        channel.send(.invalidated)
    }
}
