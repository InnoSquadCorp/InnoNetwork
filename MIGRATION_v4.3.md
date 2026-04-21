# InnoNetwork v4.3 Migration Guide

This document summarizes call-site changes between `4.2` and `4.3`.

`4.3` is a minor release. The only breaking change is additive on an
existing enum case: `WebSocketEvent.pong` gains a `WebSocketPongContext`
associated value. Everything else is strictly opt-in or test-only.

Minimum toolchain unchanged: Swift 6.2 / Xcode 26.

---

## 1. `WebSocketEvent.pong` associated value

### 1.1 Exhaustive switches

```diff
 switch event {
 case .connected:                       break
 case .disconnected:                    break
 case .message:                         break
 case .string:                          break
 case .ping:                            break
- case .pong:
+ case .pong(_):
     break
 case .error:                           break
 }
```

Bind the context if you want the attempt number or library-computed RTT:

```swift
case .pong(let context):
    metrics.recordPingRTT(context.roundTrip)
    metrics.correlate(attempt: context.attemptNumber)
```

Partial pattern matches that did not bind a value keep compiling
unchanged:

```swift
if case .pong = event { /* still valid in 4.3 */ }
```

### 1.2 Using `WebSocketPongContext` for RTT

Prior to 4.3, consumers typically held the `.ping` dispatch timestamp
themselves:

```swift
// 4.2
var pendingPingAt: ContinuousClock.Instant?
for await event in await manager.events(for: task) {
    switch event {
    case .ping(let context):
        pendingPingAt = context.dispatchedAt
    case .pong:
        if let started = pendingPingAt {
            metrics.recordPingRTT(ContinuousClock.now - started)
            pendingPingAt = nil
        }
    default:
        break
    }
}
```

The library now delivers RTT directly:

```swift
// 4.3
for await event in await manager.events(for: task) {
    switch event {
    case .pong(let context):
        metrics.recordPingRTT(context.roundTrip)
    case .error(.pingTimeout):
        metrics.recordPingTimeout()
    default:
        break
    }
}
```

`WebSocketPongContext.attemptNumber` matches the
`WebSocketPingContext.attemptNumber` of the paired ping. The library
computes `roundTrip` as
`ContinuousClock.now - pingContext.dispatchedAt` at the moment the
`.pong(_:)` event is published, so it captures library-internal
dispatch but excludes consumer-side scheduler jitter.

---

## 2. Opt-in exponential backoff for Download retries

`DownloadConfiguration` gains three new fields:

- `exponentialBackoff: Bool` (default `false`)
- `retryJitterRatio: Double` (default `0.2`, `0.0...1.0` clamped)
- `maxRetryDelay: TimeInterval` (default `60s`, `<= 0` disables the cap)

**No behavior change on upgrade** unless you explicitly enable
`exponentialBackoff`. The existing fixed `retryDelay` path is preserved.

### 2.1 Enabling exponential backoff

```swift
let configuration = DownloadConfiguration.advanced {
    $0.exponentialBackoff = true
    $0.retryDelay = 1.0         // base delay
    $0.retryJitterRatio = 0.2   // ±20% jitter
    $0.maxRetryDelay = 60       // cap at 60 seconds
}
```

With the above settings, retries observe delays close to `1s`, `2s`,
`4s`, `8s`, ... capped at `60s`. Set `maxRetryDelay` to `0` (or any
negative value) to disable the cap and let the backoff grow unbounded.

### 2.2 Leaving default behavior

If your consumer expects the current fixed-delay behavior, no change is
required. `exponentialBackoff` defaults to `false` so
`DownloadConfiguration(retryDelay: 1.0)` continues to retry every
`1s` exactly like 4.2.

The `5.0` major release is the earliest candidate for flipping the
default to `true`. Any such flip will ship with its own migration note.

---

## 3. Test infrastructure improvements (no consumer action required)

4.3 completes the Download-module migration to the
`StubDownloadURLSession` harness introduced in 4.2. The
`InMemoryDownloadTaskStore` helper is now shared across all Download
test suites. These are internal changes — library consumers observe no
difference.

---

## 4. Verification checklist

After bumping InnoNetwork to `4.3`:

1. `swift build` — the compiler points at any exhaustive `switch` on
   `WebSocketEvent` that still has `case .pong:`. Apply §1.1.
2. Grep for `case .pong` in your codebase to find unannotated patterns.
3. Consider migrating your RTT instrumentation to
   `.pong(let context) { context.roundTrip }` per §1.2.
4. If you want Download retries to apply exponential backoff, opt in per
   §2.1 and run your retry-sensitive test suites.
