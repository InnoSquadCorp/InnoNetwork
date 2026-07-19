import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

extension WebSocketManagerShutdownTests {

    func makeShutdownHarness(
        configuration: WebSocketConfiguration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 0,
        ),
        clock: any InnoNetworkClock = SystemClock()
    ) -> ShutdownHarness {
        let session = StubWebSocketURLSession()
        let callbacks = WebSocketSessionDelegateCallbacks()
        let delegate = WebSocketSessionDelegate(
            callbacks: callbacks,
        )
        let manager = WebSocketManager(
            configuration: configuration,
            urlSession: session,
            delegate: delegate,
            callbacks: callbacks,
            clock: clock
        )
        return ShutdownHarness(manager: manager, session: session, callbacks: callbacks)
    }

    struct ShutdownHarness {
        let manager: WebSocketManager
        let session: StubWebSocketURLSession
        let callbacks: WebSocketSessionDelegateCallbacks
    }

    enum BufferedTerminalDelegateEvent: Sendable {
        case mappedError
        case didClose

        func delegateEvent(taskIdentifier: Int) -> WebSocketManager.DelegateEvent {
            switch self {
            case .mappedError:
                .mappedError(taskIdentifier: taskIdentifier, error: .pingTimeout)
            case .didClose:
                .disconnected(
                    taskIdentifier: taskIdentifier,
                    closeCode: .normalClosure,
                    reason: nil
                )
            }
        }
    }

    enum TerminalHandlerReplacementCase: Sendable {
        case error
        case disconnected
    }

    enum ManualPingCompletion: Sendable {
        case success
        case failure
    }
}

final class TerminalPublicationMetricRecorder: EventPipelineMetricsReporting,
    @unchecked Sendable
{
    private let droppedPartitionTaskIDs = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    func report(_ metric: EventPipelineMetric) {
        guard case .partitionState(let state) = metric, state.droppedEventCount > 0 else { return }
        _ = droppedPartitionTaskIDs.withLock { $0.insert(state.partitionID) }
    }

    func sawDroppedPartitionEvent(taskID: String) -> Bool {
        droppedPartitionTaskIDs.withLock { $0.contains(taskID) }
    }
}

actor ShutdownDelegateGate {
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

enum ThrowingHandshakeAdapterTestError: Error, Sendable, LocalizedError {
    case tokenUnavailable

    var errorDescription: String? {
        "Handshake token lookup failed"
    }
}


@Sendable
func waitForCondition(
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
