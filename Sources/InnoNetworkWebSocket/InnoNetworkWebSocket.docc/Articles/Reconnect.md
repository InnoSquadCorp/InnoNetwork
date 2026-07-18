# Reconnect

Tune ``WebSocketConfiguration`` so reconnect attempts respect server health, network
conditions, and the user's battery.

## Overview

The internal `WebSocketReconnectCoordinator` decides whether a closed connection should reconnect,
and how long to wait before the next attempt. The decision is informed by:

1. The reason the connection closed (``WebSocketCloseDisposition``).
2. The current attempt count vs. the configured cap.
3. The configured backoff curve and optional jitter.

## Disposition-driven decision

`reconnectAction(_:_:)` returns one of:

- `retry` — schedule another attempt after the configured backoff delay.
- `terminal` — stop. The close was something we cannot recover
  from automatically (e.g., HTTP `401`, protocol error).
- `exceeded` — stop. We already used the per-connection budget.

The built-in policy is intentionally narrow: application-defined custom close
codes classify as ``WebSocketCloseDisposition/peerApplicationFailure(_:_:)`` and
do not auto-reconnect. Observe ``WebSocketTask/closeDisposition`` and call
``WebSocketManager/retry(_:)`` when your app owns a retryable custom code.

```swift
var currentTask = await manager.connect(url: socketURL)
var currentEvents = await manager.events(for: currentTask)

while true {
    for await event in currentEvents {
        print(event)
    }

    guard case .peerApplicationFailure(.custom(4001), _) =
        await currentTask.closeDisposition
    else { break }

    await refreshApplicationState()
    guard let retryResult = await manager.retry(currentTask) else { break }
    currentTask = retryResult.task
    currentEvents = retryResult.events
}
```

An explicit retry is a new logical task, not another state transition on the
terminal source. It is accepted once for a terminal source and only by the
manager that owns that source. The call returns `nil` for a nonterminal,
already-claimed, foreign-manager, or post-shutdown task. Its bounded event
stream is registered before the replacement transport resumes. If shutdown
begins after admission, the returned task may already be terminal with the
manager-shutdown connection error, which remains observable on that stream.

Use handshake adapters when reconnect attempts need fresh auth headers:

```swift
let configuration = WebSocketConfiguration.advanced(
    connection: WebSocketConnectionPack(
        handshakeRequestAdapters: [
            WebSocketHandshakeRequestAdapter { request in
                var request = request
                request.setValue("Bearer \(await tokenStore.currentAccessToken())",
                                 forHTTPHeaderField: "Authorization")
                return request
            }
        ]
    )
)
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

When a reconnect budget is exhausted, observers receive exactly one public
`.error(.maxReconnectAttemptsExceeded)` or
`.error(.reconnectWindowExceeded)` terminal outcome. The coordinator's
internal `.exceeded` decision is not a public event, and no synthetic
`.disconnected` event precedes the authoritative error.

## When auto-reconnect is wrong

Disable auto-reconnect when:

- The user explicitly closed the socket (already handled — manual disconnect bypasses the
  coordinator).
- The app is being backgrounded without push wakeups configured. Reconnects in the
  background can drain battery and never deliver messages anyway.
- Authentication or authorization has failed (``WebSocketCloseDisposition/handshakeUnauthorized(_:)``
  or ``WebSocketCloseDisposition/handshakeForbidden(_:)``). Refresh the credential or permission,
  then reconnect explicitly or configure
  ``WebSocketHandshakeRequestAdapter`` so the next attempt builds fresh headers.

```swift
let configuration = WebSocketConfiguration.advanced(
    reconnect: WebSocketReconnectPack(
        maxAttempts: 0  // app drives reconnect manually
    )
)
```

## Task identity and listener retention

| Flow | Public task and `id` | Transport generation | Task-scoped consumers |
| --- | --- | --- | --- |
| Automatic reconnect | Preserved | A fresh `URLSessionWebSocketTask` for each attempt | Retained |
| Explicit ``WebSocketManager/retry(_:)`` | Fresh task with a new UUID-backed `id` | Fresh | Consume the result's pre-registered stream; add any additional listeners to the returned task |

Listeners and streams attached through ``WebSocketManager/events(for:)``
survive automatic reconnect attempts because the manager retains the logical
task partition while replacing its transport. Explicit retry permanently
retires the source partition; its consumers finish and never migrate to the
replacement task. ``WebSocketRetryResult/events`` is attached to the fresh
partition before its transport can produce events.

## Related

- ``WebSocketConfiguration``
- ``WebSocketCloseDisposition``
- <doc:CloseCodes>
