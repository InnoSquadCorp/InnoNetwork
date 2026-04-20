# ``InnoNetworkWebSocket``

Connection-oriented realtime flows with reconnect-aware lifecycle handling, heartbeat monitoring, and explicit WebSocket event delivery.

## Overview

`InnoNetworkWebSocket` wraps `URLSessionWebSocketTask` with a state model that is easier to reason about in production clients.

Use this module when you need:

- reconnect-aware connection management
- heartbeat and pong timeout handling, surfaced as paired ``WebSocketEvent/ping(_:)``/``WebSocketEvent/pong`` events with attempt-number and dispatch-time context
- observable close classification via ``WebSocketTask/closeDisposition``
- listener retention across reconnect attempts
- manual disconnect semantics that stay visible to the caller

Reconnect decisions are driven by handshake and close outcomes, so the public manager can distinguish retryable failures from terminal ones without forcing application code to rebuild that policy every time. When UX needs to branch on the reason (for example showing a "retrying…" banner only for ``WebSocketCloseDisposition/peerRetryable(_:_:)``), consumers read ``WebSocketTask/closeDisposition`` after the task reaches `.disconnected` / `.failed`.

### Measuring heartbeat RTT

Every ping emission carries a ``WebSocketPingContext``. Pair its ``WebSocketPingContext/dispatchedAt`` with a ``ContinuousClock`` reading at pong receipt to compute round-trip time without client-side bookkeeping.

```swift
var pendingPingAt: ContinuousClock.Instant?
for await event in await manager.events(for: task) {
    switch event {
    case .ping(let context):
        pendingPingAt = context.dispatchedAt
    case .pong:
        if let started = pendingPingAt {
            metrics.recordPingRTT(ContinuousClock.now - started)
            pendingPingAt = nil
        }
    case .error(.pingTimeout):
        metrics.recordPingTimeout()
        pendingPingAt = nil
    default:
        break
    }
}
```

## Topics

### Essentials

- ``WebSocketManager``
- ``WebSocketConfiguration``
- ``WebSocketTask``
- ``WebSocketState``

### Events and observability

- ``WebSocketEvent``
- ``WebSocketPingContext``
- ``WebSocketCloseCode``
- ``WebSocketCloseDisposition``

### Realtime Flows

- ``WebSocketManager``
- ``WebSocketConfiguration``
- ``WebSocketTask``
