import Foundation
import InnoNetworkTestSupport
import Testing
import os

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

        // `loop.start(...)` registers the listener as an unstructured `Task`.
        // Under heavy parallel load (full-suite runs on macOS Actions runners,
        // TSAN, etc.), the scheduler can defer its first hop past a tight
        // 1-second polling window — at that point neither `receive()` nor the
        // ensuing `onError` dispatch has happened, and the test fails
        // deterministically. Wait until the listener has actually suspended
        // inside `urlTask.receive()` before scripting the error so the rest
        // of the assertions run with a known starting state.
        let suspended = await stub.waitForPendingReceiveCount(1)
        #expect(suspended)

        // Scripted error causes the suspended receive() to resume with a
        // throw; loop should invoke onError exactly once.
        stub.scriptReceive(.failure(URLError(.networkConnectionLost)))

        let fired = await waitFor(timeout: 2.0) {
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
        let suspended = await stub.waitForPendingReceiveCount(1)
        #expect(suspended)

        await registry.cancelMessageListenerTask(for: task.id)

        // The stub signals when cancellation has removed the suspended
        // receive continuation, so the assertions cannot race cleanup.
        #expect(await stub.waitForPendingReceiveCount(0))
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
        let firstDelivered = try await recorder.waitForEvent(timeout: 5.0) { event in
            if case .string(let s) = event, s == "first" { return true }
            return false
        }
        #expect(firstDelivered)

        stub.scriptReceive(.success(.data(Data([0x01, 0x02]))))
        let secondDelivered = try await recorder.waitForEvent(timeout: 5.0) { event in
            if case .message(let d) = event, d == Data([0x01, 0x02]) { return true }
            return false
        }
        #expect(secondDelivered)
        #expect(errorFired.withLock { $0 } == false)

        await registry.cancelMessageListenerTask(for: task.id)
    }

    @Test("Receive loop burst-delivers pre-queued messages in scripted order")
    func receiveLoopBurstDeliversMessagesInOrder() async throws {
        let registry = WebSocketRuntimeRegistry()
        let eventHub = TaskEventHub<WebSocketEvent>(
            policy: .default,
            metricsReporter: nil,
            hubKind: .webSocketTask
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/burst")!)
        await registry.add(task)
        let stub = StubWebSocketURLTask()
        await registry.setURLTask(stub, for: task.id)

        let recorder = WebSocketEventRecorder()
        _ = await eventHub.addListener(taskID: task.id) { event in
            recorder.record(event)
        }

        // Script 5 messages before starting the loop. The loop should drain
        // all of them through successive `receive()` calls, and each should
        // publish in the same order they were queued.
        let payloads: [URLSessionWebSocketTask.Message] = [
            .string("one"),
            .data(Data([0x01])),
            .string("three"),
            .data(Data([0x04, 0x05])),
            .string("five"),
        ]
        for payload in payloads {
            stub.scriptReceive(.success(payload))
        }

        let loop = WebSocketReceiveLoop(runtimeRegistry: registry, eventHub: eventHub)
        await loop.start(task: task, urlTask: stub) { _, _ in }

        // Wait until all 5 observable events (mix of .string/.message) have
        // landed in the recorder.
        let delivered = try await recorder.waitForCount(
            atLeast: payloads.count,
            matching: { event in
                switch event {
                case .string, .message: true
                default: false
                }
            }
        )
        #expect(delivered)

        // Verify the sequence order-for-order.
        let observed = recorder.snapshot().compactMap { event -> URLSessionWebSocketTask.Message? in
            switch event {
            case .string(let text): return .string(text)
            case .message(let data): return .data(data)
            default: return nil
            }
        }
        #expect(observed.count == payloads.count)
        for (expected, actual) in zip(payloads, observed) {
            switch (expected, actual) {
            case (.string(let l), .string(let r)):
                #expect(l == r)
            case (.data(let l), .data(let r)):
                #expect(l == r)
            default:
                Issue.record("type mismatch at position — expected \(expected), got \(actual)")
            }
        }

        await registry.cancelMessageListenerTask(for: task.id)
    }

    @Test("Swapping the registry's URL task mid-receive does not redirect an in-flight loop")
    func receiveLoopContinuesOnRegistryURLTaskSwap() async throws {
        // Contract: `WebSocketReceiveLoop.start(task:urlTask:onError:)`
        // captures `urlTask` at call time. Swapping
        // `runtimeRegistry.setURLTask(newStub, for: taskID)` does not
        // redirect an already-running loop — the original loop continues
        // to drain the original stub. This locks in the "one loop per
        // urlTask" lifecycle.
        let registry = WebSocketRuntimeRegistry()
        let eventHub = TaskEventHub<WebSocketEvent>(
            policy: .default,
            metricsReporter: nil,
            hubKind: .webSocketTask
        )
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/swap")!)
        await registry.add(task)
        let originalStub = StubWebSocketURLTask()
        await registry.setURLTask(originalStub, for: task.id)

        let recorder = WebSocketEventRecorder()
        _ = await eventHub.addListener(taskID: task.id) { event in
            recorder.record(event)
        }

        let loop = WebSocketReceiveLoop(runtimeRegistry: registry, eventHub: eventHub)
        await loop.start(task: task, urlTask: originalStub) { _, _ in }

        // Wait for the loop to block inside `originalStub.receive()`.
        #expect(await originalStub.waitForPendingReceiveCount(1))

        // Swap the registry's URL task entry. The running loop should NOT
        // start polling `replacementStub` — it still holds a reference to
        // `originalStub`.
        let replacementStub = StubWebSocketURLTask()
        await registry.setURLTask(replacementStub, for: task.id)

        // Delivery through `originalStub` still publishes.
        originalStub.scriptReceive(.success(.string("from-original")))
        let originalDelivered = try await recorder.waitForEvent(timeout: 5.0) { event in
            if case .string(let s) = event, s == "from-original" { return true }
            return false
        }
        #expect(originalDelivered)

        // Wait for the original loop to suspend in its next receive. This
        // proves it iterated again after delivery before we make the negative
        // assertion about the replacement.
        #expect(await originalStub.waitForPendingReceiveCount(1))
        #expect(replacementStub.pendingReceiveCount == 0)

        await registry.cancelMessageListenerTask(for: task.id)
    }

    // NOTE: `@unknown default` inside the receive loop's message switch is
    // not directly testable — `URLSessionWebSocketTask.Message` is a
    // Foundation enum and Swift does not allow external code to construct
    // values outside the declared cases. The branch exists for forward
    // compatibility should Foundation add a new case; the tests above
    // cover the two current cases (`.string`, `.data`) comprehensively.
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
