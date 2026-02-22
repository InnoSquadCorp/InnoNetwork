# InnoNetwork v2 Migration Guide

This document summarizes breaking changes from v1 to v2.

## 1. RetryPolicy Semantics

`RetryPolicy` now uses retry count semantics explicitly.

- Old: `shouldRetry(error:attempt:)`
- New: `shouldRetry(error:retryIndex:)`
- `retryIndex` is 0-based and represents retry executions.
- `maxRetries` now strictly means retry count.
- Total request attempts are always `1 + maxRetries` (unless cancelled/failed earlier).

Example:

```swift
struct RetryOncePolicy: RetryPolicy {
    let maxRetries: Int = 1
    let retryDelay: TimeInterval = 0.5

    func shouldRetry(error: NetworkError, retryIndex: Int) -> Bool {
        retryIndex < maxRetries
    }
}
```

## 2. Deprecated Callback Properties Removed

Deprecated property APIs are removed from v2.

### DownloadManager

- Removed:
  - `onProgress`
  - `onStateChanged`
  - `onCompleted`
  - `onFailed`
- Use:
  - `setOnProgressHandler(_:)`
  - `setOnStateChangedHandler(_:)`
  - `setOnCompletedHandler(_:)`
  - `setOnFailedHandler(_:)`
  - `events(for:)`
  - `addEventListener(for:listener:)` / `removeEventListener(_:)`

### WebSocketManager

- Removed:
  - `onConnected`
  - `onDisconnected`
  - `onMessage`
  - `onString`
  - `onError`
- Use:
  - `setOnConnectedHandler(_:)`
  - `setOnDisconnectedHandler(_:)`
  - `setOnMessageHandler(_:)`
  - `setOnStringHandler(_:)`
  - `setOnErrorHandler(_:)`
  - `events(for:)`
  - `addEventListener(for:listener:)` / `removeEventListener(_:)`

## 3. NetworkConfiguration Additions

`NetworkConfiguration` now supports trust policy and lifecycle events.

- Added `trustPolicy: TrustPolicy`
- Added `eventObservers: [any NetworkEventObserving]`

Example:

```swift
let config = NetworkConfiguration(
    baseURL: URL(string: "https://api.example.com")!,
    trustPolicy: .publicKeyPinning(
        PublicKeyPinningPolicy(
            pinsByHost: ["api.example.com": ["sha256/PRIMARY_PIN", "sha256/BACKUP_PIN"]]
        )
    ),
    eventObservers: [OSLogNetworkEventObserver()]
)
```

## 4. URLSessionProtocol Context Overload

`URLSessionProtocol` now has context-based overload for trust/metrics/event correlation.

- Added: `data(for:context:)`
- `NetworkRequestContext` carries:
  - `requestID`
  - `retryIndex`
  - `metricsReporter`
  - `trustPolicy`
  - `eventObservers`

Existing custom session mocks should implement `data(for:context:)` for full behavior.

## 5. WebSocket Runtime Configuration Changes

`WebSocketConfiguration` heartbeat/reconnect fields changed:

- Added:
  - `heartbeatInterval`
  - `pongTimeout`
  - `maxMissedPongs`
  - `reconnectJitterRatio`
- Removed/renamed old ping-specific fields.

## 6. Error Model Is Sendable-Safe

Raw `Error` payloads are removed from public error enums.

- `NetworkError.objectMapping` now uses `SendableUnderlyingError`
- `NetworkError.underlying` now uses `SendableUnderlyingError`
- Added `NetworkError.trustEvaluationFailed(TrustFailureReason)`

Download/WebSocket errors also use `SendableUnderlyingError` instead of raw `Error`.

## 7. Download Restore Behavior Tightened

Background task restore no longer falls back to URL-only matching.

- v2 restore uses task-id (`taskDescription`) and persisted metadata only.
- Orphaned tasks are ignored unless tracked metadata exists.

## 8. MultipartFormData API Usage

Use mutating `append` APIs in v2.

```swift
var form = MultipartFormData()
form.append("My title", name: "title")
form.append(imageData, name: "file", fileName: "image.jpg", mimeType: "image/jpeg")
```

## 9. Concurrency Policy

- Production sources no longer use `@unchecked Sendable`.
- If you maintain downstream extensions, prefer actor isolation or immutable sendable structures over unchecked conformance.
