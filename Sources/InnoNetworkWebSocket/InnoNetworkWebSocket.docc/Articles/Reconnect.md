# Reconnect

Tune ``WebSocketConfiguration`` so reconnect attempts respect server health, network
conditions, and the user's battery.

## Overview

``WebSocketReconnectCoordinator`` decides whether a closed connection should reconnect,
and how long to wait before the next attempt. The decision is informed by:

1. The reason the connection closed (``WebSocketCloseDisposition``).
2. The current attempt count vs. the configured cap.
3. The configured backoff curve and optional jitter.

## Disposition-driven decision

`reconnectAction(_:_:)` returns one of:

- ``WebSocketReconnectAction/retry(delay:)`` — schedule another attempt after the delay.
- ``WebSocketReconnectAction/terminal`` — stop. The close was something we cannot recover
  from automatically (e.g., HTTP `401`, protocol error).
- ``WebSocketReconnectAction/exceeded`` — stop. We already used the per-connection budget.

Override or extend the policy through `WebSocketConfiguration.AdvancedBuilder` if you have
application-specific retryable codes:

```swift
let configuration = WebSocketConfiguration.advanced { builder in
    builder.maxReconnectAttempts = 5
    builder.reconnectDelay = .seconds(1)
    builder.maxReconnectDelay = .seconds(30)
    builder.reconnectJitterRatio = 0.2
    builder.shouldReconnect = { disposition in
        switch disposition {
        case .custom(let code) where code == 4001: return true  // app-defined "service paused"
        default: return disposition.shouldReconnect
        }
    }
}
```

## Backoff curve

Default backoff is exponential with optional jitter:

```
delay(attempt) = min(maxReconnectDelay,
                     reconnectDelay × 2^(attempt - 1))
delay        ±= delay × reconnectJitterRatio  (uniform)
```

Jitter prevents synchronised reconnect storms — when a server restarts and 10 000
clients all try at the same moment with a fixed delay, the next failure is a thundering
herd. A small jitter (10–20 %) is enough to spread the load.

## Attempt accounting

`WebSocketTask` tracks two counters:

- ``WebSocketTask/attemptedReconnectCount`` — every reconnect attempt, including ones that
  exceeded the cap before the coordinator yielded `.exceeded`. Useful for "did we ever
  even try" alarms.
- ``WebSocketTask/successfulReconnectCount`` — attempts that re-entered the `connected`
  state. Useful for SLO dashboards.

The legacy property ``WebSocketTask/reconnectCount`` aliases `attemptedReconnectCount` for
source compatibility.

## When auto-reconnect is wrong

Disable auto-reconnect when:

- The user explicitly closed the socket (already handled — manual disconnect bypasses the
  coordinator).
- The app is being backgrounded without push wakeups configured. Reconnects in the
  background can drain battery and never deliver messages anyway.
- Authentication has failed (``WebSocketCloseDisposition/handshakeUnauthorized``). Refresh
  the token, then reconnect explicitly.

```swift
let configuration = WebSocketConfiguration.advanced { builder in
    builder.autoReconnect = false  // app drives reconnect manually
}
```

## Listener retention across attempts

Listeners attached via ``WebSocketManager/events(for:)`` survive reconnect attempts. The
underlying `URLSessionWebSocketTask` is replaced each attempt, but the public
``WebSocketTask`` keeps the same `id` and the manager fans events to the same set of
subscribers. Application code does not need to reattach observers on each reconnect.

## Related

- ``WebSocketConfiguration``
- ``WebSocketCloseDisposition``
- <doc:CloseCodes>
