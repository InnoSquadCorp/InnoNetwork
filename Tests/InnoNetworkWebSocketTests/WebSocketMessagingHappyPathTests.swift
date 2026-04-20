import Foundation
import os
import Testing
@testable import InnoNetworkWebSocket


@Suite("WebSocket Messaging Happy Path Tests")
struct WebSocketMessagingHappyPathTests {

    @Test("send(data:) forwards a binary payload to the URL task")
    func sendBinaryForwardsToURLTask() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()
        let payload = Data([0x01, 0x02, 0x03])

        try await harness.manager.send(task, message: payload)

        let recorded = harness.stubTask.sentMessages
        #expect(recorded.count == 1)
        if case .data(let data) = recorded.first {
            #expect(data == payload)
        } else {
            Issue.record("Expected .data message, got \(String(describing: recorded.first))")
        }
        await harness.tearDown(task: task)
    }

    @Test("send(string:) forwards a text payload to the URL task")
    func sendStringForwardsToURLTask() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()

        try await harness.manager.send(task, string: "hello-ws")

        let recorded = harness.stubTask.sentMessages
        #expect(recorded.count == 1)
        if case .string(let text) = recorded.first {
            #expect(text == "hello-ws")
        } else {
            Issue.record("Expected .string message, got \(String(describing: recorded.first))")
        }
        await harness.tearDown(task: task)
    }

    @Test("Receive loop publishes binary payloads as .message events")
    func receiveLoopPublishesBinaryAsMessageEvent() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()

        let expected = Data([0xAA, 0xBB, 0xCC, 0xDD])
        harness.stubTask.scriptReceive(.success(.data(expected)))

        let delivered = await harness.waitForEvent(taskID: task.id, timeout: 1.0) { event in
            if case .message(let data) = event, data == expected { return true }
            return false
        }
        #expect(delivered)
        await harness.tearDown(task: task)
    }

    @Test("Receive loop publishes string payloads as .string events")
    func receiveLoopPublishesStringAsStringEvent() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()

        harness.stubTask.scriptReceive(.success(.string("greetings")))

        let delivered = await harness.waitForEvent(taskID: task.id, timeout: 1.0) { event in
            if case .string(let text) = event, text == "greetings" { return true }
            return false
        }
        #expect(delivered)
        await harness.tearDown(task: task)
    }

    @Test("Consecutive sends preserve ordering")
    func sendPreservesMessageOrder() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()

        for index in 0..<10 {
            try await harness.manager.send(task, string: "msg-\(index)")
        }

        let recorded = harness.stubTask.sentMessages
        #expect(recorded.count == 10)
        for (index, message) in recorded.enumerated() {
            if case .string(let text) = message {
                #expect(text == "msg-\(index)")
            } else {
                Issue.record("Unexpected message at index \(index): \(message)")
            }
        }
        await harness.tearDown(task: task)
    }

    @Test("Multiple scripted receives are delivered in order")
    func receiveLoopDeliversMultiplePayloadsInOrder() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()

        let recorder = WebSocketEventCollector()
        let subscription = await harness.manager.addEventListener(for: task) { event in
            recorder.record(event)
        }

        harness.stubTask.scriptReceive(.success(.string("one")))
        harness.stubTask.scriptReceive(.success(.string("two")))
        harness.stubTask.scriptReceive(.success(.string("three")))

        let collected = await recorder.waitForCount(3, timeout: 1.0)
        #expect(collected)

        let strings = recorder.snapshot().compactMap { event -> String? in
            if case .string(let text) = event { return text }
            return nil
        }
        #expect(strings == ["one", "two", "three"])

        await harness.manager.removeEventListener(subscription)
        await harness.tearDown(task: task)
    }

    @Test("Immediate scripted receive still throws CancellationError when cancelled before returning")
    func immediateScriptedReceiveHonorsCancellation() async throws {
        let stubTask = StubWebSocketURLTask()
        let gate = AsyncGate()
        stubTask.setBeforeReceiveCancellationCheckHook {
            await gate.arriveAndWait()
        }
        stubTask.scriptReceive(.success(.string("ready")))

        let receiveTask = Task {
            try await stubTask.receive()
        }

        #expect(await waitForGateArrival(gate, timeout: 1.0))
        receiveTask.cancel()
        await gate.release()

        do {
            _ = try await receiveTask.value
            Issue.record("Expected CancellationError from immediate scripted receive")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test("Continuation-backed receive still throws CancellationError when cancelled after resuming")
    func resumedReceiveHonorsCancellation() async throws {
        let stubTask = StubWebSocketURLTask()
        let gate = AsyncGate()
        stubTask.setBeforeReceiveCancellationCheckHook {
            await gate.arriveAndWait()
        }

        let receiveTask = Task {
            try await stubTask.receive()
        }

        #expect(await waitForPendingReceive(stubTask, timeout: 1.0))
        stubTask.scriptReceive(.success(.string("resumed")))
        #expect(await waitForGateArrival(gate, timeout: 1.0))

        receiveTask.cancel()
        await gate.release()

        do {
            _ = try await receiveTask.value
            Issue.record("Expected CancellationError from resumed receive")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }
}

private actor AsyncGate {
    private var arrived = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        arrived = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func hasArrived() -> Bool {
        arrived
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func waitForGateArrival(_ gate: AsyncGate, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await gate.hasArrived() {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await gate.hasArrived()
}

private func waitForPendingReceive(_ stubTask: StubWebSocketURLTask, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if stubTask.pendingReceiveCount > 0 {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return stubTask.pendingReceiveCount > 0
}


/// Shared harness that wires a `WebSocketManager` to a stub `URLSession` and
/// exposes helpers for bringing a task to the `.connected` state deterministically.
final class StubMessagingHarness: Sendable {
    let manager: WebSocketManager
    let stubSession: StubWebSocketURLSession
    let stubTask: StubWebSocketURLTask
    let stubTaskIdentifier: Int
    private let callbacks: WebSocketSessionDelegateCallbacks
    private let sessionIdentifier: String

    init() {
        let identifier = "test.websocket.stub.\(UUID().uuidString)"
        let stubSession = StubWebSocketURLSession()
        let stubTask = StubWebSocketURLTask()
        stubSession.enqueue(stubTask)

        let callbacks = WebSocketSessionDelegateCallbacks()
        let delegate = WebSocketSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: BackgroundCompletionStore()
        )

        self.sessionIdentifier = identifier
        self.stubSession = stubSession
        self.stubTask = stubTask
        self.stubTaskIdentifier = stubTask.taskIdentifier
        self.callbacks = callbacks
        self.manager = WebSocketManager(
            configuration: WebSocketConfiguration(
                heartbeatInterval: 0,
                reconnectDelay: 0,
                maxReconnectAttempts: 0,
                sessionIdentifier: identifier
            ),
            urlSession: stubSession,
            delegate: delegate,
            callbacks: callbacks
        )
    }

    /// Opens a connection against the stub, drives it to `.connected`, and
    /// returns the corresponding `WebSocketTask`.
    func connectAndReady(url: URL = URL(string: "ws://stub.invalid/socket")!) async throws -> WebSocketTask {
        let task = await manager.connect(url: url)
        // startConnection returns after registering the stub task; taskIdentifier
        // is immediately available because the stub runs synchronously.
        manager.handleConnected(taskIdentifier: stubTaskIdentifier, protocolName: nil)

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if await task.state == .connected { return task }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Stub task never transitioned to .connected within the timeout")
        return task
    }

    func waitForEvent(
        taskID: String,
        timeout: TimeInterval,
        predicate: @escaping @Sendable (WebSocketEvent) -> Bool
    ) async -> Bool {
        let recorder = WebSocketEventCollector()
        let subscription = await manager.addEventListener(for: WebSocketTaskIdentity(id: taskID)) { event in
            recorder.record(event)
        }
        defer {
            Task { [manager] in
                await manager.removeEventListener(subscription)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recorder.snapshot().contains(where: predicate) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func tearDown(task: WebSocketTask) async {
        await manager.disconnect(task)
    }
}


private struct WebSocketTaskIdentity {
    let id: String
}


extension WebSocketManager {
    fileprivate func addEventListener(
        for identity: WebSocketTaskIdentity,
        listener: @escaping @Sendable (WebSocketEvent) async -> Void
    ) async -> WebSocketEventSubscription {
        guard let task = await self.task(withId: identity.id) else {
            fatalError("Task \(identity.id) not found in manager")
        }
        return await addEventListener(for: task, listener: listener)
    }
}


/// Thread-safe event collector used by the happy-path tests to observe the
/// order and content of events published to the event hub.
final class WebSocketEventCollector: Sendable {
    private let events = OSAllocatedUnfairLock<[WebSocketEvent]>(initialState: [])

    func record(_ event: WebSocketEvent) {
        events.withLock { $0.append(event) }
    }

    func snapshot() -> [WebSocketEvent] {
        events.withLock { $0 }
    }

    func waitForCount(_ count: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if events.withLock({ $0.count }) >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
