# InnoNetwork v4 Migration Guide

This document summarizes breaking changes from the `3.x` line to `4.0`.

`4.0` bundles three long-planned changes into a single major release:

1. **I — `WebSocketCloseCode` is promoted to `public`** and becomes the
   canonical close-code type on all public WebSocket APIs. Apple's
   `URLSessionWebSocketTask.CloseCode` remains as a Foundation-boundary
   adapter type only.
2. **J — Swift 6 language mode** is enabled for every target via
   `swiftLanguageMode(.v6)` in `Package.swift`. Strict concurrency checking is
   always in effect without the explicit `-strict-concurrency=complete` flag.
3. **K — `WebSocketEvent.ping`** is emitted at the start of every heartbeat
   attempt, completing the `.ping → .pong`/`.error(.pingTimeout)` observability
   pair.

Minimum toolchain remains Swift 6.2 / Xcode 26.

---

## 1. WebSocket close-code API (Item I)

### 1.1 `WebSocketManager.disconnect(_:closeCode:)`

```diff
- await manager.disconnect(task, closeCode: .normalClosure)
+ await manager.disconnect(task, closeCode: .normalClosure)
```

The spelling at the call site is identical. The parameter's static type
changed from `URLSessionWebSocketTask.CloseCode` to
[`WebSocketCloseCode`](Sources/InnoNetworkWebSocket/WebSocketCloseCode.swift).
Because case names match, most call sites compile unchanged after a rebuild.

### 1.2 `WebSocketManager.disconnectAll(closeCode:)`

```diff
- await manager.disconnectAll(closeCode: .goingAway)
+ await manager.disconnectAll(closeCode: .goingAway)
```

Same treatment — type changed, spelling preserved.

### 1.3 `WebSocketTask.closeCode`

```diff
- let code: URLSessionWebSocketTask.CloseCode? = await task.closeCode
+ let code: WebSocketCloseCode? = await task.closeCode
```

Pattern matches on shared case names keep working:

```swift
if case .goingAway = await task.closeCode { /* ... */ }
```

### 1.4 New matchable cases

`WebSocketCloseCode` exposes cases that `URLSessionWebSocketTask.CloseCode`
did not:

```swift
switch await task.closeCode {
case .serviceRestart, .tryAgainLater:
    // 1012/1013 — retryable per RFC 6455. Previously unreachable via Apple's
    // enum and required raw-integer comparison.
    await scheduleReconnectWithBackoff()

case .custom(4001):
    // Application-defined close codes (3000–4999) are first-class.
    await handleAppSpecificLogout()

case .normalClosure, .goingAway, .none:
    break

default:
    break
}
```

### 1.5 Removed: `URLSessionWebSocketTask.CloseCode`-based
classifier overload

`WebSocketCloseDisposition.classifyPeerClose(closeCode:reason:)` was
package-internal in `3.x` and is no longer present. The sole entry point is
`classifyPeerClose(_:reason:)` taking `WebSocketCloseCode`. This remains an
in-package symbol, so external consumers are unaffected. If package targets or
tests previously called the overload, convert at the call site:

```diff
- WebSocketCloseDisposition.classifyPeerClose(closeCode: stdlibCode, reason: nil)
+ WebSocketCloseDisposition.classifyPeerClose(
+     WebSocketCloseCode(rawValue: UInt16(stdlibCode.rawValue)),
+     reason: nil
+ )
```

### 1.6 SessionDelegate adapter boundary

`WebSocketSessionDelegate.urlSession(_:webSocketTask:didCloseWith:reason:)`
keeps Apple's close-code type in its signature (required by
`URLSessionWebSocketDelegate`), but converts to `WebSocketCloseCode` before
dispatching to the rest of the library. No call-site change is required
unless you were implementing a custom session delegate outside the library.

---

## 2. Swift 6 language mode (Item J)

`Package.swift` now sets `swiftLanguageMode(.v6)` on every target. Consumers
that embed InnoNetwork via SwiftPM pick this up automatically — the package
itself compiles under Swift 6 rules regardless of the consumer's own language
mode.

### 2.1 CI simplification (optional)

If you previously mirrored the library's CI and passed
`-Xswiftc -strict-concurrency=complete` to `swift build`/`swift test`, you can
drop it:

```diff
- xcrun swift build -Xswiftc -strict-concurrency=complete
+ xcrun swift build
```

The `Package.swift` setting already pins the behavior.

### 2.2 `@unchecked Sendable` removal

All five `@unchecked Sendable` usages in production sources are gone. If your
own code relied on InnoNetwork's previous lenient concurrency posture, audit
for:

- `URLQueryEncoder` is now plain `Sendable`.
- `URLQueryCustomKeyTransform` now carries a `@Sendable` closure. If you
  pass a closure through its `init(_:)`, the closure must be `@Sendable`
  (usually just requires the caller's captures to be Sendable).

---

## 3. `WebSocketEvent.ping` (Item K)

`WebSocketEvent` has a new case:

```swift
public enum WebSocketEvent: Sendable {
    case connected(String?)
    case disconnected(WebSocketError?)
    case message(Data)
    case string(String)
    case ping       // NEW in 4.0
    case pong
    case error(WebSocketError)
}
```

The event is emitted immediately before any heartbeat ping or public
`WebSocketManager.ping(_:)` call. It always precedes the corresponding
`.pong` (on success) or `.error(.pingTimeout)` (on timeout) in the event
stream for the same task.

### 3.1 Exhaustive switches

If you have an exhaustive `switch` over `WebSocketEvent`, the compiler will
point you at the missing case:

```diff
 switch event {
 case .connected:    // ...
 case .disconnected: // ...
 case .message:      // ...
 case .string:       // ...
+case .ping:
+    break
 case .pong:         // ...
 case .error:        // ...
 }
```

### 3.2 Observability use

Pair `.ping` with `.pong` / `.error(.pingTimeout)` to compute success rate
and round-trip latency on the client:

```swift
var pendingPingAt: Date?
for await event in await manager.events(for: task) {
    switch event {
    case .ping:
        pendingPingAt = .now
    case .pong:
        if let started = pendingPingAt {
            metrics.recordPingRTT(.now.timeIntervalSince(started))
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

---

## 4. Verification checklist

After bumping InnoNetwork to `4.0`:

1. `swift build` (or your IDE build) — fix any exhaustive-switch warning on
   `WebSocketEvent` by adding a `.ping` branch.
2. Search for `URLSessionWebSocketTask.CloseCode` in your code:
   ```bash
   rg -n "URLSessionWebSocketTask\\.CloseCode"
   ```
   Outside of Foundation-delegate implementations, each remaining usage is a
   candidate for replacement with `WebSocketCloseCode`.
3. If you switch on `task.closeCode` expecting only Apple's cases, add
   `.serviceRestart` / `.tryAgainLater` / `.custom(_)` arms as appropriate
   for your retry policy.
4. Run your test suite — pattern matches that compiled against the old type
   still work, but any tests asserting raw values through
   `URLSessionWebSocketTask.CloseCode.rawValue` should now go through
   `WebSocketCloseCode.rawValue` (which is `UInt16`, not `Int`).
