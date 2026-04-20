import Foundation
import os
import Testing
import InnoNetworkTestSupport
@testable import InnoNetwork
@testable import InnoNetworkWebSocket


@Suite("WebSocket Heartbeat Timing Tests")
struct WebSocketHeartbeatTimingTests {

    @Test("Ping fires after one heartbeat interval")
    func pingFiresAfterInterval() async throws {
        let harness = HeartbeatTestHarness(
            heartbeatInterval: 10,
            pongTimeout: 1,
            maxMissedPongs: 1
        )
        await harness.startHeartbeat()

        // Wait for the loop's first clock.sleep(interval) to register.
        #expect(await harness.clock.waitForWaiters(count: 1))

        // Snapshot the sleep counter BEFORE advancing so we can detect the
        // pongTimeout waiter that sendPing enqueues next.
        let baseline = harness.clock.enqueuedCount
        harness.clock.advance(by: .seconds(10))

        // sendPing enqueues the pongTimeout waiter → counter increments.
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))
        #expect(await harness.waitForStubPingCount(atLeast: 1))
        harness.stubTask.completePendingPong(with: nil)

        await harness.stopHeartbeat()
    }

    @Test("Multiple pings fire across consecutive intervals")
    func multiplePingsFireAcrossIntervals() async throws {
        let harness = HeartbeatTestHarness(
            heartbeatInterval: 5,
            pongTimeout: 1,
            maxMissedPongs: 5
        )
        await harness.startHeartbeat()

        // The first interval waiter is enqueued as part of startHeartbeat.
        #expect(await harness.clock.waitForWaiters(count: 1))

        for cycle in 1...3 {
            // Before advancing, note the current sleep counter. Each cycle
            // adds exactly 2 new clock sleeps: the pongTimeout (after sendPing
            // starts) and the next interval sleep (after the loop iterates).
            let baseline = harness.clock.enqueuedCount
            harness.clock.advance(by: .seconds(5))

            #expect(await harness.waitForStubPingCount(atLeast: cycle))
            // Wait for the pongTimeout waiter to register so we don't race
            // the loop when we complete the pong.
            #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))

            harness.stubTask.completePendingPong(with: nil)

            // Wait for the loop to publish .pong AND enqueue the next interval.
            #expect(await harness.waitForPongCount(atLeast: cycle))
            #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 2))
        }

        #expect(harness.stubTask.pingCount >= 3)
        await harness.stopHeartbeat()
    }

    @Test("Successful pongs keep the loop publishing .pong events")
    func successfulPongPublishesPongEvent() async throws {
        let harness = HeartbeatTestHarness(
            heartbeatInterval: 8,
            pongTimeout: 1,
            maxMissedPongs: 3
        )
        await harness.startHeartbeat()

        #expect(await harness.clock.waitForWaiters(count: 1))
        let baseline = harness.clock.enqueuedCount
        harness.clock.advance(by: .seconds(8))
        #expect(await harness.waitForStubPingCount(atLeast: 1))
        #expect(await harness.waitForPingEventCount(atLeast: 1))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))

        harness.stubTask.completePendingPong(with: nil)
        #expect(await harness.waitForPongCount(atLeast: 1))

        await harness.stopHeartbeat()
    }

    @Test("Ping context carries a monotonically increasing attempt number")
    func pingContextCarriesMonotonicAttemptNumber() async throws {
        let harness = HeartbeatTestHarness(
            heartbeatInterval: 5,
            pongTimeout: 1,
            maxMissedPongs: 5
        )
        await harness.startHeartbeat()
        #expect(await harness.clock.waitForWaiters(count: 1))

        for cycle in 1...3 {
            let baseline = harness.clock.enqueuedCount
            harness.clock.advance(by: .seconds(5))
            #expect(await harness.waitForStubPingCount(atLeast: cycle))
            #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))
            harness.stubTask.completePendingPong(with: nil)
            #expect(await harness.waitForPongCount(atLeast: cycle))
            #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 2))
        }

        let snapshot = harness.defaultRecorder.snapshot()
        let attemptNumbers = snapshot.compactMap { event -> Int? in
            if case .ping(let context) = event { return context.attemptNumber }
            return nil
        }
        #expect(attemptNumbers == [1, 2, 3])

        await harness.stopHeartbeat()
    }

    @Test("Ping context dispatchedAt precedes subsequent .pong observation")
    func pingContextDispatchedAtPrecedesPongObservation() async throws {
        let harness = HeartbeatTestHarness(
            heartbeatInterval: 4,
            pongTimeout: 1,
            maxMissedPongs: 3
        )
        await harness.startHeartbeat()
        #expect(await harness.clock.waitForWaiters(count: 1))

        let baseline = harness.clock.enqueuedCount
        harness.clock.advance(by: .seconds(4))
        #expect(await harness.waitForPingEventCount(atLeast: 1))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))

        let capturedAt = ContinuousClock.now
        harness.stubTask.completePendingPong(with: nil)
        #expect(await harness.waitForPongCount(atLeast: 1))

        let snapshot = harness.defaultRecorder.snapshot()
        let pingContext = snapshot.compactMap { event -> WebSocketPingContext? in
            if case .ping(let context) = event { return context }
            return nil
        }.first
        #expect(pingContext != nil)

        if let pingContext {
            // The ping must have been dispatched before we captured the
            // pong-side timestamp (because the advance that fires ping
            // happened before `capturedAt` was read).
            #expect(pingContext.dispatchedAt <= capturedAt)
        }

        await harness.stopHeartbeat()
    }

    @Test("Automatic reconnect resets the next heartbeat ping attempt number to 1")
    func automaticReconnectResetsPingAttemptNumber() async throws {
        let harness = StubMessagingHarness(
            heartbeatInterval: 0.1,
            pongTimeout: 2,
            reconnectDelay: 0,
            maxReconnectAttempts: 1
        )
        let task = try await harness.connectAndReady()
        let recorder = WebSocketEventCollector()
        let subscription = await harness.manager.addEventListener(for: task) { event in
            recorder.record(event)
        }

        #expect(await waitFor(timeout: 2.0) { harness.stubTask.pingCount >= 1 })
        harness.stubTask.completePendingPong(with: nil)
        #expect(await waitFor(timeout: 2.0) {
            recorder.snapshot().contains { event in
                if case .pong = event { return true }
                return false
            }
        })

        let reconnectStub = StubWebSocketURLTask()
        harness.stubSession.enqueue(reconnectStub)
        harness.manager.handleDisconnected(
            taskIdentifier: harness.stubTaskIdentifier,
            closeCode: .serviceRestart,
            reason: "restart"
        )

        #expect(await harness.waitForCreatedTaskCount(atLeast: 2, timeout: 2.0))

        let preReconnectPingCount = recorder.snapshot().compactMap { event -> Int? in
            if case .ping = event { return 1 }
            return nil
        }.count
        #expect(preReconnectPingCount >= 1)

        harness.manager.handleConnected(taskIdentifier: reconnectStub.taskIdentifier, protocolName: nil)
        #expect(await harness.waitForTaskState(task, equals: .connected, timeout: 2.0))
        #expect(await waitFor(timeout: 2.0) { reconnectStub.pingCount >= 1 })
        reconnectStub.completePendingPong(with: nil)
        #expect(await waitFor(timeout: 2.0) {
            recorder.snapshot().compactMap { event -> Int? in
                if case .ping(let context) = event { return context.attemptNumber }
                return nil
            }.count > preReconnectPingCount
        })

        let attemptNumbers = recorder.snapshot().compactMap { event -> Int? in
            if case .ping(let context) = event { return context.attemptNumber }
            return nil
        }
        #expect(attemptNumbers.count > preReconnectPingCount)
        if attemptNumbers.count > preReconnectPingCount {
            #expect(attemptNumbers[preReconnectPingCount] == 1)
        }

        await harness.manager.removeEventListener(subscription)
        await harness.manager.disconnect(task)
        harness.manager.handleDisconnected(
            taskIdentifier: reconnectStub.taskIdentifier,
            closeCode: .normalClosure,
            reason: nil
        )
    }

    @Test(".ping event is published before the paired .pong event")
    func pingPublishedBeforePong() async throws {
        let harness = HeartbeatTestHarness(
            heartbeatInterval: 6,
            pongTimeout: 1,
            maxMissedPongs: 3
        )
        await harness.startHeartbeat()

        #expect(await harness.clock.waitForWaiters(count: 1))
        let baseline = harness.clock.enqueuedCount
        harness.clock.advance(by: .seconds(6))

        #expect(await harness.waitForStubPingCount(atLeast: 1))
        #expect(await harness.waitForPingEventCount(atLeast: 1))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))

        harness.stubTask.completePendingPong(with: nil)
        #expect(await harness.waitForPongCount(atLeast: 1))

        // The single-cycle snapshot must contain exactly one .ping followed by
        // one .pong, in that order. This locks in the "attempt → success"
        // observability contract documented on `WebSocketEvent.ping`.
        let snapshot = harness.defaultRecorder.snapshot()
        let relevantIndices = snapshot.enumerated().compactMap { offset, event -> Int? in
            switch event {
            case .ping, .pong: return offset
            default: return nil
            }
        }
        #expect(relevantIndices.count == 2)
        if relevantIndices.count == 2 {
            if case .ping = snapshot[relevantIndices[0]] {} else {
                Issue.record("expected first of the ping/pong pair to be .ping")
            }
            if case .pong = snapshot[relevantIndices[1]] {} else {
                Issue.record("expected second of the ping/pong pair to be .pong")
            }
        }

        await harness.stopHeartbeat()
    }

    @Test("Consecutive missed pongs trigger the onPingTimeout callback")
    func consecutiveMissedPongsInvokesOnPingTimeout() async throws {
        let harness = HeartbeatTestHarness(
            heartbeatInterval: 4,
            pongTimeout: 2,
            maxMissedPongs: 2
        )

        let timeoutBox = OSAllocatedUnfairLock<Int?>(initialState: nil)
        await harness.startHeartbeat(onPingTimeout: { taskIdentifier in
            timeoutBox.withLock { $0 = taskIdentifier }
        })

        #expect(await harness.clock.waitForWaiters(count: 1))

        // Cycle 1: advance interval → ping → advance pongTimeout → miss
        var baseline = harness.clock.enqueuedCount
        harness.clock.advance(by: .seconds(4))
        #expect(await harness.waitForStubPingCount(atLeast: 1))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))

        harness.clock.advance(by: .seconds(2))
        // Loop catches pingTimeout and starts the next interval sleep.
        #expect(await harness.waitForPingTimeoutErrorCount(atLeast: 1))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 2))
        #expect(timeoutBox.withLock { $0 } == nil)

        // Cycle 2: same, and missedPongs should reach maxMissedPongs → callback.
        baseline = harness.clock.enqueuedCount
        harness.clock.advance(by: .seconds(4))
        #expect(await harness.waitForStubPingCount(atLeast: 2))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))

        harness.clock.advance(by: .seconds(2))

        let invoked = await waitFor(timeout: 1.0) {
            timeoutBox.withLock { $0 } != nil
        }
        #expect(invoked)
        #expect(timeoutBox.withLock { $0 } == harness.stubTask.taskIdentifier)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(harness.defaultRecorder.pingTimeoutErrorCount == 1)
    }

    @Test("Successful pong resets the missed pong counter")
    func successfulPongResetsMissedCount() async throws {
        let harness = HeartbeatTestHarness(
            heartbeatInterval: 4,
            pongTimeout: 2,
            maxMissedPongs: 2
        )

        let timeoutBox = OSAllocatedUnfairLock<Int?>(initialState: nil)
        await harness.startHeartbeat(onPingTimeout: { identifier in
            timeoutBox.withLock { $0 = identifier }
        })

        #expect(await harness.clock.waitForWaiters(count: 1))

        // Cycle 1 (miss): advance interval → ping → advance pongTimeout → miss
        var baseline = harness.clock.enqueuedCount
        harness.clock.advance(by: .seconds(4))
        #expect(await harness.waitForStubPingCount(atLeast: 1))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))
        harness.clock.advance(by: .seconds(2))
        #expect(await harness.waitForPingTimeoutErrorCount(atLeast: 1))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 2))

        // Cycle 2 (successful): pong resets missedPongs to 0.
        baseline = harness.clock.enqueuedCount
        harness.clock.advance(by: .seconds(4))
        #expect(await harness.waitForStubPingCount(atLeast: 2))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))
        harness.stubTask.completePendingPong(with: nil)
        #expect(await harness.waitForPongCount(atLeast: 1))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 2))

        // Cycle 3 (miss again): should NOT trip the callback since we reset.
        baseline = harness.clock.enqueuedCount
        harness.clock.advance(by: .seconds(4))
        #expect(await harness.waitForStubPingCount(atLeast: 3))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))
        harness.clock.advance(by: .seconds(2))
        #expect(await harness.waitForPingTimeoutErrorCount(atLeast: 2))
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 2))

        // Give the loop a brief moment to react; the timeout callback should
        // have stayed silent throughout.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(timeoutBox.withLock { $0 } == nil)

        await harness.stopHeartbeat()
    }

    @Test("Cancelling the heartbeat task exits the loop promptly")
    func heartbeatCancelStopsLoop() async throws {
        let harness = HeartbeatTestHarness(
            heartbeatInterval: 30,
            pongTimeout: 1,
            maxMissedPongs: 1
        )
        await harness.startHeartbeat()
        #expect(await harness.clock.waitForWaiters(count: 1))

        await harness.stopHeartbeat()

        // After cancellation the loop's sleep must have been unblocked. The
        // TestClock's onCancel path runs asynchronously relative to the task
        // cancellation, so poll briefly before asserting.
        let drained = await waitFor(timeout: 1.0) {
            harness.clock.waiterCount == 0
        }
        #expect(drained)
        #expect(harness.stubTask.pingCount == 0)
    }

    @Test("Timed out heartbeat does not dispatch a stale ping after pre-dispatch cancellation")
    func timedOutHeartbeatDoesNotDispatchStalePing() async throws {
        let dispatchGate = AsyncDispatchGate()
        let harness = HeartbeatTestHarness(
            heartbeatInterval: 4,
            pongTimeout: 1,
            maxMissedPongs: 1,
            beforeSendPingDispatch: {
                await dispatchGate.arriveAndWait()
            }
        )

        let timeoutBox = OSAllocatedUnfairLock<Int?>(initialState: nil)
        await harness.startHeartbeat(onPingTimeout: { taskIdentifier in
            timeoutBox.withLock { $0 = taskIdentifier }
        })

        #expect(await harness.clock.waitForWaiters(count: 1))

        let baseline = harness.clock.enqueuedCount
        harness.clock.advance(by: .seconds(4))

        let reachedDispatchGate = await waitFor(timeout: 1.0) {
            dispatchGate.hasArrivedSync
        }
        #expect(reachedDispatchGate)
        #expect(await harness.clock.waitForEnqueuedCount(atLeast: baseline + 1))

        harness.clock.advance(by: .seconds(1))
        dispatchGate.release()

        let stalePingSuppressed = await waitFor(timeout: 1.0) {
            harness.stubTask.pingCount == 0 && !harness.stubTask.hasPendingPong
        }
        #expect(stalePingSuppressed)

        let timedOut = await waitFor(timeout: 1.0) {
            timeoutBox.withLock { $0 } != nil
        }
        #expect(timedOut)
        #expect(timeoutBox.withLock { $0 } == harness.stubTask.taskIdentifier)

        await harness.stopHeartbeat()
    }
}


