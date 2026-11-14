# Offline-Aware Request Handling

Decide whether a request should fail fast, queue, or proceed
optimistically when the device cannot reach the network. Covers
the existing ``NetworkMonitoring`` protocol, the
`NetworkSnapshot` shape, and recipes for building offline-aware
``RequestInterceptor`` and ``RetryPolicy`` integrations.

## Overview

Mobile networks are flaky by design — cellular handover, captive
portals, transient TLS handshake stalls, train tunnels — and
issuing every request optimistically wastes battery and surfaces
slow timeouts to the user instead of immediate, actionable
errors. InnoNetwork ships ``NetworkMonitor`` (an `NWPathMonitor`
wrapper) and the ``NetworkMonitoring`` protocol so consumers can
inspect or wait on the path state, but the *policy* — fail fast,
queue, retry-on-recovery — stays in the consumer's hands.

This article documents the three patterns most apps need.

## Pattern A — Inspect-and-skip

For one-off background work where a missing network is a
business-acceptable outcome (telemetry flush, prefetch warm-up):

```swift
guard
    let snapshot = await monitor.currentSnapshot(),
    snapshot.status == .satisfied
else { return }

try await client.request(prefetchEndpoint)
```

This avoids issuing a request that will time out 30 seconds later
on a known-unsatisfied path. It does not retry on recovery; the
caller is expected to schedule the next attempt.

## Pattern B — Fail-fast `RequestInterceptor`

For interactive flows where queuing is wrong (the user is staring
at a spinner) but optimistic dispatch is wasteful, wrap the check
in a ``RequestInterceptor``:

```swift
struct RequireOnlineInterceptor: RequestInterceptor {
    let monitor: any NetworkMonitoring

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        let snapshot = await monitor.currentSnapshot()
        if let snapshot, snapshot.status == .unsatisfied {
            throw NetworkError.configuration(
                reason: .offline("Network is not reachable; refusing to dispatch.")
            )
        }
        // .requiresConnection (VPN/proxy needed) and nil (no
        // path observed yet) fall through — those are not
        // definitively offline.
        return urlRequest
    }
}

let configuration = NetworkConfiguration.advanced(
    baseURL: baseURL,
    auth: AuthPack(
        additionalRequestInterceptors: [RequireOnlineInterceptor(monitor: networkMonitor)]
    )
)
```

The interceptor runs on every retry attempt by ``RequestInterceptor``
contract, so a request issued during a brief outage can retry once
the path recovers when the configured ``RetryPolicy`` accepts the
thrown ``NetworkError``. The built-in
``ExponentialBackoffRetryPolicy`` treats every
``NetworkError/configuration(reason:)`` failure as terminal, so the
offline rejection above is retried only by a custom policy that
returns ``RetryDecision/retry`` for it.

The reason this is a `RequestInterceptor` rather than a
``RetryPolicy`` modifier is that **rejecting the request before it
hits the wire** is the point: a `RetryPolicy.shouldRetry` callback
runs only after a transport error, which means the OS already
spent the timeout budget waiting for an unsatisfied path.

## Pattern C — Wait-for-recovery on retry

For non-interactive flows (background uploads, telemetry batching)
where the request *should* succeed eventually, let the retry
coordinator wait for the network before it retries. The built-in policy
needs only two arguments:

```swift
let configuration = NetworkConfiguration.advanced(
    baseURL: baseURL,
    resilience: ResiliencePack(
        retry: ExponentialBackoffRetryPolicy(
            maxRetries: 3,
            waitsForNetworkChanges: true,
            networkChangeTimeout: 30
        )
    ),
    observability: ObservabilityPack(networkMonitor: networkMonitor)
)
```

``RetryPolicy/shouldRetry(error:retryIndex:request:response:)`` is
synchronous, so a policy cannot await the monitor itself. It declares
the wait through ``RetryPolicy/waitsForNetworkChanges`` and
``RetryPolicy/networkChangeTimeout``, and the coordinator calls
``NetworkMonitoring/waitForChange(from:timeout:)`` on the client's
configured monitor. To add the wait to an existing policy, wrap it:

