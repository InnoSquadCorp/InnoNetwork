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

The built-in policy is intentionally narrow: application-defined custom close
codes classify as ``WebSocketCloseDisposition/peerApplicationFailure(_:_:)`` and
do not auto-reconnect. Observe ``WebSocketTask/closeDisposition`` and call
``WebSocketManager/retry(_:)`` when your app owns a retryable custom code.

```swift
let task = await manager.connect(url: socketURL)
for await event in await manager.events(for: task) {
    guard case .disconnected = event else { continue }
    guard case .peerApplicationFailure(.custom(4001), _) = await task.closeDisposition else {
        continue
    }
    await refreshApplicationState()
    await manager.retry(task)
}
```

Use handshake adapters when reconnect attempts need fresh auth headers:

```swift
let configuration = WebSocketConfiguration.advanced { builder in
    builder.handshakeRequestAdapters = [
        WebSocketHandshakeRequestAdapter { request in
            var request = request
            request.setValue("Bearer \(await tokenStore.currentAccessToken())",
                             forHTTPHeaderField: "Authorization")
            return request
        }
    ]
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
- Authentication has failed (``WebSocketCloseDisposition/handshakeUnauthorized``).
  Refresh the token, then reconnect explicitly or configure
  ``WebSocketHandshakeRequestAdapter`` so the next attempt builds fresh headers.

```swift
let configuration = WebSocketConfiguration.advanced { builder in
    builder.maxReconnectAttempts = 0  // app drives reconnect manually
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
