# InnoNetwork v4.1 Migration Guide

This document summarizes call-site changes between `4.0` and `4.1`.

`4.1` is a minor release. All changes are additive except one:
`WebSocketEvent.ping` gains a `WebSocketPingContext` associated value.
Exhaustive switches that used `case .ping:` must update the pattern — the
case name itself did not change.

Minimum toolchain unchanged: Swift 6.2 / Xcode 26.

---

## 1. `WebSocketEvent.ping` associated value

### 1.1 Exhaustive switches

```diff
 switch event {
 case .connected: break
 case .disconnected: break
 case .message: break
 case .string: break
- case .ping:
+ case .ping(_):
     break
 case .pong: break
 case .error: break
 }
```

If you want the context data, bind it directly:

```swift
case .ping(let context):
    metrics.recordPingAttempt(context.attemptNumber)
    pendingPingStart = context.dispatchedAt
```

Partial pattern matches that did not bind a value keep compiling without
edits:

```swift
if case .ping = event { /* still valid in 4.1 */ }
```

### 1.2 Using `WebSocketPingContext` for RTT

Replace any client-side timestamping with the context the library already
captures:

```diff
-var pendingPingAt: Date?
+var pendingPingAt: ContinuousClock.Instant?
 for await event in await manager.events(for: task) {
     switch event {
-    case .ping:
-        pendingPingAt = .now
+    case .ping(let context):
+        pendingPingAt = context.dispatchedAt
     case .pong:
         if let started = pendingPingAt {
-            metrics.recordPingRTT(.now.timeIntervalSince(started))
+            metrics.recordPingRTT(ContinuousClock.now - started)
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

`ContinuousClock.now - started` now returns `Duration`. If your metrics API
already accepts `Duration`, you can pass that value through directly as shown
above.

If you still record RTT as `TimeInterval`, convert the duration explicitly:

```swift
let elapsed = ContinuousClock.now - started
let seconds = Double(elapsed.components.seconds) +
    Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
metrics.recordPingRTT(seconds)
```

`WebSocketPingContext.attemptNumber` starts at 1 on each connection and
resets whenever a new connection becomes ready (or `task.reset()` is called),
so it also serves as a stable correlation ID between the `.ping(_:)` and the
following `.pong` / `.error(.pingTimeout)` events from the same cycle.

---

## 2. `WebSocketCloseDisposition` public + `WebSocketTask.closeDisposition`

### 2.1 Observing close reason

After a task transitions to `.disconnected` or `.failed`, the new
`closeDisposition` property surfaces the library's internal classification
without forcing consumers to re-map raw close codes:

```swift
switch await task.closeDisposition {
case .manual:                         hideReconnectBanner()
case .peerRetryable, .handshakeServerUnavailable, .handshakeTransientNetwork:
    showReconnectingBanner()
case .peerTerminal, .handshakeUnauthorized, .handshakeForbidden,
     .handshakeTerminalHTTP, .handshakeTimeout:
    showTerminalErrorBanner()
case .transportFailure:               showRetryingBanner()
case .peerNormal:                     break
case .none:                           break        // task has not closed yet
@unknown default:                     break        // forward-compat
}
```

Exhaustive switches over `WebSocketCloseDisposition` should use
`@unknown default` — new cases may be added in future minor releases.

### 2.2 `disposition.shouldReconnect`

If you only need to know whether the library is about to retry, use the
convenience flag:

```swift
if await task.closeDisposition?.shouldReconnect == true {
    analytics.incrementReconnectAttempts()
}
```

### 2.3 Classifier factories stay package-internal

The `classifyPeerClose(_:reason:)` and `classifyHandshake(statusCode:error:)`
static methods remain package-scoped — the library owns the policy. If you
have a concrete need to customize classification, please open an issue.

---

## 3. Verification checklist

After bumping InnoNetwork to `4.1`:

1. `swift build` — fix any `ping` case-pattern compile error per §1.1.
2. Grep your codebase for `case .ping` to find any remaining unannotated
   patterns.
3. Consider surfacing `task.closeDisposition` to users if your UX
   differentiates between retryable / terminal close reasons (§2.1).
4. Run your test suite to confirm the RTT timestamp migration (§1.2) still
   produces the expected latency distribution.