```swift
struct WaitForRecoveryRetryPolicy: RetryPolicy {
    let inner: any RetryPolicy

    var maxRetries: Int { inner.maxRetries }
    var maxTotalRetries: Int { inner.maxTotalRetries }
    var retryDelay: TimeInterval { inner.retryDelay }
    var maxRetryAfterDelay: TimeInterval? { inner.maxRetryAfterDelay }
    var idempotencyPolicy: RetryIdempotencyPolicy { inner.idempotencyPolicy }

    // After a connectivity failure the coordinator waits up to 30 s
    // for the path to change before the retry delay.
    var waitsForNetworkChanges: Bool { true }
    var networkChangeTimeout: TimeInterval? { 30 }

    func retryDelay(for retryIndex: Int) -> TimeInterval {
        inner.retryDelay(for: retryIndex)
    }

    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision {
        inner.shouldRetry(
            error: error,
            retryIndex: retryIndex,
            request: request,
            response: response
        )
    }

    func shouldResetAttempts(
        afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?,
        to newSnapshot: NetworkSnapshot?
    ) -> Bool {
        inner.shouldResetAttempts(afterNetworkChangeFrom: oldSnapshot, to: newSnapshot)
    }
}
```

The wait applies only after a connectivity failure —
``NetworkError/reachability(_:_:_:)``, including
``ReachabilityReason/cellularDataUnavailable``, or an offline
``NetworkError/configuration(reason:)``. A retry after a `503` or a
timeout on a working network is not held back, and neither is a retry
after `URLError.cannotConnectToHost`, which maps to
``TimeoutReason/connectionTimeout``. The wait happens before
the backoff delay, so ``RetryPolicy/maxRetries`` still bounds attempts
while the request waits out a transient offline window instead of
burning through the budget on a tight loop.
``RetryPolicy/maxTotalRetries`` never resets, even when
`shouldResetAttempts` restarts the per-request count after the path
changes.

## Why no built-in `OfflineQueuePolicy`?

A persistent offline queue (write-through to disk, replay on
recovery) is a backend-shaped decision: idempotency, cookie
scoping, quota, and TTL semantics depend on the API contract, not
on the transport layer. Shipping a one-size-fits-all queue would
either be too restrictive (locked to a single persistence engine)
or too configurable (every consumer ends up wiring their own
shape anyway). The patterns above let consumers compose what they
need on top of ``NetworkMonitoring`` and the existing retry
machinery without taking a dependency on a full queue
implementation that may not match their semantics.

## Cellular access vs reachability

`NetworkSnapshot.interfaceTypes` reports the active path interface
mix (`.wifi`, `.cellular`, `.wiredEthernet`, `.loopback`,
`.other`) so consumers can implement Wi-Fi-only or
cellular-allowed policies on top of reachability:

```swift
guard let snapshot = await monitor.currentSnapshot() else { return }
guard snapshot.status == .satisfied else { return }
guard snapshot.interfaceTypes.contains(.wifi) else {
    // skip large download on cellular
    return
}
try await downloader.startLargeMediaDownload()
```

For an ongoing policy, observe ``NetworkMonitoring/snapshots()``. New
subscribers receive the current snapshot when one is available, followed by
later changes. The stream keeps only the newest pending state for slow
consumers:

```swift
let snapshots = await monitor.snapshots()
for await snapshot in snapshots {
    let shouldDeferLargeTransfer = snapshot.isConstrained || snapshot.isExpensive
    updateTransferPolicy(shouldDeferLargeTransfer)
}
```

Snapshots produced by ``NetworkMonitor`` also report DNS, IPv4, and IPv6
capabilities plus a typed ``NetworkUnsatisfiedReason`` for unsatisfied paths.
Capability values on manually constructed snapshots use conservative defaults
unless supplied explicitly.

This pairs naturally with the `allowsCellularAccess` inputs on
``TransportPack`` and the optional `DownloadTransferPack` type from
`InnoNetworkDownload`.

When the only available path is cellular and it cannot carry the request's
data — cellular data is not allowed for the connection, international data
roaming is off, or an active voice call blocks data on an EDGE or GPRS
network — `URLSession` fails with `URLError.dataNotAllowed`,
`.internationalRoamingOff`, or `.callIsActive`. InnoNetwork reports all three as
``NetworkError/reachability(_:_:_:)`` with
``ReachabilityReason/cellularDataUnavailable``; the underlying error keeps the
exact code. Joining Wi-Fi is a path change, so a retry policy with
``RetryPolicy/waitsForNetworkChanges`` waits for it, and download retries do
the same:

```swift
catch NetworkError.reachability(.cellularDataUnavailable, let underlying, _) {
    showCellularDataUnavailable(isRoaming: underlying.code == URLError.internationalRoamingOff.rawValue)
}
```

## See also

- ``NetworkMonitoring``
- ``NetworkSnapshot``
- ``NetworkReachabilityStatus``
- ``NetworkUnsatisfiedReason``
- ``NetworkInterfaceType``
- <doc:RetryDecisions>
- [HTTP/3 opt-in](../../../../docs/HTTP3.md) for transport tuning
  that often pairs with offline-aware policies.
