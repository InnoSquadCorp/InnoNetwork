# ``InnoNetworkWebSocket``

Connection-oriented realtime flows with reconnect-aware lifecycle handling, heartbeat monitoring, and explicit WebSocket event delivery.

## Overview

`InnoNetworkWebSocket` wraps `URLSessionWebSocketTask` with a state model that is easier to reason about in production clients.

Use this module when you need:

- reconnect-aware connection management
- heartbeat and pong timeout handling, surfaced as paired ``WebSocketEvent/ping(_:)``/``WebSocketEvent/pong`` events plus optional pong RTT callbacks
- observable close classification via ``WebSocketTask/closeDisposition``
- listener retention across reconnect attempts
- manual disconnect semantics that stay visible to the caller

Reconnect decisions are driven by handshake and close outcomes, so the public manager can distinguish retryable failures from terminal ones without forcing application code to rebuild that policy every time. When UX needs to branch on the reason (for example showing a "retrying…" banner only for ``WebSocketCloseDisposition/peerRetryable(_:_:)``), consumers read ``WebSocketTask/closeDisposition`` after the task reaches `.disconnected` / `.failed`.

Event delivery for socket tasks flows through the shared event hub. Tune buffering, overflow behavior, and metrics integration via ``WebSocketConfiguration/eventDeliveryPolicy`` — see <doc:EventDeliveryPolicy> in the core module for a full guide.

### Measuring heartbeat RTT

As of 5.0, ``WebSocketEvent/pong(_:)`` carries a
``WebSocketPongContext`` directly, and
``WebSocketManager/setOnPongHandler(_:)`` delivers the **same context value**
at the same logical point. Pick whichever surface your architecture already
consumes:

```swift
// Event stream
for await event in await manager.events(for: task) {
    switch event {
    case .pong(let context):
        metrics.recordPingRTT(context.roundTrip)
        metrics.correlate(attempt: context.attemptNumber)
    default:
        break
    }
}

// Or callback convenience
await manager.setOnPongHandler { _, context in
    metrics.recordPingRTT(context.roundTrip)
    metrics.correlate(attempt: context.attemptNumber)
}
```

Both paths receive identical `attemptNumber` / `roundTrip` values. In
Swift pattern-matching positions, `case .pong:` remains valid when you do
not need the payload. The source-breaking change is code that constructs
or refers to `.pong` as a value, which must now account for the
associated `WebSocketPongContext` — see `MIGRATION_v5.md` for examples.

`roundTrip` is measured as `ContinuousClock.now - pingContext.dispatchedAt`
just before the paired `.pong(_:)` event is published — it reflects the
library-observed span from `.ping(_:)` emission to successful pong handling
(excluding consumer-side scheduler jitter). Heartbeat cadence and timeout
control still use the injected ``InnoNetwork/InnoNetworkClock``; only the RTT
measurement itself is wall-clock `ContinuousClock` time.

## Topics

### Essentials

- ``WebSocketManager``
- ``WebSocketConfiguration``
- ``WebSocketTask``
- ``WebSocketState``

### Events and observability

- ``WebSocketEvent``
- ``WebSocketPingContext``
- ``WebSocketPongContext``
- ``WebSocketCloseCode``
- ``WebSocketCloseDisposition``

### Realtime Flows

- ``WebSocketManager``
- ``WebSocketConfiguration``
- ``WebSocketTask``
