import Foundation
import os
import Testing
@testable import InnoNetwork
@testable import InnoNetworkWebSocket


/// Focused tests for `WebSocketReceiveLoop`'s error and cancellation paths.
/// Happy-path delivery is covered by `WebSocketMessagingHappyPathTests`; this
/// suite pins down the less-exercised branches: `onError` dispatch on
/// non-cancellation errors, silent exit on cancellation, and clean loop
/// shutdown when the runtime message-listener task is cancelled mid-flight.
@Suite("WebSocket Receive Loop Tests")
struct WebSocketReceiveLoopTests {

    @Test("Receive loop invokes onError when the URL task throws a non-cancellation error")
    func receiveLoopInvokesOnErrorForNonCancellationErrors() async throws {
        let registry = WebSocketRuntimeRegistry()
        let eventHub = TaskEventHub<WebSocketEvent>(
            policy: .default,
            metricsReporter: nil,
            hubKind: .webSocketTask
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/receive")!)
        await registry.add(task)
        let stub = StubWebSocketURLTask()
        await registry.setURLTask(stub, for: task.id)

        let receivedError = OSAllocatedUnfairLock<(Int, URLError.Code)?>(initialState: nil)
        let loop = WebSocketReceiveLoop(runtimeRegistry: registry, eventHub: eventHub)
        await loop.start(task: task, urlTask: stub) { identifier, error in
            if let urlError = error as? URLError {
                receivedError.withLock { $0 = (identifier, urlError.code) }
            }
        }

        // Scripted error causes receive() to throw; loop should invoke onError
        // exactly once.
        stub.scriptReceive(.failure(URLError(.networkConnectionLost)))

        let fired = await waitFor(timeout: 1.0) {
            receivedError.withLock { $0 } != nil
        }
        #expect(fired)
        let captured = receivedError.withLock { $0 }
        #expect(captured?.0 == stub.taskIdentifier)
        #expect(captured?.1 == URLError.Code.networkConnectionLost)

        await registry.cancelMessageListenerTask(for: task.id)
    }

    @Test("Cancelling the runtime message listener stops the loop without invoking onError")
    func receiveLoopCancellationSkipsOnError() async throws {
        let registry = WebSocketRuntimeRegistry()
        let eventHub = TaskEventHub<WebSocketEvent>(
            policy: .default,
            metricsReporter: nil,
            hubKind: .webSocketTask
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/cancel")!)
        await registry.add(task)
        let stub = StubWebSocketURLTask()
        await registry.setURLTask(stub, for: task.id)

        let errorFired = OSAllocatedUnfairLock<Bool>(initialState: false)
        let loop = WebSocketReceiveLoop(runtimeRegistry: registry, eventHub: eventHub)
        await loop.start(task: task, urlTask: stub) { _, _ in
            errorFired.withLock { $0 = true }
        }

        // Wait until the loop is suspended inside urlTask.receive() with no
        // scripted results, then cancel.
        let suspended = await waitFor(timeout: 1.0) {
            stub.pendingReceiveCount == 1
        }
        #expect(suspended)

        await registry.cancelMessageListenerTask(for: task.id)

        // Give the cancellation path a moment to propagate, then verify that
        // onError stayed silent.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(errorFired.withLock { $0 } == false)
        #expect(stub.pendingReceiveCount == 0)
    }

    @Test("Receive loop continues publishing after a successful delivery")
    func receiveLoopContinuesAfterOneMessage() async throws {
        let registry = WebSocketRuntimeRegistry()
        let eventHub = TaskEventHub<WebSocketEvent>(
            policy: .default,
            metricsReporter: nil,
            hubKind: .webSocketTask
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/keep-alive")!)
        await registry.add(task)
        let stub = StubWebSocketURLTask()
        await registry.setURLTask(stub, for: task.id)

        let recorder = WebSocketEventRecorder()
        _ = await eventHub.addListener(taskID: task.id) { event in
            recorder.record(event)
        }

        let errorFired = OSAllocatedUnfairLock<Bool>(initialState: false)
        let loop = WebSocketReceiveLoop(runtimeRegistry: registry, eventHub: eventHub)
        await loop.start(task: task, urlTask: stub) { _, _ in
            errorFired.withLock { $0 = true }
        }

        stub.scriptReceive(.success(.string("first")))
        let firstDelivered = await recorder.waitForEvent(timeout: 1.0) { event in
            if case .string(let s) = event, s == "first" { return true }
            return false
        }
        #expect(firstDelivered)

        stub.scriptReceive(.success(.data(Data([0x01, 0x02]))))
        let secondDelivered = await recorder.waitForEvent(timeout: 1.0) { event in
            if case .message(let d) = event, d == Data([0x01, 0x02]) { return true }
            return false
        }
        #expect(secondDelivered)
        #expect(errorFired.withLock { $0 } == false)

        await registry.cancelMessageListenerTask(for: task.id)
    }
}


/// Shared polling helper. Mirrors the one used in reconnect/heartbeat tests.
@Sendable
private func waitFor(
    timeout: TimeInterval,
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
