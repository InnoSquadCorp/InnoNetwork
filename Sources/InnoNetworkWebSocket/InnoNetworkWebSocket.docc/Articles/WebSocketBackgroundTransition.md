# WebSocket background transition

Survive iOS foreground / background / terminated transitions without
leaking sockets, ping timers, or stale lifecycle generations.

## What the OS does

`URLSessionWebSocketTask` runs on a regular `URLSession`, not a
background-eligible session. iOS gives the app a short tail (typically
under 30 seconds) after the user backgrounds the process before
suspending the runloop. While suspended:

- ping/pong heartbeats stop being delivered
- the socket stays open from the OS's point of view but is unobserved
  application-side
- carrier NAT and Wi-Fi access points routinely drop the connection
  silently within minutes

When the app resumes, the manager cannot trust the connection's state
without re-handshaking. ``WebSocketLifecycleReducer`` models this
explicitly through generation counters and the
``WebSocketState/reconnecting`` transition.

## Recommended foreground-only policy

For most apps, treat the WebSocket as foreground-only:

1. Subscribe to `UIScene.willDeactivateNotification` (or the AppKit
   equivalent) and call ``WebSocketManager/disconnect(_:)`` when the
   scene leaves the foreground.
2. Subscribe to `UIScene.didActivateNotification` and call
   ``WebSocketManager/connect(url:subprotocols:)`` again on resume.
3. Disable the heartbeat (``WebSocketConfiguration/heartbeatInterval``
   = `0`) for backgrounded scenes — the OS does not deliver application
   pings reliably while suspended, so a heartbeat schedule will fire a
   spurious `.error(.pingTimeout)` immediately on resume.

This keeps the lifecycle deterministic: every foreground entry begins
a new generation, and the reducer's stale-callback gate drops any
events that were enqueued for an earlier generation.

## When background-eligible is required

Streaming use cases that must keep the connection alive while
backgrounded (VoIP signaling, push fallback) need a different OS
mechanism — push-triggered wake-ups, VoIP background mode, or a
companion network extension. The manager itself does not bridge to
those modes; the application coordinates them and re-uses the manager
once the OS hands the process a foreground execution window again.

## Generation invalidation on terminated

When the OS terminates the app, all in-flight generations are
discarded. On the next launch:

- The manager is re-instantiated; there is no persisted
  ``WebSocketState``.
- Any callbacks scheduled before termination (heartbeat timer, receive
  loop) are gone with the process.
- The first ``WebSocketManager/connect(url:subprotocols:)`` after
  launch starts at generation 1 again.

The reducer's invariant is that an event tagged with generation `N`
can only mutate state that is also at generation `N`; the
``WebSocketReceiveLoop`` and heartbeat coordinators carry the
generation they were started with, so a callback fired across a
process restart cannot mutate a fresh generation by accident. See
``WebSocketLifecycleReducer`` for the full transition table.

## Reconnect policy on resume

Use ``WebSocketReconnectCoordinator`` defaults rather than rolling a
custom retry loop:

- Bounded exponential backoff with jitter.
- Distinguish handshake-time failures (HTTP 401 / 403 / 404 on the
  upgrade request) from post-handshake transport closures —
  authentication failures should bubble up to the caller for token
  refresh, not feed the reconnect loop indefinitely.
- Cap total retry attempts. A foreground app that cannot reconnect
  within a small handful of attempts has either lost connectivity or
  has a configuration error; surface the failure to the user instead
  of looping forever.

See <doc:Reconnect> for the policy details and <doc:CloseCodes> for
which close codes the manager treats as reconnect-eligible.
