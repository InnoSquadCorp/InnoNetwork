# ``InnoNetworkWebSocket``

Connection-oriented realtime flows with reconnect-aware lifecycle handling, heartbeat monitoring, and explicit WebSocket event delivery.

## Overview

`InnoNetworkWebSocket` wraps `URLSessionWebSocketTask` with a state model that is easier to reason about in production clients.

Use this module when you need:

- reconnect-aware connection management
- heartbeat and pong timeout handling, surfaced as paired ``WebSocketEvent/ping``/``WebSocketEvent/pong`` events
- listener retention across reconnect attempts
- manual disconnect semantics that stay visible to the caller

Reconnect decisions are driven by handshake and close outcomes, so the public manager can distinguish retryable failures from terminal ones without forcing application code to rebuild that policy every time.

## Topics

### Essentials

- ``WebSocketManager``
- ``WebSocketConfiguration``
- ``WebSocketTask``
- ``WebSocketState``

### Realtime Flows

- ``WebSocketManager``
- ``WebSocketConfiguration``
- ``WebSocketTask``
