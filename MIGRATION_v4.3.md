# InnoNetwork v4.3 Migration Guide

This document summarizes observable behavior and optional adoption notes
between `4.2` and `4.3`.

`4.3` is a source-compatible minor release. Existing `WebSocketEvent`
switches remain valid; the new pong RTT surface is additive.

Minimum toolchain unchanged: Swift 6.2 / Xcode 26.

---

## 1. Optional pong RTT observation

### 1.1 `setOnPongHandler(_:)`

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
await manager.setOnPongHandler { _, context in
    metrics.recordPingRTT(context.roundTrip)
    metrics.correlate(attempt: context.attemptNumber)
}
```

`WebSocketPongContext.attemptNumber` matches the
`WebSocketPingContext.attemptNumber` of the paired ping. The library
computes `roundTrip` as
`ContinuousClock.now - pingContext.dispatchedAt` just before the paired
`.pong` event is published, so it captures library-internal
dispatch but excludes consumer-side scheduler jitter.

### 1.2 Existing `.pong` event handling

No call-site update is required for existing event listeners:

```swift
switch event {
case .ping(let context):
    pendingPingAt = context.dispatchedAt
case .pong:
    if let started = pendingPingAt {
        metrics.recordPingRTT(ContinuousClock.now - started)
    }
default:
    break
}
```

> **Forward pointer (5.0).** `WebSocketEvent.pong` gains a
> `WebSocketPongContext` payload in 5.0 — the same value that
> `setOnPongHandler(_:)` already delivers in 4.3. Pattern matches like
> `case .pong:` remain valid; code that constructs or forwards `.pong`
> as a value, or binds the payload to consume RTT metadata, must account
> for `WebSocketPongContext`. See
> [`MIGRATION_v5.md`](MIGRATION_v5.md) for the full diff.

---

## 2. Opt-in exponential backoff for Download retries

`DownloadConfiguration` gains three new fields:

- `exponentialBackoff: Bool` (default `false`)
- `retryJitterRatio: Double` (default `0.2`, `0.0...1.0` clamped)
- `maxRetryDelay: TimeInterval` (default `60s`, `<= 0` disables the
  user-facing cap and falls back to the runtime's maximum safe sleep
  duration)

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
negative value) to remove the user-facing cap; internally the delay is
still clamped to the largest runtime-safe sleep duration.

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

1. `swift build` — no `.pong` event migration should be required for 4.3.
2. If you want library-computed RTT metadata, adopt
   `setOnPongHandler(_:)` per §1.1.
3. If you want Download retries to apply exponential backoff, opt in per
   §2.1 and run your retry-sensitive test suites.
