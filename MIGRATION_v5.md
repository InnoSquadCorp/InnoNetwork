# InnoNetwork v5 Migration Guide

This document summarizes the breaking change introduced in `5.0` and the
new runnable integration samples that ship alongside it.

`5.0` is a **major release** with exactly one breaking change: the
`WebSocketEvent.pong` case now carries a `WebSocketPongContext`
associated value, mirroring the 4.1 `.ping(_:)` shape. All other entries
are additive (new examples, smoke test, CI workflow).

Minimum toolchain unchanged: Swift 6.2 / Xcode 26.

---

## 1. `WebSocketEvent.pong` now carries `WebSocketPongContext`

### 1.1 Breaking diff

```diff
 public enum WebSocketEvent: Sendable {
     case ping(WebSocketPingContext)
-    case pong
+    case pong(WebSocketPongContext)
     ...
 }
```

`WebSocketPongContext` is the same value already delivered to
`setOnPongHandler(_:)` in 4.3:

```swift
public struct WebSocketPongContext: Sendable {
    public let attemptNumber: Int
    public let roundTrip: Duration
}
```

Both the event stream and the callback now receive the **identical**
context for a given pong — the library computes `roundTrip` once
(`ContinuousClock.now - pingContext.dispatchedAt`) just before publish,
then delivers that value to both surfaces.

### 1.2 Switch update

**Exhaustive switches** over `WebSocketEvent` must bind or ignore the
new associated value:

```diff
 switch event {
 case .ping(let context):
     pendingPingAt = context.dispatchedAt
-case .pong:
-    metrics.recordRTT(ContinuousClock.now - (pendingPingAt ?? .now))
+case .pong(let context):
+    metrics.recordRTT(context.roundTrip)
+    metrics.correlate(attempt: context.attemptNumber)
 default:
     break
 }
```

**Non-binding patterns** continue to compile unchanged:

```swift
// Still valid in 5.0
if case .pong = event { pongCount += 1 }
```

### 1.3 Picking a surface

Both paths carry the same `WebSocketPongContext`. Choose whichever fits
the call site:

```swift
// Event-stream — natural for code already iterating events.
for await event in await manager.events(for: task) {
    if case .pong(let ctx) = event {
        metrics.recordRTT(ctx.roundTrip)
    }
}

// Callback — natural for metrics wiring that lives outside the main loop.
await manager.setOnPongHandler { _, ctx in
    metrics.recordRTT(ctx.roundTrip)
}
```

---

## 2. New runnable integration samples

None of these are required for migration — they exist to make the
WebSocket / Download / observability surfaces easier to try against real
endpoints. Every sample gates the live path behind
`INNONETWORK_RUN_INTEGRATION=1` so `swift build` in CI stays offline.

### 2.1 `Examples/WebSocketChat`

CLI that connects to a public echo server, streams stdin lines as text
frames, and prints both the echoed messages and pong RTT:

```bash
INNONETWORK_RUN_INTEGRATION=1 swift run WebSocketChat
```

Demonstrates `setOnPongHandler(_:)` and `.pong(_:)` receiving identical
context values.

### 2.2 `Examples/DownloadManager` (executable: `DownloadManagerSample`)

CLI that drives a real HTTPS download with the 4.3 exponential-backoff
surface enabled:

```bash
INNONETWORK_RUN_INTEGRATION=1 swift run DownloadManagerSample
INNONETWORK_RUN_INTEGRATION=1 swift run DownloadManagerSample \
    https://example.com/file.zip /tmp/out.zip
```

The executable is named `DownloadManagerSample` to avoid colliding with
the library's `DownloadManager` class.

### 2.3 `Examples/EventPolicyObserver`

Reference implementations of `EventPipelineMetricsReporting`:

- `LoggerMetricsReporter` — `os.Logger`, subsystem `com.example.event-policy`
- `SignPostMetricsReporter` — `OSSignposter` (Instruments → Points of Interest)
- `CompositeMetricsReporter` — fan-out helper

Wire one (or the composite) into
`WebSocketConfiguration.eventMetricsReporter` /
`DownloadConfiguration.eventMetricsReporter`. The sample has zero
external dependencies; a swift-metrics bridge recipe lives in the
README as a comment-only snippet.

### 2.4 `SmokeTests/InnoNetworkDownloadSmoke`

End-to-end smoke that kicks off a real download, pauses after the first
progress event, verifies `resumeData` is non-nil, resumes, and asserts
the completed file exists with a non-zero size:

```bash
INNONETWORK_RUN_INTEGRATION=1 swift run InnoNetworkDownloadSmoke
```

Without the env flag, the binary prints a skip message and exits 0.

---

## 3. New CI workflow

`.github/workflows/tsan.yml` runs the full test suite under
ThreadSanitizer nightly (18:00 UTC ≈ 03:00 KST) and on manual dispatch.
Expected runtime ≈ 5–10× the default suite; no action required from
consumers.

---

## 4. Why major?

`WebSocketEvent.pong` is a public enum case with a source-level payload
change: every exhaustive switch over `WebSocketEvent` must be updated.
Semantic Versioning treats that as a breaking change even though the
semantic behavior (timing, ordering, attempt correlation) is preserved.
No other public API shape changes in this release.