/// Small helper: poll a condition up to `timeout` and return true as soon as
/// it is satisfied. Used to avoid hard-coded sleeps in assertions.
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


/// Blocks the coordinator right before it would dispatch a ping, allowing
/// tests to cancel the enclosing task while the continuation is already
/// registered but the socket has not yet seen the ping.
final class AsyncDispatchGate: @unchecked Sendable {
    private let arrivedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let continuationLock = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    func arriveAndWait() async {
        arrivedLock.withLock { $0 = true }
        await withCheckedContinuation { continuation in
            continuationLock.withLock { $0 = continuation }
        }
    }

    func release() {
        let continuation = continuationLock.withLock { state -> CheckedContinuation<Void, Never>? in
            let current = state
            state = nil
            return current
        }
        continuation?.resume()
    }

    var hasArrivedSync: Bool {
        arrivedLock.withLock { $0 }
    }
}


/// Wires a `WebSocketHeartbeatCoordinator` against a stub URL task and a
/// `TestClock`, exposing helpers to drive the heartbeat deterministically.
final class HeartbeatTestHarness: Sendable {
    let task: WebSocketTask
    let stubTask: StubWebSocketURLTask
    let clock: TestClock
    let configuration: WebSocketConfiguration
    let runtimeRegistry: WebSocketRuntimeRegistry
    let eventHub: TaskEventHub<WebSocketEvent>
    /// Default recorder attached during `startHeartbeat`. Every heartbeat
    /// event (including `.pong`) flows through it; tests use `pongCount` to
    /// sequence multi-cycle scenarios.
    let defaultRecorder: WebSocketEventRecorder
    private let coordinator: WebSocketHeartbeatCoordinator

