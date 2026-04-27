# WebSocket Lifecycle

`WebSocketManager` exposes a typed state machine that mirrors the underlying
`URLSessionWebSocketTask` plus the library's reconnect bookkeeping. This page documents the
allowed transitions, the invariants enforced across reconnect, and the corner cases that
informed the current contract.

## State machine

```mermaid
stateDiagram-v2
    [*] --> idle

    idle --> connecting : connect(_:)
    connecting --> connected : URLSession didOpenWithProtocol
    connecting --> failed : handshake error (terminal)
    connecting --> disconnected : peer close before open
    connecting --> disconnecting : disconnect(_:closeCode:)

    connected --> disconnecting : disconnect(_:closeCode:)
    connected --> reconnecting : peer close (retryable)
    connected --> failed : transport failure (terminal)
    connected --> disconnected : peer close (manual / terminal)

    reconnecting --> connecting : backoff elapsed, attempt
    reconnecting --> connected : reattach succeeded mid-attempt
    reconnecting --> failed : maxReconnectAttempts exhausted
    reconnecting --> disconnected : disconnect(_:closeCode:)

    disconnecting --> disconnected : close handshake completes
    disconnected --> connecting : connect(_:) again
    disconnected --> reconnecting : auto-reconnect armed by peer close
    disconnected --> failed : observer-driven failure escalation

    failed --> idle : reset()
    failed --> connecting : connect(_:) (manual restart)
```

`isTerminal` is `true` only for `disconnected` and `failed`. Every other state is observable
as a "moving" state from the manager's perspective.

The single source of truth is [`WebSocketState.swift`](../Sources/InnoNetworkWebSocket/WebSocketState.swift):
the `nextStates` and `canTransition(to:)` accessors are the contract used by reconnect and
disconnect coordinators.

## Reconnect classification

Whether a peer-initiated close transitions to `reconnecting` or `failed` is decided by
[`WebSocketCloseDisposition`](../Sources/InnoNetworkWebSocket/WebSocketCloseDisposition.swift).
The mapping is:

| Disposition | Trigger | Next state |
|-------------|---------|------------|
| `.manual` | Caller invoked `disconnect(_:closeCode:)` | `disconnected` |
| `.peerNormal` | RFC 6455 `1000` (normal closure) | `disconnected` |
| `.peerRetryable` | `1001`, `1006`, `1011`, `1012`, `1013`, `1014`, `1015` | `reconnecting` |
| `.peerTerminal` | `1003`, `1007`, `1008`, `1009`, `1010` (protocol/policy) | `failed` |
| `.handshakeRetryable` | HTTP `429` / `5xx` on upgrade | `reconnecting` |
| `.handshakeTerminal` | HTTP `401` / `403` / `404` on upgrade | `failed` |
| `.handshakeUnauthorized` | HTTP `401` specifically | `failed` (caller should refresh auth before reconnecting manually) |
| `.transportFailure` | NSURLError transient (timeout, DNS, network lost) | `reconnecting` |

Custom close codes (3000–4999) default to **terminal**. If your app uses an application-
defined retryable code, classify it explicitly via `WebSocketConfiguration` rather than
relying on the default.

## Auto-reconnect invariants

These invariants prevent `_autoReconnectEnabled` from racing against
`disconnect(_:closeCode:)`:

1. **Manual disconnect always wins.** If the caller invokes `disconnect` while
   `reconnecting`, the manager cancels the in-flight reconnect timer and transitions
   directly to `disconnected`. No further attempts are scheduled.
2. **Disconnect during `connecting` is honored.** A manual disconnect during the
   handshake cancels the `URLSessionWebSocketTask` and transitions through
   `disconnecting → disconnected`. The handshake error, if any, is suppressed because the
   caller's intent is to terminate.
3. **`maxReconnectAttempts` is a hard cap.** The cap is checked in
   `WebSocketReconnectCoordinator.reconnectAction(_:_:)` *before* state mutation. Even if
   the count overshoots due to multiple coordinator entries, the public-facing decision
   stays at `.exceeded` once the cap is reached. (See `WebSocketTask` counter docs in
   [`WebSocketTask.swift`](../Sources/InnoNetworkWebSocket/WebSocketTask.swift) for why
   the internal counter may overshoot.)
4. **Reconnect attempts use a fresh `URLSessionWebSocketTask`.** Each attempt rebuilds the
   request with the latest interceptors and cookies. Server-issued auth tokens that expired
   between attempts will surface as a fresh `handshakeUnauthorized` and stop the loop.

## Heartbeat and ping/pong

`WebSocketHeartbeatCoordinator` issues pings on the configured cadence. Each attempt:

1. Emits `WebSocketEvent.ping(attemptNumber:dispatchedAt:)` immediately before the send.
2. Awaits either a pong or the configured `pongTimeout`, whichever comes first.
3. On pong: emits `.pong(rtt:)` (RTT measured against `dispatchedAt` using
   `ContinuousClock`).
4. On timeout: increments `missedPongs`. After `maxMissedPongs` consecutive timeouts the
   manager surfaces `WebSocketError.pingTimeout` and transitions to either `reconnecting`
   or `failed` per the reconnect policy.

The `attemptNumber` is per-connection (1-indexed) and resets across reconnects so dashboards
can filter "this socket lost N consecutive pongs".

## Manual reconnect (escape hatch)

For debugging or auth-refresh flows, you can drive reconnect manually:

```swift
let task = await WebSocketManager.shared.connect(url: socketURL)

// Force a clean reconnect with a custom close code (e.g. application-defined 4001):
await WebSocketManager.shared.disconnect(task, closeCode: .custom(4001))
let resumed = await WebSocketManager.shared.connect(url: socketURL)
```

The new connect call returns a *new* `WebSocketTask` (different `id`) — the previous task's
listeners are not preserved automatically. If you need listener retention across a manual
reset, attach observers to `WebSocketManager` directly rather than per-task.

## Related

- [`WebSocketState.swift`](../Sources/InnoNetworkWebSocket/WebSocketState.swift) — state enum and
  transitions.
- [`WebSocketCloseDisposition.swift`](../Sources/InnoNetworkWebSocket/WebSocketCloseDisposition.swift) —
  close-code classification.
- [`WebSocketReconnectCoordinator.swift`](../Sources/InnoNetworkWebSocket/WebSocketReconnectCoordinator.swift) —
  backoff and attempt accounting.
- [`MIGRATION_v4.md`](../MIGRATION_v4.md) — close-code typing changes for v4.
