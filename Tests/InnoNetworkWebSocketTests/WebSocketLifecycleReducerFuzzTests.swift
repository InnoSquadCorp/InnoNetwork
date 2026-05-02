import Foundation
import Testing

@testable import InnoNetworkWebSocket

/// Property-based fuzz coverage over `WebSocketLifecycleReducer`.
///
/// Drives the reducer with deterministic random walks across the
/// full `WebSocketLifecycleEvent` × `WebSocketReconnectAction` space
/// and asserts the lifecycle invariants the production callers rely
/// on:
///
/// 1. The reducer is deterministic: equal `(state, event, context)`
///    triples produce equal transitions.
/// 2. Generation counters are monotonic — they never decrease.
/// 3. `disconnected(.manual(_))` and `failed(.maxReconnectAttemptsExceeded)`
///    are absorbing once entered without an explicit `reset` /
///    `connect`.
/// 4. Stale-callback events (a `didOpen` / `didClose` / `failure`
///    tagged with a generation that is not the current one) are
///    ignored: the state does not change and the only effect is
///    `.ignoreStaleCallback`.
///
/// Note: this fuzz test does not assert that every transition is in
/// `WebSocketState/canTransition(to:)`. The reducer is intentionally
/// more permissive than that documentation table — `.reset` can land
/// in `.idle` from any state, and `.connect` can re-enter `.connecting`
/// from any non-terminal state — and the reducer is the authority.
@Suite("WebSocket lifecycle reducer fuzz")
struct WebSocketLifecycleReducerFuzzTests {
    private static let seeds: [UInt64] = [
        0x1234_5678_ABCD_EF01,
        0xDEAD_BEEF_CAFE_BABE,
        0x0F0F_0F0F_0F0F_0F0F,
        0xFEDC_BA98_7654_3210,
        0xA5A5_5A5A_3C3C_C3C3,
    ]

    @Test("reducer is deterministic for equal inputs", arguments: seeds)
    func reducerIsDeterministicForEqualInputs(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var state = WebSocketLifecycleState.initial

        for _ in 0..<1000 {
            let event = randomEvent(state: state, rng: &rng)
            let context = randomContext(rng: &rng)
            let first = WebSocketLifecycleReducer.reduce(
                state: state,
                event: event,
                context: context
            )
            let second = WebSocketLifecycleReducer.reduce(
                state: state,
                event: event,
                context: context
            )

            #expect(first.state == second.state)
            #expect(first.effects == second.effects)
            state = first.state
        }
    }

