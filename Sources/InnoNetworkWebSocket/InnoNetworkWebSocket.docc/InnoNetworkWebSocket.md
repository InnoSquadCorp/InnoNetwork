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

As of 4.3, ``WebSocketManager/setOnPongHandler(_:)`` delivers a
``WebSocketPongContext`` with the library-computed `roundTrip: Duration`, so
there is no need to thread a timestamp through your event handler.

```swift
await manager.setOnPongHandler { _, context in
    metrics.recordPingRTT(context.roundTrip)
}
```

``WebSocketPongContext/attemptNumber`` matches the
``WebSocketPingContext/attemptNumber`` of the paired ping, so consumers that
want to correlate ping → pong explicitly can still do so:

```swift
case .ping(let context):
    openSpans[context.attemptNumber] = context.dispatchedAt
await manager.setOnPongHandler { _, context in
    openSpans[context.attemptNumber] = nil
    metrics.recordPingRTT(context.roundTrip)
}
```

`roundTrip` is measured as `ContinuousClock.now - pingContext.dispatchedAt`
just before the paired `.pong` event is published — it reflects the
library-observed span from `.ping(_:)` emission to successful pong handling
(excluding consumer-side scheduler jitter).

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
