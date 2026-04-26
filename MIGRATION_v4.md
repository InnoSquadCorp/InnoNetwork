# InnoNetwork v4 Migration Guide

This document summarizes breaking changes from the `3.x` line to `4.0`.

`4.0` bundles the long-planned WebSocket / Swift 6 work with a
production-readiness pass on the request pipeline:

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
4. **L — `NetworkError.timeout(reason:)`** is a new exhaustive case so
   transport timeouts can be branched on without unwrapping NSError.
5. **M — `RequestPayload.fileURL(_:contentType:)`** lets multi-hundred-MB
   bodies stream from disk via `URLSession.upload(for:fromFile:)`.
6. **N — `DefaultNetworkClient` is now a `final class`** (was `actor`) so
   concurrent requests dispatch without an actor-hop. The public API
   surface is byte-for-byte unchanged.

Items L–N are source-breaking on exhaustive switches; everything else
in this release is additive.

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

## 4. `NetworkError.timeout(reason:)` (Item L)

```diff
 public enum NetworkError: Error, Sendable {
     case invalidBaseURL(String)
     case invalidRequestConfiguration(String)
     ...
     case undefined
     case cancelled
+    case timeout(reason: TimeoutReason)
 }

+public enum TimeoutReason: Sendable, Equatable {
+    case requestTimeout
+    case resourceTimeout
+    case connectionTimeout
+}
```

`URLError.timedOut`, `URLError.cannotConnectToHost`, and
`URLError.cannotFindHost` previously folded into `.underlying`. The new
case routes them to a first-class branch:

```diff
 switch error {
 case .statusCode(let response): ...
 case .underlying(let error, _): ...
+case .timeout(.requestTimeout):
+    showSlowNetworkBanner()
+case .timeout(.connectionTimeout):
+    showOfflineBanner()
+case .timeout(.resourceTimeout):
+    showSlowNetworkBanner()
 default: ...
 }
```

`ExponentialBackoffRetryPolicy` retries `.timeout(_)` by default, so
existing retry behavior is unchanged — the case is purely an
observability and UX improvement.

---

## 5. `RequestPayload.fileURL(_:contentType:)` (Item M)

```diff
 public enum RequestPayload: Sendable {
     case none
     case data(Data)
     case queryItems([URLQueryItem])
+    case fileURL(URL, contentType: String)
 }
```

Used together with the new `MultipartFormData.writeEncodedData(to:)`
helper and `URLSessionProtocol.upload(for:fromFile:context:)`, the case
lets bodies that don't fit comfortably in memory stream from disk:

```swift
var formData = MultipartFormData()
try await formData.appendFile(at: videoURL, name: "video", mimeType: "video/mp4")

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("upload-\(UUID().uuidString).bin")
try formData.writeEncodedData(to: temp)
defer { try? FileManager.default.removeItem(at: temp) }

// Wire the temp URL into a SingleRequestExecutable returning
// .fileURL(temp, contentType: formData.contentTypeHeader)
let response = try await client.perform(executable: streamingExecutable)
```

Update exhaustive `switch` blocks over `RequestPayload`:

```diff
 switch payload {
 case .none: ...
 case .data(let data): ...
 case .queryItems(let items): ...
+case .fileURL(let url, let contentType): ...
 }
```

The synchronous `MultipartFormData.appendFile(at:)` is now
`@available(*, deprecated)`. It still works (loads the file into
memory) but the async overload combined with `writeEncodedData(to:)`
is the path forward. The synchronous overload is scheduled for removal
in `5.0`.

---

## 6. `DefaultNetworkClient` is a `final class` (Item N)

The public API is byte-for-byte unchanged:

```swift
let client = DefaultNetworkClient(
    configuration: .safeDefaults(baseURL: baseURL)
)
let user = try await client.request(GetUser())
```

Code that explicitly passed `DefaultNetworkClient` through actor
boundaries assuming actor isolation no longer holds. The previous
`actor` implementation already released isolation on every `await
session.data(...)`, so two parallel callers were already executing in
parallel through the public API. The conversion makes that explicit.

`Sendable` conformance is checked statically by Swift 6 strict mode.

---

## 7. `RetryPolicy.shouldRetry` contextual overload

The legacy boolean overload still exists, but `RetryPolicy` now ships a
contextual overload returning ``RetryDecision``:

