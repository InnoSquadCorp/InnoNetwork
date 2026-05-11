# HTTP/3 (QUIC) Opt-In

`URLSession` on iOS 15+ / macOS 12+ / tvOS 15+ / watchOS 8+ /
visionOS 1+ supports HTTP/3 (QUIC) when both endpoints negotiate it,
but the negotiation is **opt-in per session**. InnoNetwork inherits
the platform default — HTTP/2 over TLS 1.3 — so callers who want
QUIC must enable it explicitly.

This article shows the pattern. Build the starting
`URLSessionConfiguration` via
``NetworkConfiguration/makeURLSessionConfiguration()`` so timeout, cache,
and network-access defaults stay aligned with ``NetworkConfiguration``.
Then mutate `URLSessionConfiguration` directly for HTTP/3, cookie
isolation, TLS protocol bounds, proxies, or other Foundation-owned
session behavior before injecting the resulting `URLSession` into
`DefaultNetworkClient`.

## When to enable HTTP/3

Enable when **all** of the following hold:

- Your endpoint advertises QUIC via DNS HTTPS RR (`Alt-Svc: h3=":443"`)
  or via TLS ALPN. Cloudflare, Fastly, Akamai, GCP HTTPS LB, and AWS
  CloudFront all do — many internal load balancers do not.
- Your traffic profile is **latency-sensitive over flaky networks**:
  mobile cellular, transit, or congested Wi-Fi where TCP head-of-line
  blocking dominates the tail latency.
- You are **not** behind a captive proxy or corporate middlebox that
  forces HTTPS interception. Most of those terminate TLS and do not
  speak HTTP/3, so QUIC frames get dropped and `URLSession` quietly
  falls back to HTTP/2 — not a regression, but the win evaporates.

If you are not sure, leave HTTP/3 disabled. The HTTP/2 default is
already excellent on modern Apple platforms, and the HTTP/3 wins are
typically in the 5-20% range on the long tail rather than across
median requests.

## Compatibility matrix

| Platform | Minimum SDK | API |
| --- | --- | --- |
| iOS / iPadOS | 15.0 | `URLSessionConfiguration.assumesHTTP3Capable` |
| macOS | 12.0 | same |
| tvOS | 15.0 | same |
| watchOS | 8.0 | same |
| visionOS | 1.0 | same |

InnoNetwork's own minimum (iOS 16, macOS 14, tvOS 16, watchOS 9,
visionOS 1) is above these floors, so callers can rely on
`assumesHTTP3Capable` without an `@available` shim. Linux builds are
not supported — see `docs/PlatformSupport.md`.

## Enabling HTTP/3

Use the same `URLSessionConfiguration` injection pattern documented in
`docs/Cookies.md`:

```swift
let config = NetworkConfiguration.safeDefaults(baseURL: baseURL)
let sessionConfig = config.makeURLSessionConfiguration()
sessionConfig.assumesHTTP3Capable = true

let session = URLSession(configuration: sessionConfig)
let client = DefaultNetworkClient(configuration: config, session: session)
```

`assumesHTTP3Capable = true` tells the system the origin advertises
QUIC even when the cached `Alt-Svc` row has not arrived yet. The
practical effect: the very first request to a known-QUIC origin can
race a QUIC handshake instead of waiting for the TCP+TLS round trip
plus the `Alt-Svc` upgrade.

If the origin does not actually speak QUIC, `URLSession` transparently
falls back to HTTP/2 — there is no API-level error, but the latency
win does not materialize.

## Combining with other overrides

The configuration mutates a single `URLSessionConfiguration`. The most
common pairing is HTTP/3 + a private cookie jar:

```swift
let sessionConfig = config.makeURLSessionConfiguration()
sessionConfig.assumesHTTP3Capable = true
sessionConfig.httpCookieStorage = isolatedCookies
let session = URLSession(configuration: sessionConfig)
```

Mutate the configuration in one place rather than threading multiple
closures through the configuration surface.

## Verifying HTTP/3 negotiation

`URLSessionTaskMetrics.transactionMetrics[i].networkProtocolName`
reports the negotiated protocol per network transaction. Wire it
through a `NetworkEventObserving` hook to confirm:

```swift
struct ProtocolObserver: NetworkEventObserving {
    func handle(_ event: NetworkEvent) {
        if case .didFinishTransaction(let metrics) = event {
            for transaction in metrics.transactionMetrics {
                if let proto = transaction.networkProtocolName {
                    // Expect "h3" for HTTP/3, "h2" for HTTP/2,
                    // "http/1.1" for the legacy transport.
                    print("transport: \(proto)")
                }
            }
        }
    }
}
```

A non-`h3` value on a known-QUIC origin almost always points at a
middlebox between client and origin, not a misconfiguration on the
InnoNetwork side.

## Known caveats

- **Captive portals on first connect**: a fresh session that has
  never seen the origin may still TCP-handshake first, depending on
  cached `Alt-Svc` state. The first few requests after a clean
  install can land on HTTP/2 even with `assumesHTTP3Capable = true`.
- **Background sessions**: HTTP/3 in background `URLSession`
  instances is supported but more conservative — long-lived
  background tasks may downgrade to HTTP/2 if the QUIC connection
  cannot be re-established quickly.
- **Strict 0-RTT**: QUIC's 0-RTT data is replay-vulnerable for
  non-idempotent requests; `URLSession` declines 0-RTT for
  `POST`/`PUT`/`PATCH`/`DELETE` automatically. No additional opt-out
  is required.

## See also


- [Cookie Storage Isolation](Cookies.md) for the same hook applied
  to per-client cookie jars.
- [Apple URLSession Programming Guide — Networking Protocols](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/3997491-assumeshttp3capable)