    @Test("generation counter is monotonic", arguments: seeds)
    func generationCounterIsMonotonic(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var state = WebSocketLifecycleState.initial

        for _ in 0..<1000 {
            let previousGeneration = state.generation
            let event = randomEvent(state: state, rng: &rng)
            let context = randomContext(rng: &rng)
            let transition = WebSocketLifecycleReducer.reduce(
                state: state,
                event: event,
                context: context
            )

            #expect(
                transition.state.generation >= previousGeneration,
                "generation regressed \(previousGeneration) → \(transition.state.generation) on \(event)"
            )
            state = transition.state
        }
    }

    @Test("manual-disconnect terminal is absorbing without reset")
    func manualDisconnectTerminalIsAbsorbing() {
        let connected = WebSocketLifecycleState.connected(
            generation: 5,
            attempt: 2,
            autoReconnect: true
        )
        let disconnecting = WebSocketLifecycleReducer.reduce(
            state: connected,
            event: .manualDisconnect(closeCode: .normalClosure, error: nil)
        )
        let terminal = WebSocketLifecycleReducer.reduce(
            state: disconnecting.state,
            event: .didClose(
                generation: 5,
                closeCode: .normalClosure,
                disposition: .manual(.normalClosure),
                error: nil
            )
        )

        #expect(terminal.state.publicState == .disconnected)
        #expect(terminal.state.publicState.isTerminal)

        let nonResetEvents: [WebSocketLifecycleEvent] = [
            .didOpen(generation: 5, protocolName: nil),
            .didClose(
                generation: 5, closeCode: .abnormalClosure, disposition: .peerTerminal(.abnormalClosure, nil),
                error: nil),
            .failure(generation: 5, disposition: .peerTerminal(.abnormalClosure, nil), error: .pingTimeout),
            .closeTimeout(closeCode: .normalClosure, error: .pingTimeout),
            .reconnectTimerFired,
            .manualDisconnect(closeCode: .normalClosure, error: nil),
        ]

        var current = terminal.state
        for event in nonResetEvents {
            let next = WebSocketLifecycleReducer.reduce(
                state: current,
                event: event,
                context: .init(reconnectAction: .terminal)
            )
            #expect(
                next.state.publicState == .disconnected,
                "absorbing terminal escaped on \(event) → \(next.state.publicState)"
            )
            current = next.state
        }
    }

    @Test("max-reconnect-exceeded failed state is absorbing without reset")
    func maxReconnectExceededIsAbsorbing() {
        let connected = WebSocketLifecycleState.connected(
            generation: 7,
            attempt: 9,
            autoReconnect: true
        )
        let failed = WebSocketLifecycleReducer.reduce(
            state: connected,
            event: .didClose(
                generation: 7,
                closeCode: .abnormalClosure,
                disposition: .peerTerminal(.abnormalClosure, nil),
                error: .pingTimeout
            ),
            context: .init(reconnectAction: .exceeded(reason: .attempts), attempt: 10)
        )

        #expect(failed.state.publicState == .failed)
        #expect(failed.state.publicState.isTerminal)
        #expect(failed.state.error == .maxReconnectAttemptsExceeded)

        let nonResetEvents: [WebSocketLifecycleEvent] = [
            .didOpen(generation: 7, protocolName: nil),
            .didClose(
                generation: 7, closeCode: .abnormalClosure, disposition: .peerTerminal(.abnormalClosure, nil),
                error: nil),
            .failure(generation: 7, disposition: .peerTerminal(.abnormalClosure, nil), error: .pingTimeout),
            .closeTimeout(closeCode: .normalClosure, error: .pingTimeout),
            .reconnectTimerFired,
            .manualDisconnect(closeCode: .normalClosure, error: nil),
        ]

        var current = failed.state
        for event in nonResetEvents {
            let next = WebSocketLifecycleReducer.reduce(
                state: current,
                event: event,
                context: .init(reconnectAction: .terminal)
            )
            #expect(
                next.state.publicState == .failed,
                "absorbing failed escaped on \(event) → \(next.state.publicState)"
            )
            current = next.state
        }
    }

    @Test("stale callbacks never mutate state or effects beyond ignoreStaleCallback", arguments: seeds)
    func staleCallbacksNeverMutateState(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var state = WebSocketLifecycleState.initial

        for _ in 0..<200 {
            let event = randomEvent(state: state, rng: &rng)
            let context = randomContext(rng: &rng)
            state =
                WebSocketLifecycleReducer.reduce(
                    state: state,
                    event: event,
                    context: context
                ).state

            let staleGeneration = state.generation - 10
            let staleEvents: [WebSocketLifecycleEvent] = [
                .didOpen(generation: staleGeneration, protocolName: nil),
                .didClose(
                    generation: staleGeneration,
                    closeCode: .abnormalClosure,
                    disposition: .peerTerminal(.abnormalClosure, nil),
                    error: nil
                ),
                .failure(
                    generation: staleGeneration, disposition: .peerTerminal(.abnormalClosure, nil), error: .pingTimeout),
            ]

            for stale in staleEvents {
                let result = WebSocketLifecycleReducer.reduce(
                    state: state,
                    event: stale
                )
                #expect(
                    result.state == state,
                    "stale event \(stale) mutated state \(state) → \(result.state)"
                )
                #expect(
                    result.effects == [.ignoreStaleCallback],
                    "stale event \(stale) produced unexpected effects \(result.effects)"
                )
            }
        }
    }

    private func randomEvent(
        state: WebSocketLifecycleState,
        rng: inout SplitMix64
    ) -> WebSocketLifecycleEvent {
        let pick = rng.next() % 8
        switch pick {
        case 0:
            return .connect
        case 1:
            return .didOpen(generation: state.generation, protocolName: nil)
        case 2:
            return .manualDisconnect(closeCode: .normalClosure, error: nil)
        case 3:
            return .didClose(
                generation: state.generation,
                closeCode: .abnormalClosure,
                disposition: .peerTerminal(.abnormalClosure, nil),
                error: nil
            )
        case 4:
            return .failure(
                generation: state.generation,
                disposition: .peerTerminal(.abnormalClosure, nil),
                error: .pingTimeout
            )
        case 5:
            return .closeTimeout(closeCode: .normalClosure, error: .pingTimeout)
        case 6:
            return .reconnectTimerFired
        default:
            return .reset
        }
    }

    private func randomContext(rng: inout SplitMix64) -> WebSocketLifecycleDecisionContext {
        let pick = rng.next() % 3
        switch pick {
        case 0:
            return .init(reconnectAction: .retry, attempt: Int(rng.next() % 5))
        case 1:
            return .init(reconnectAction: .terminal)
        default:
            return .init(reconnectAction: .exceeded(reason: .attempts), attempt: Int(rng.next() % 10) + 1)
        }
    }
}

/// Deterministic 64-bit PRNG (SplitMix64) so fuzz iterations are
/// reproducible across runs and Swift versions.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