```swift
public protocol RetryPolicy: Sendable {
    // unchanged...
    func shouldRetry(error: NetworkError, retryIndex: Int) -> Bool
    // NEW:
    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision
}
```

A protocol-level default extension wraps the boolean overload so every
existing policy keeps compiling. Override the contextual overload to
honor `Retry-After` headers, branch on HTTP method, or inspect response
bodies:

```swift
struct IdempotentOnlyRetryPolicy: RetryPolicy {
    let maxRetries = 3
    let maxTotalRetries = 3
    let retryDelay: TimeInterval = 1

    func shouldRetry(error: NetworkError, retryIndex: Int) -> Bool {
        true // legacy fallback
    }

    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision {
        guard retryIndex < maxRetries else { return .noRetry }
        let method = request?.httpMethod ?? "GET"
        guard ["GET", "HEAD", "PUT", "DELETE"].contains(method) else { return .noRetry }
        return .retry
    }
}
```

`ExponentialBackoffRetryPolicy` already implements the contextual
overload to honor `Retry-After` on `429` and `503` responses
(delta-seconds and HTTP-date). The retry coordinator clamps the
returned wait between the policy's own jittered delay and 4× that
delay to defend against adversarial servers.

The legacy boolean overload is scheduled for removal in `5.0`.

---

## 8. Additive (no migration needed)

These features ship in `4.0` but require no changes to existing code:

- **Session-level interceptors**:
  ``NetworkConfiguration/requestInterceptors`` and
  ``responseInterceptors``. See the
  [Interceptors](Sources/InnoNetwork/InnoNetwork.docc/Articles/Interceptors.md)
  DocC article for the onion-ordering rules.
- **`acceptableStatusCodes`**:
  ``NetworkConfiguration/acceptableStatusCodes`` lets `304`, `205`, or
  custom status codes flow through to consumer code.
- **`cancelAll()`**:
  ``DefaultNetworkClient/cancelAll()`` drains every in-flight request
  at sign-out / screen disposal.
- **`stream(_:)`**:
  ``DefaultNetworkClient/stream(_:)`` plus ``StreamingAPIDefinition``
  and ``ServerSentEventDecoder`` cover SSE / NDJSON / chunked log
  feeds.
- **Ed25519 SPKI**: `TrustEvaluator.spkiData(...)` recognizes
  `keyType == "ed25519"` (case-insensitive) or the OID string
  `"1.3.101.112"` (RFC 8410).
- **UTType-backed multipart MIME**: 13 legacy mappings preserved;
  modern formats (`webp`, `avif`, `heif`, `m4a`, `webm`) now resolve
  through UTType.

---

## 9. Verification checklist

After bumping InnoNetwork to `4.0`:

1. `swift build` (or your IDE build) — fix any exhaustive-switch
   warnings on `WebSocketEvent`, `NetworkError`, and `RequestPayload`
   by adding the new cases.
2. Search for `URLSessionWebSocketTask.CloseCode` in your code:
   ```bash
   rg -n "URLSessionWebSocketTask\\.CloseCode"
   ```
   Outside of Foundation-delegate implementations, each remaining usage
   is a candidate for replacement with `WebSocketCloseCode`.
3. If you switch on `task.closeCode` expecting only Apple's cases, add
   `.serviceRestart` / `.tryAgainLater` / `.custom(_)` arms as
   appropriate for your retry policy.
4. Search for callers that branched on `URLError.timedOut` inside a
   `NetworkError.underlying` arm — the new `.timeout(reason:)` case is
   the cleaner branch.
5. If you implement `RetryPolicy`, consider overriding the contextual
   overload to honor `Retry-After` and per-method rules.
6. If you implement `URLSessionProtocol`, the new
   `bytes(for:context:)` and `upload(for:fromFile:context:)`
   requirements default to throwing
   `NetworkError.invalidRequestConfiguration` — no change needed unless
   your tests now exercise streaming.
7. Run your test suite — pattern matches that compiled against the
   `WebSocketCloseCode` change still work, but any tests asserting raw
   values through `URLSessionWebSocketTask.CloseCode.rawValue` should
   now go through `WebSocketCloseCode.rawValue` (which is `UInt16`,
   not `Int`).
