# Caching Strategies

``ResponseCachePolicy`` provides an opt-in executor-level cache for idempotent
`GET` requests. It is disabled by default and requires a ``ResponseCache``
implementation, such as ``InMemoryResponseCache``.

```swift
let cache = InMemoryResponseCache(maxBytes: 10 * 1024 * 1024)

let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!,
        cache: CachePack(
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: cache
        )
    )
)
```

Available modes:

- `.disabled` keeps the baseline request behaviour.
- `.networkOnly` always goes to the network and skips both cache reads and writes, so an existing cache stays untouched while callers still get fresh data.
- `.cacheFirst(maxAge:)` returns fresh cached data and revalidates stale cached data with `If-None-Match` when an ETag is present.
- `.staleWhileRevalidate(maxAge:staleWindow:)` returns stale data inside the stale window and refreshes it in the background.
- `.staleIfError(wrapping:)` permits an otherwise stale entry to recover an
  eligible transient failure only when the stored response carries a valid
  `stale-if-error=N` directive.
- `.requestOnlyIfCached(wrapping:)` consumes request `only-if-cached` and
  guarantees that the request will either use a reusable entry or fail locally
  without transport.

The two cache-control wrappers are additive opt-ins and may be nested with the
freshness policies in either order. For example:

```swift
let policy = ResponseCachePolicy.requestOnlyIfCached(
    wrapping: .staleIfError(
        wrapping: .rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )
    )
)
```

`only-if-cached` accepts a fresh cache-first result or a response inside an
explicit stale-while-revalidate window; the latter is returned without its
usual background revalidation. A miss, an expired entry, or an entry marked
for mandatory revalidation throws a typed `NetworkError.configuration` before
signing or transport. Without the wrapper, InnoNetwork leaves the directive
origin-controlled and follows the normal cache/network path.

`stale-if-error` is evaluated after the configured retry policy reaches a
terminal decision. It covers only unacceptable `500`, `502`, `503`, and `504`
responses plus typed timeout and reachability failures. A later successful
retry always wins. Cancellation, trust, configuration, decoding,
response-interceptor, and response-body-limit failures never use the fallback.
Malformed, missing, or duplicate `stale-if-error` values fail closed, as do
`no-store`, `must-revalidate`, and entries beyond the advertised window.

When the server responds with `304 Not Modified`, InnoNetwork substitutes the
cached body before status validation and decoding for conditional cache modes.

A `304` must identify the stored response that the conditional request was
built from. When its `ETag` or `Last-Modified` identifies a different
representation, or the merged headers cannot be rebuilt, the request fails with
``NetworkError/underlying(_:_:)`` whose ``SendableUnderlyingError`` has domain
`InnoNetwork.ResponseCache` and code `304`. The error's ``Response`` is the
stored response; its body is redacted unless failure-payload capture is
enabled. Before the error is reported, InnoNetwork removes the stored entry,
provided it is still that representation, so a replay — the built-in retry or
your own — sends an unconditional request and receives a full response. The
failure is transient. The circuit breaker does not count it, because the `304`
was already recorded as a successful exchange. A background
stale-while-revalidate refresh follows the same rule. A `304` that arrives
after the entry was removed or replaced by another request fails the same way
but removes nothing.

GET responses with RFC-cacheable whole-response status codes (`200`, `203`,
`204`, `300`, `301`, `308`, `404`, `405`, `410`, `414`, and `501`) are eligible
for storage. `206 Partial Content` is intentionally excluded because range
semantics require a different representation model.

Cache entries are keyed by HTTP method, absolute URL, and representation
headers that affect privacy or request identity. Credential-like headers such as
`Authorization` and `Cookie` are included as SHA-256 fingerprints rather than raw
values, and `Accept-Language` is included so locale-specific responses do not
cross-pollute. URL fragments are ignored because they are not sent to the server.
Responses to requests carrying `Authorization` are stored only when the origin
explicitly permits it with `Cache-Control: public`, `must-revalidate`, or
`s-maxage`.
The cache-control wrappers do not relax this admission rule or cache-key
partitioning: authenticated stale recovery still requires an admitted entry
for the same credential identity and an explicit origin directive.

## Scope and offline storage

``ResponseCachePolicy`` is an executor-level response reuse policy, not a
general offline database. It is a good fit when:

- the request is an idempotent `GET`
- the response body can be reused as one HTTP representation
- freshness can be expressed with a caller-provided max age, ETag
  revalidation, or stale-while-revalidate window
- cache lifetime can remain process-local through ``InMemoryResponseCache``

Use app-owned persistent storage when cached data needs domain indexing,
offline mutation, conflict resolution, cross-launch browse/search, or user
visible "downloaded for offline" semantics. In those cases, let InnoNetwork
fetch and validate transport responses, then project the decoded model into
SwiftData, Core Data, SQLite, files, or another app-owned store.

Persistent response caching ships as the optional `InnoNetworkPersistentCache`
companion product rather than being part of the core `InnoNetwork` target. Its
first-party disk cache defines these policies explicitly:

- cache key normalization and configurable Vary/identity inputs
- freshness precedence between caller policy, `Cache-Control`, and validators
- eviction by byte budget, age, and user/account boundary
- privacy defaults for credential-derived keys and sensitive payloads
- iOS-family data protection class and explicit deletion hooks. Selecting
  `.none` requests `NSFileProtectionNone` on cache-owned paths on iOS, tvOS,
  watchOS, and visionOS; other platforms treat the class as a no-op.