    init(
        heartbeatInterval: TimeInterval,
        pongTimeout: TimeInterval,
        maxMissedPongs: Int,
        beforeSendPingDispatch: (@Sendable () async -> Void)? = nil
    ) {
        let url = URL(string: "ws://stub.invalid/hb")!
        self.task = WebSocketTask(url: url)
        self.stubTask = StubWebSocketURLTask()
        self.clock = TestClock()
        self.configuration = WebSocketConfiguration(
            heartbeatInterval: heartbeatInterval,
            pongTimeout: pongTimeout,
            maxMissedPongs: maxMissedPongs,
            reconnectDelay: 0,
            maxReconnectAttempts: 0
        )
        self.runtimeRegistry = WebSocketRuntimeRegistry()
        self.eventHub = TaskEventHub(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .webSocketTask
        )
        self.defaultRecorder = WebSocketEventRecorder()
        self.coordinator = WebSocketHeartbeatCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry,
            eventHub: eventHub,
            clock: clock,
            beforeSendPingDispatch: beforeSendPingDispatch
        )
    }

    func startHeartbeat(
        onPingTimeout: @escaping @Sendable (Int) -> Void = { _ in }
    ) async {
        await runtimeRegistry.add(task)
        await runtimeRegistry.setURLTask(stubTask, for: task.id)
        await task.updateState(.connected)
        // Attach the always-on recorder before the heartbeat task starts so
        // `.pong` events are never missed.
        let recorder = defaultRecorder
        _ = await eventHub.addListener(taskID: task.id) { event in
            recorder.record(event)
        }
        await coordinator.startHeartbeat(for: task) { identifier in
            onPingTimeout(identifier)
        }
    }

    func stopHeartbeat() async {
        await runtimeRegistry.cancelHeartbeatTask(for: task.id)
    }

    func waitForStubPingCount(atLeast count: Int, timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stubTask.pingCount >= count { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return stubTask.pingCount >= count
    }

    /// Waits until the heartbeat loop has published at least `count` `.pong`
    /// events on `defaultRecorder`.
    func waitForPongCount(atLeast count: Int, timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if defaultRecorder.pongCount >= count { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return defaultRecorder.pongCount >= count
    }

    /// Waits until the heartbeat loop has published at least `count` `.ping`
    /// events on `defaultRecorder`.
    func waitForPingEventCount(atLeast count: Int, timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if defaultRecorder.pingCount >= count { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return defaultRecorder.pingCount >= count
    }

    /// Waits until the heartbeat loop has published at least `count`
    /// `.error(.pingTimeout)` events on `defaultRecorder`.
    func waitForPingTimeoutErrorCount(atLeast count: Int, timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if defaultRecorder.pingTimeoutErrorCount >= count { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return defaultRecorder.pingTimeoutErrorCount >= count
    }

    /// Attaches an additional event listener. The default recorder remains
    /// active; this is useful when a test wants an isolated recorder with
    /// its own history.
    func attachListener() async -> WebSocketEventRecorder {
        let recorder = WebSocketEventRecorder()
        _ = await eventHub.addListener(taskID: task.id) { event in
            recorder.record(event)
        }
        return recorder
    }
}


// `WebSocketEventRecorder` (now `WebSocketEventRecorder`) moved to
// `WebSocketTestSupport.swift` so Reconnect/ReceiveLoop/Messaging suites can
// reuse the same snapshot + counter helpers. A `typealias
// WebSocketEventRecorder = WebSocketEventRecorder` is kept there for
// back-compat.
