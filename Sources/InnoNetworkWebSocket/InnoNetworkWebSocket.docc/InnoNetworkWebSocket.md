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
- typed application messages via ``WebSocketMessageCodec`` and
  ``JSONWebSocketMessageCodec``
- listener retention across automatic reconnect transport generations
- explicit retry through ``WebSocketManager/retry(_:)``, which returns a fresh
  task and a pre-registered bounded event stream in ``WebSocketRetryResult``
- manual disconnect semantics that stay visible to the caller

Reconnect decisions are driven by handshake and close outcomes, so the public manager can distinguish retryable failures from terminal ones without forcing application code to rebuild that policy every time.

Create feature-scoped ``WebSocketManager`` instances so reconnect, heartbeat,
send-buffer, and event-delivery policy stay owned by the feature that opens the
socket. See <doc:FeatureScopedManagers>.

Event delivery for socket tasks flows through the shared event hub. Tune
buffering, overflow behavior, and metrics integration through
``WebSocketObservabilityPack`` — see the [event delivery guide](https://innosquadcorp.github.io/InnoNetwork/InnoNetwork/documentation/innonetwork/eventdeliveryguide)
in the core module.

### Event streams are bounded

``WebSocketManager/events(for:)`` does not buffer without limit. Every stream
or listener has its own queue of at most `maxBufferedEventsPerConsumer`
events, and the task has a partition queue of at most
`maxBufferedEventsPerPartition` events:

| Configuration | Events per consumer | Events per partition | Overflow |
| --- | --- | --- | --- |
| ``WebSocketConfiguration/safeDefaults()`` (`EventDeliveryPolicy.default`) | 256 | 256 | `.dropOldest` |
| ``WebSocketConfiguration/advanced(connection:liveness:reconnect:messaging:observability:)`` with the default ``WebSocketObservabilityPack`` | 512 | 512 | `.dropOldest` |

A consumer that falls behind therefore loses its **oldest** queued events,
including `.message` and `.string` frames. The socket is not slowed down and
the stream delivers no event for the gap. Only the task's final outcome is
always admitted. Do not treat the stream as a lossless message log: read it
promptly, move slow work off the iteration, and let the application protocol
detect gaps (sequence numbers, or a resynchronizing request after a reconnect).

To see drops, pass an `EventPipelineMetricsReporting` reporter. A consumer or
partition that dropped events reports a nonzero `droppedEventCount`, and each
aggregate snapshot reports the drops since the previous snapshot in
`overflowEventCount` and the running total in `totalDroppedEventCount`. Size
the buffers with an `EventDeliveryPolicy` on ``WebSocketObservabilityPack``:

```swift
import InnoNetwork
import InnoNetworkWebSocket

struct DropReporter: EventPipelineMetricsReporting {
    func report(_ metric: EventPipelineMetric) {
        switch metric {
        case .consumerState(let state) where state.droppedEventCount > 0:
            logger.warning("consumer \(state.consumerID) dropped \(state.droppedEventCount) events")
        case .aggregateSnapshot(let snapshot) where snapshot.overflowEventCount > 0:
            logger.warning("\(snapshot.overflowEventCount) events dropped since the last snapshot")
        default:
            break
        }
    }
}

let configuration = WebSocketConfiguration.advanced(
    observability: WebSocketObservabilityPack(
        eventDeliveryPolicy: EventDeliveryPolicy(
            maxBufferedEventsPerPartition: 1024,
            maxBufferedEventsPerConsumer: 1024,
            overflowPolicy: .dropOldest
        ),
        eventMetricsReporter: DropReporter()
    )
)
```

`.dropNewest` keeps the queued events and discards the arriving one instead.
`EventDeliveryPolicy` and the metrics types are declared in the core
`InnoNetwork` module.

### Observing heartbeat attempts

The 6.1.1 contract emits a `.ping` event before each heartbeat or manual ping
attempt. Pair it with
`.pong` and `.error(.pingTimeout)` to track heartbeat success, timeout, and
approximate round-trip timing in application code.

For pong, event publication is attempted before the snapshotted manager
handler is invoked. The event still uses ordinary bounded overflow and listener
delivery is asynchronous, so the event can be dropped and no listener-versus-
handler execution order is guaranteed.

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
- <doc:TypedMessages>
- <doc:WebSocketProtocolPolicy>
- <doc:WebSocketBackgroundTransition>
- ``WebSocketManager``
- ``WebSocketConfiguration``
- ``WebSocketTask``
