# RFC 9111 Compliance Matrix for `InnoNetworkPersistentCache`

This RFC pins the exact subset of [RFC 9111: HTTP Caching](https://www.rfc-editor.org/rfc/rfc9111)
that `InnoNetworkPersistentCache` and the in-memory `ResponseCachePolicy`
honour in the 4.0.0 line. The intent is to give operators a single sheet
to reason about cache-driven behavior without re-reading the executor or
the cache actor.

## Header / Directive Coverage

The cache module always reads requests and responses through the
`ResponseCacheKey` / `CachedResponse` value types; this matrix maps RFC
9111 directives to whether the 4.0.0 line consumes, persists, or ignores
them.

| RFC 9111 directive / header | Status | Behavior in 4.0.0 |
| --- | --- | --- |
| `Cache-Control: no-store` (request and response) | ✅ Honored | Skips writes, invalidates an existing key. Applied in `RequestExecutor.storeCacheIfNeeded`. |
| `Cache-Control: no-cache` | ✅ Honored | Stored but flagged as `requiresRevalidation`; the next read forces conditional revalidation. |
| `Cache-Control: private` | ✅ Honored | Skips writes, invalidates an existing key. Quoted-form (`private="X-Foo"`) is parsed by `HTTPListParser` and treated identically. |
| `Cache-Control: public` | ⚠️ Implicit | Cache is private-by-default; `public` is treated as "no objection" rather than a permission grant for shared caches. Single-process consumers are unaffected. |
| `Cache-Control: max-age=N` | ⚠️ Partial | The directive is preserved on disk, but freshness windows are driven by `ResponseCachePolicy` (`cacheFirst(maxAge:)` etc.) rather than the response's `max-age`. A 5.0 follow-up moves freshness onto the directive. |
| `Cache-Control: s-maxage=N` | ❌ Not consumed | Shared-cache directive; ignored because the persistent cache is single-process. |
| `Cache-Control: stale-while-revalidate=N` | ⚠️ Partial | The library exposes stale-while-revalidate semantics through `ResponseCachePolicy.staleWhileRevalidate`, but does not currently parse the response directive — operators opt in via the policy. |
| `Cache-Control: stale-if-error=N` | ❌ Not consumed | Tracked as a 5.0 candidate. |
| `Cache-Control: must-revalidate` | ⚠️ Implicit | Behaves identically to `no-cache` because the cache always revalidates `requiresRevalidation` entries. |
| `Cache-Control: only-if-cached` | ❌ Not consumed | Request directive; the executor always falls through to transport on cache miss. |
| `Cache-Control: immutable` | ❌ Not consumed | Tracked as a 5.0 candidate; safe to ignore because the freshness window is policy-driven. |
| `Expires` | ❌ Not consumed | Superseded by the `ResponseCachePolicy` freshness window in 4.0.0. Listed here so operators do not assume the header takes effect. |
| `Vary` | ✅ Honored | Captured at write time as `varyHeaders` and consulted on every lookup. `Vary: *` skips the write entirely. |
| `Set-Cookie` | ✅ Honored | Refused by default (`storesSetCookieResponses = false`); operators can opt in. |
| `Authorization` (request key) | ✅ Honored | Refused by default (`storesAuthenticatedResponses = false`); operators can opt in. |
| `ETag` | ✅ Honored | Captured for conditional revalidation via `If-None-Match`. |
| `Last-Modified` | ⚠️ Partial | Captured on the cached entry but conditional revalidation in 4.0.0 keys on `If-None-Match` rather than `If-Modified-Since`. |
| `Age` | ❌ Not emitted | The cache does not synthesize an `Age` header on cached responses. |

## Status Code Coverage

`PersistentResponseCache` mirrors the `RequestExecutor`'s default
`cacheableStatusCodes` set (RFC 9110 §15) for whole-response cacheability:

```
[200, 203, 204, 300, 301, 308, 404, 405, 410, 414, 501]
```

Notable exclusions:
- `206 Partial Content` is not stored. Range-aware caching is out of scope.
- `307 Temporary Redirect` is not stored even though it is technically
  cacheable when paired with `Cache-Control: max-age`. Storing it would
  silently change observed redirect behaviour, so the 4.0.0 line refuses
  the cache write.

## Eviction and Privacy

These behaviours sit alongside RFC 9111 but are unique to the InnoNetwork
implementation:

| Behavior | Default | Configuration knob |
| --- | --- | --- |
| Total byte budget | 50 MB | `PersistentResponseCacheConfiguration.maxBytes` |
| Total entry budget | 1,000 | `maxEntries` |
| Per-entry hard cap | 5 MB | `maxEntryBytes` |
| Authenticated request bodies | rejected | `storesAuthenticatedResponses` |
| `Set-Cookie` responses | rejected | `storesSetCookieResponses` |
| File protection class | `.completeUnlessOpen` | `dataProtectionClass` |
| Index durability | `.onCheckpoint` (no fsync) | `persistenceFsyncPolicy` |

`statistics()` reports cumulative `hitCount` / `missCount` / `evictionCount`
since the actor was constructed; the counters seed from the open-time
scrubbing pipeline so the eviction count covers the entire actor
lifetime, not only post-init activity.

## Deviations Tracked for 5.0

1. **`Cache-Control: max-age` consumption.** The 5.0 line should treat the
   response directive as a freshness signal, with `ResponseCachePolicy`
   acting as a per-client cap rather than the sole source of freshness.
2. **`stale-while-revalidate` directive parsing.** The runtime semantics
   already exist; the 5.0 line should also accept the response directive
   directly so APIs that emit it transparently get stale-while-revalidate
   behavior.
3. **`Last-Modified` based revalidation.** The cached entry already
   captures `Last-Modified`; the 5.0 conditional revalidation path should
   emit `If-Modified-Since` when no `ETag` is present.
4. **`Age` header synthesis.** Some downstream caches (or operator tools)
   inspect the `Age` header to detect stale-while-revalidate hits; the 5.0
   line should emit it on cache hits.

The full code path lives in
[`Sources/InnoNetwork/Cache/ResponseCachePolicy.swift`](../../Sources/InnoNetwork/Cache/ResponseCachePolicy.swift)
and
[`Sources/InnoNetworkPersistentCache/PersistentResponseCache.swift`](../../Sources/InnoNetworkPersistentCache/PersistentResponseCache.swift).
