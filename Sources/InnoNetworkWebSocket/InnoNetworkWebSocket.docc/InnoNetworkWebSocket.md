# ``InnoNetworkWebSocket``

Connection-oriented realtime flows with reconnect-aware lifecycle handling, heartbeat monitoring, and explicit WebSocket event delivery.

## Overview

`InnoNetworkWebSocket` wraps `URLSessionWebSocketTask` with a state model that is easier to reason about in production clients.

Use this module when you need:

- reconnect-aware connection management
- heartbeat and pong timeout handling, surfaced as paired `.ping` / `.pong` /
  `.error(.pingTimeout)` events
- typed close-code handling via ``WebSocketCloseCode``
- async handshake request adaptation via ``WebSocketHandshakeRequestAdapter``
- listener retention across reconnect attempts
- manual disconnect semantics that stay visible to the caller

Reconnect decisions are driven by handshake and close outcomes, so the public manager can distinguish retryable failures from terminal ones without forcing application code to rebuild that policy every time.

Create feature-scoped ``WebSocketManager`` instances so reconnect, heartbeat,
send-buffer, and event-delivery policy stay owned by the feature that opens the
socket. See <doc:FeatureScopedManagers>.

Event delivery for socket tasks flows through the shared event hub. Tune buffering, overflow behavior, and metrics integration via ``WebSocketConfiguration/eventDeliveryPolicy`` — see <doc:EventDeliveryPolicy> in the core module for a full guide.

### Observing heartbeat attempts

The 4.0.0 public contract emits a `.ping` event before each heartbeat or manual
ping attempt. Pair it with `.pong` and `.error(.pingTimeout)` to track heartbeat
success, timeout, and approximate round-trip timing in application code.

```swift
var pendingPingAt: Date?

for await event in await manager.events(for: task) {
    switch event {
    case .ping(_):
        pendingPingAt = .now
    case .pong(_):
        if let started = pendingPingAt {
            metrics.recordPingRTT(.now.timeIntervalSince(started))
        }
        pendingPingAt = nil
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
- ``WebSocketHandshakeRequestAdapter``
- ``WebSocketTask``
- ``WebSocketState``

### Events and observability

- ``WebSocketEvent``
- ``WebSocketCloseCode``
- <doc:CloseCodes>

### Realtime Flows

- <doc:Reconnect>
- <doc:FeatureScopedManagers>
- <doc:WebSocketProtocolPolicy>
- <doc:WebSocketBackgroundTransition>
- ``WebSocketManager``
- ``WebSocketConfiguration``
- ``WebSocketTask``
