import Foundation
import Testing

@testable import InnoNetworkWebSocket

@Suite("WebSocket lifecycle reducer tests")
struct WebSocketLifecycleReducerTests {
    @Test("connect then didOpen transitions to connected")
    func connectThenDidOpenTransitionsToConnected() async {
        let connecting = WebSocketLifecycleReducer.reduce(
            state: .initial,
            event: .connect
        )

        #expect(connecting.state.publicState == .connecting)
        #expect(connecting.state.generation == 1)
        #expect(connecting.effects == [.cancelReconnect, .startConnection(generation: 1)])

        let connected = WebSocketLifecycleReducer.reduce(
            state: connecting.state,
            event: .didOpen(generation: 1, protocolName: "chat")
        )

        #expect(connected.state.publicState == .connected)
        #expect(
            connected.effects == [
                .cancelReconnect,
                .startHeartbeat,
                .publishConnected(protocolName: "chat"),
            ])
    }

    @Test("connected manual disconnect finalizes through disconnected")
    func connectedManualDisconnectFinalizesThroughDisconnected() async {
        let connected = WebSocketLifecycleState.connected(
            generation: 3,
            attempt: 0,
            autoReconnect: true
        )
        let manualError = WebSocketError.disconnected(nil)
        let disconnecting = WebSocketLifecycleReducer.reduce(
            state: connected,
            event: .manualDisconnect(closeCode: .normalClosure, error: manualError)
        )

        #expect(disconnecting.state.publicState == .disconnecting)
        #expect(
            disconnecting.effects == [
                .cancelHeartbeat,
                .cancelReconnect,
                .cancelMessageListener,
                .scheduleCloseTimeout(closeCode: .normalClosure),
            ])

        let closed = WebSocketLifecycleReducer.reduce(
            state: disconnecting.state,
            event: .didClose(
                generation: 3,
                closeCode: .normalClosure,
                disposition: .manual(.normalClosure),
                error: manualError
            )
        )

        #expect(closed.state.publicState == .disconnected)
        #expect(closed.state.autoReconnectEnabled == false)
        #expect(
            closed.effects == [
                .cleanupRuntime,
                .cancelCloseTimeout,
                .publishDisconnected(error: manualError),
                .finishTerminal(generation: 3),
            ])
    }

    @Test("retryable peer close schedules reconnect then timer starts fresh generation")
    func retryablePeerCloseSchedulesReconnectThenTimerStartsFreshGeneration() async {
        let connected = WebSocketLifecycleState.connected(
            generation: 4,
            attempt: 0,
            autoReconnect: true
        )
        let error = WebSocketError.disconnected(nil)
        let reconnecting = WebSocketLifecycleReducer.reduce(
            state: connected,
            event: .didClose(
                generation: 4,
                closeCode: .goingAway,
                disposition: .peerRetryable(.goingAway, nil),
                error: error
            ),
            context: .init(reconnectAction: .retry, attempt: 1)
        )

        #expect(reconnecting.state.publicState == .reconnecting)
        #expect(reconnecting.state.generation == 4)
        #expect(reconnecting.state.attempt == 1)
        #expect(reconnecting.state.closeCode == .goingAway)
        #expect(
            reconnecting.effects == [
                .cleanupRuntime,
                .cancelHeartbeat,
                .cancelMessageListener,
                .publishDisconnected(error: error),
                .scheduleReconnect,
            ])

        let connecting = WebSocketLifecycleReducer.reduce(
            state: reconnecting.state,
            event: .reconnectTimerFired
        )

        #expect(connecting.state.publicState == .connecting)
        #expect(connecting.state.generation == 5)
        #expect(connecting.effects == [.startConnection(generation: 5)])
    }

    @Test("exceeded peer close preserves close code on failed state")
    func exceededPeerClosePreservesCloseCodeOnFailedState() async {
        let connected = WebSocketLifecycleState.connected(
            generation: 4,
            attempt: 2,
            autoReconnect: true
        )
        let failed = WebSocketLifecycleReducer.reduce(
            state: connected,
            event: .didClose(
                generation: 4,
                closeCode: .goingAway,
                disposition: .peerRetryable(.goingAway, nil),
                error: .disconnected(nil)
            ),
            context: .init(reconnectAction: .exceeded(reason: .attempts), attempt: 3)
        )

        #expect(failed.state.publicState == .failed)
        #expect(failed.state.closeCode == .goingAway)
        #expect(failed.state.error == .maxReconnectAttemptsExceeded)
    }

    @Test("terminal handshake failure transitions to failed")
    func terminalHandshakeFailureTransitionsToFailed() async {
        let connecting = WebSocketLifecycleState.connecting(
            generation: 2,
            attempt: 0,
            autoReconnect: true
        )
        let error = WebSocketError.unknown
        let failed = WebSocketLifecycleReducer.reduce(
            state: connecting,
            event: .failure(
                generation: 2,
                disposition: .handshakeForbidden(403),
                error: error
            ),
            context: .init(reconnectAction: .terminal, attempt: 0)
        )

        #expect(failed.state.publicState == .failed)
        #expect(
            failed.effects == [
                .cleanupRuntime,
                .cancelHeartbeat,
                .cancelMessageListener,
                .publishError(error),
                .finishTerminal(generation: 2),
            ])
    }

    @Test("disconnecting stale didOpen does not mutate state or generation")
    func disconnectingStaleDidOpenDoesNotMutateStateOrGeneration() async {
        let disconnecting = WebSocketLifecycleState.disconnecting(
            generation: 7,
            attempt: 1,
            manualDisconnect: .init(closeCode: .normalClosure, error: .disconnected(nil))
        )
        let afterDidOpen = WebSocketLifecycleReducer.reduce(
            state: disconnecting,
            event: .didOpen(generation: 7, protocolName: "stale")
        )

        #expect(afterDidOpen.state == disconnecting)
        #expect(afterDidOpen.effects == [.ignoreStaleCallback])
    }

    @Test("stale close and failure callbacks do not mutate the current generation")
    func staleCloseAndFailureCallbacksDoNotMutateCurrentGeneration() async {
        let connecting = WebSocketLifecycleState.connecting(
            generation: 10,
            attempt: 1,
            autoReconnect: true
        )
        let staleClose = WebSocketLifecycleReducer.reduce(
            state: connecting,
            event: .didClose(
                generation: 9,
                closeCode: .goingAway,
                disposition: .peerRetryable(.goingAway, nil),
                error: .disconnected(nil)
            ),
            context: .init(reconnectAction: .retry, attempt: 2)
        )
        let staleFailure = WebSocketLifecycleReducer.reduce(
            state: connecting,
            event: .failure(
                generation: 9,
                disposition: .transportFailure(.pingTimeout),
                error: .pingTimeout
            ),
            context: .init(reconnectAction: .retry, attempt: 2)
        )

        #expect(staleClose.state == connecting)
        #expect(staleClose.effects == [.ignoreStaleCallback])
        #expect(staleFailure.state == connecting)
        #expect(staleFailure.effects == [.ignoreStaleCallback])
    }

    @Test("terminal states ignore late close and failure callbacks")
    func terminalStatesIgnoreLateCloseAndFailureCallbacks() async {
        let failed = WebSocketLifecycleState.failed(
            generation: 11,
            attempt: 3,
            autoReconnect: true,
            closeCode: nil,
            disposition: .handshakeForbidden(403),
            error: .unknown
        )
        let lateClose = WebSocketLifecycleReducer.reduce(
            state: failed,
            event: .didClose(
                generation: 11,
                closeCode: .goingAway,
                disposition: .peerRetryable(.goingAway, nil),
                error: .disconnected(nil)
            ),
            context: .init(reconnectAction: .retry, attempt: 4)
        )

        #expect(lateClose.state == failed)
        #expect(lateClose.effects == [.ignoreStaleCallback])

        let disconnected = WebSocketLifecycleState.disconnected(
            generation: 12,
            attempt: 1,
            autoReconnect: false,
            closeCode: .normalClosure,
            disposition: .manual(.normalClosure),
            error: .disconnected(nil)
        )
        let lateFailure = WebSocketLifecycleReducer.reduce(
            state: disconnected,
            event: .failure(
                generation: 12,
                disposition: .transportFailure(.pingTimeout),
                error: .pingTimeout
            ),
            context: .init(reconnectAction: .retry, attempt: 2)
        )

        #expect(lateFailure.state == disconnected)
        #expect(lateFailure.effects == [.ignoreStaleCallback])
    }

    @Test("WebSocketTask updateState rejects illegal production transitions")
    func taskUpdateStateRejectsIllegalProductionTransitions() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        let rejected = await task.updateState(.failed)
        #expect(rejected == .rejected(previous: .idle, next: .failed))
        #expect(await task.state == .idle)

        let applied = await task.updateState(.connecting)
        #expect(applied == .applied(previous: .idle, next: .connecting))
        #expect(await task.state == .connecting)

        let sameState = await task.updateState(.connecting)
        #expect(sameState == .applied(previous: .connecting, next: .connecting))
        #expect(await task.state == .connecting)
    }

    @Test("restoreStateForTesting bypasses production transition enforcement")
    func restoreStateForTestingBypassesProductionTransitionEnforcement() async {
        let task = WebSocketTask(url: URL(string: "wss://example.invalid/socket")!)

        await task.restoreStateForTesting(.failed)

        #expect(await task.state == .failed)
    }
}