InnoNetwork honours response cache-control directives that affect storage and
reuse:

- `Cache-Control: no-store` responses are not stored and invalidate the current
  key if an older entry exists.
- `Cache-Control: private` responses are treated as do-not-store by the built-in
  executor and the persistent companion cache.
- `Cache-Control: no-cache` responses may be stored, but every lookup must
  revalidate before reuse even inside the caller-provided freshness window.
- `ResponseCachePolicy.rfc9111Compliant(wrapping:)` additionally consumes
  `Cache-Control: max-age`, `Expires`, and `Last-Modified` as freshness
  signals, using `Expires - Date` or `Expires - storedAt` when no valid
  `max-age` exists and applying the RFC 9111 §4.2.2 10% heuristic when only
  `Last-Modified` is available.
- Successful unsafe methods (`POST`, `PUT`, `PATCH`, `DELETE`, and unknown
  methods) invalidate all cached variants for the normalized target URI. This
  implements the RFC 9111 §4.4 target-URI requirement; `Location` and
  `Content-Location` candidate invalidation remains out of scope.

The response `Vary` header is processed automatically. `Vary: *` responses are
not stored, while concrete `Vary` headers capture a snapshot of the named request
headers and require those values to match on later lookup.

A `304 Not Modified` reply confirms freshness of the stored representation, but
its own `Vary` header describes the variant the origin would have served on a
full `200`. When the 304 carries a `Vary` value that differs from the snapshot
captured when the entry was stored, InnoNetwork preserves the existing entry
verbatim and only refreshes its `storedAt` timestamp instead of rewriting the
entry under the new vary dimension. This keeps the stored representation
addressable through its original vary signature; later 200 responses with the
revised `Vary` are stored as new entries through the normal write path.

Request coalescing can be enabled separately with ``RequestCoalescingPolicy``:

```swift
let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!,
        resilience: ResiliencePack(coalescing: .getOnly)
    )
)
```

Coalescing shares one raw transport result among identical in-flight requests;
each waiter still decodes independently. Non-`GET` methods are excluded by the
default `.getOnly` policy.

Use ``CircuitBreakerPolicy`` when repeated per-host failures should short-circuit
before transport:

```swift
let configuration = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!,
    resilience: ResiliencePack(
        circuitBreaker: CircuitBreakerPolicy(
            failureThreshold: 3,
            windowSize: 5,
            resetAfter: .seconds(30)
        )
    )
)
```

While a circuit is open, a request fails before transport with
``NetworkError/policyRejected(_:)`` and
``NetworkPolicyRejection/circuitOpen(_:)``. The payload is a
``CircuitBreakerOpenError`` that carries the `host` and the `retryAfter`
interval:

```swift
do {
    let feed = try await client.request(GetFeed())
    render(feed)
} catch NetworkError.policyRejected(.circuitOpen(let open)) {
    showTemporarilyUnavailable(retryAfter: open.retryAfter)
}
```

An open circuit is a local decision, so the built-in retry policy does not
retry it. The breaker counts `5xx` responses, timeouts, reachability failures,
and unclassified transport errors. It does not count a policy rejection — a
response over the body limit, or a full admission or rate-limit queue — or an
authentication failure, because neither is evidence about the host's health.
`stream(_:)` handshakes take part in the same per-host breaker.

## URLSession's own cache

`URLSession` keeps a second cache, `URLCache`, which keys entries by URL and
ignores credential headers. A request that reaches transport carrying
`Authorization`, `Proxy-Authorization`, `Cookie`, `X-API-Key`, `X-Auth-Token`,
or a header listed in `CachePack(sensitiveHeaderNames:)` therefore never has
its response stored in `URLCache`, whatever its cache policy. Under the default
`.useProtocolCachePolicy` it does not read `URLCache` either: the request is
sent with `.reloadIgnoringLocalCacheData`. Only an explicitly cache-first
policy, `.returnCacheDataElseLoad` or `.returnCacheDataDontLoad`, opts out of
both rules. The check runs after request interceptors and token application,
so it covers a credential that an interceptor adds, with either preset, and it
applies to `stream(_:)` handshakes as well. Signed requests and requests that
use ``RequestSecurity`` always bypass `URLCache`. The library's response cache
described above is not affected; it partitions entries by a fingerprint of the
credential.

### Cache policy with the advanced preset

``NetworkConfiguration/advanced(baseURL:resilience:auth:observability:cache:transport:)``
starts from ``NetworkConfiguration/safeDefaults(baseURL:)``, whose
`URLRequest.CachePolicy` is `.useProtocolCachePolicy`. When ``TransportPack``
does not set a `cachePolicy`, requests use `.reloadIgnoringLocalCacheData`
instead if

- ``CachePack`` sets a `responseCachePolicy` other than `.disabled`, so
  `URLSession`'s own cache does not answer for, or store beside, the library's
  response cache; or
- ``AuthPack`` configures a session refresh policy, so a response fetched with
  one session's token is not served from `URLSession`'s cache after the session
  changes, even when the token travels in a header the library does not
  recognize as a credential.

A credential in a custom header that is not in the list above is not
recognized. Add the header to `CachePack(sensitiveHeaderNames:)`, which also
fingerprints it in response-cache keys, or set
`TransportPack(cachePolicy: .reloadIgnoringLocalCacheData)`.
