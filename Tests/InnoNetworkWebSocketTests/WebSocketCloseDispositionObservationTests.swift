import Foundation
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

/// Observation tests for the 4.0.0 public `WebSocketTask.closeDisposition`
/// getter. Confirms that the manager records the classified disposition on
/// every close path (manual disconnect, close-handshake timeout, peer close,
/// transport failure) so consumers branching on retry/terminal semantics can
/// rely on the value after the task reaches `.disconnected` / `.failed`.
///
/// Uses `StubMessagingHarness` so real URLSession activity doesn't race the
/// test's scripted close code and drive disposition into `.transportFailure`.
@Suite("WebSocket Close Disposition Observation Tests")
struct WebSocketCloseDispositionObservationTests {

    @Test("Manual disconnect records .manual disposition")
    func manualDisconnectRecordsDisposition() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()

        await harness.manager.disconnect(task, closeCode: .goingAway)
        // Simulate the delegate callback that lands once URLSession hands
        // control back after the peer acknowledges close.
        harness.manager.handleDisconnected(
            taskIdentifier: harness.stubTaskIdentifier,
            closeCode: .goingAway,
            reason: nil
        )

        let disposition = await waitForCloseDisposition(task: task, timeout: .seconds(2))
        guard case .manual(let code) = disposition else {
            Issue.record("expected .manual, got \(String(describing: disposition))")
            return
        }
        #expect(code == .goingAway)
        #expect(disposition?.shouldReconnect == false)
    }

    @Test("Manual disconnect timeout records .handshakeTimeout disposition")
    func manualDisconnectTimeoutRecordsDisposition() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()

        await harness.manager.disconnect(task, closeCode: .goingAway)

        let disposition = await waitForCloseDisposition(task: task, timeout: .seconds(5))
        guard case .handshakeTimeout(let code) = disposition else {
            Issue.record("expected .handshakeTimeout, got \(String(describing: disposition))")
            return
        }
        #expect(code == .goingAway)
        #expect(disposition?.shouldReconnect == false)
        #expect(await task.state == .disconnected)

        let taskError = await task.error
        guard case .disconnected(let underlyingError?)? = taskError else {
            Issue.record("expected timeout-flavored disconnected error, got \(String(describing: taskError))")
            return
        }
        #expect(underlyingError.domain == "InnoNetworkWebSocket.HandshakeTimeout")
        #expect(underlyingError.code == Int(WebSocketCloseCode.goingAway.rawValue))
        #expect(underlyingError.message == "WebSocket close handshake timed out.")
    }

    @Test("Zero close-handshake timeout finalizes through timeout path")
    func zeroCloseHandshakeTimeoutFinalizesThroughTimeoutPath() async throws {
        let harness = StubMessagingHarness(closeHandshakeTimeout: .zero)
        let task = try await harness.connectAndReady()

        await harness.manager.disconnect(task, closeCode: .normalClosure)

        let disposition = await waitForCloseDisposition(task: task, timeout: .seconds(1))
        guard case .handshakeTimeout(let code) = disposition else {
            Issue.record("expected .handshakeTimeout, got \(String(describing: disposition))")
            return
        }
        #expect(code == .normalClosure)
        #expect(await waitForManagerTaskRemoval(manager: harness.manager, task: task, timeout: .seconds(1)))
    }

    @Test("Peer close with retryable code records .peerRetryable disposition")
    func peerRetryableCloseRecordsDisposition() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()

        harness.manager.handleDisconnected(
            taskIdentifier: harness.stubTaskIdentifier,
            closeCode: .serviceRestart,
            reason: "restart"
        )

        let disposition = await waitForCloseDisposition(task: task, timeout: .seconds(2))
        guard case .peerRetryable(let code, let reason) = disposition else {
            Issue.record("expected .peerRetryable, got \(String(describing: disposition))")
            return
        }
        #expect(code == .serviceRestart)
        #expect(reason == "restart")
        #expect(disposition?.shouldReconnect == true)
    }

    @Test("Peer close with RFC terminal code records .peerProtocolFailure disposition")
    func peerProtocolFailureCloseRecordsDisposition() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()

        harness.manager.handleDisconnected(
            taskIdentifier: harness.stubTaskIdentifier,
            closeCode: .policyViolation,
            reason: "policy"
        )

        let disposition = await waitForCloseDisposition(task: task, timeout: .seconds(2))
        guard case .peerProtocolFailure(let code, _) = disposition else {
            Issue.record("expected .peerProtocolFailure, got \(String(describing: disposition))")
            return
        }
        #expect(code == .policyViolation)
        #expect(disposition?.shouldReconnect == false)
    }

    @Test("Custom close code records .peerApplicationFailure disposition with the custom value")
    func customCloseCodeRecordsApplicationFailureDisposition() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()

        harness.manager.handleDisconnected(
            taskIdentifier: harness.stubTaskIdentifier,
            closeCode: .custom(4001),
            reason: "app-specific"
        )

        let disposition = await waitForCloseDisposition(task: task, timeout: .seconds(2))
        guard case .peerApplicationFailure(let code, _) = disposition else {
            Issue.record("expected .peerApplicationFailure, got \(String(describing: disposition))")
            return
        }
        #expect(code == .custom(4001))
        #expect(disposition?.shouldReconnect == false)
    }

    @Test("closeDisposition is nil for a task that has not yet closed")
    func closeDispositionStartsNil() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/fresh")!)
        #expect(await task.closeDisposition == nil)
    }

    @Test("Task reset clears closeDisposition")
    func taskResetClearsDisposition() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/reset")!)
        await task.setCloseDisposition(.manual(.normalClosure))
        #expect(await task.closeDisposition != nil)
        await task.reset()
        #expect(await task.closeDisposition == nil)
    }
}


/// Waits for `task.closeDisposition` to become non-nil.
private func waitForCloseDisposition(
    task: WebSocketTask,
    timeout: Duration
) async -> WebSocketCloseDisposition? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let disposition = await task.closeDisposition {
            return disposition
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await task.closeDisposition
}

private func waitForManagerTaskRemoval(
    manager: WebSocketManager,
    task: WebSocketTask,
    timeout: Duration
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await manager.task(withId: task.id) == nil {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await manager.task(withId: task.id) == nil
}
