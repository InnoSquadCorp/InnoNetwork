# Caching Strategies

``ResponseCachePolicy`` provides an opt-in executor-level cache for idempotent
`GET` requests. It is disabled by default and requires a ``ResponseCache``
implementation, such as ``InMemoryResponseCache``.

```swift
let cache = InMemoryResponseCache(maxBytes: 10 * 1024 * 1024)

let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!
    ) { builder in
        builder.responseCache = cache
        builder.responseCachePolicy = .cacheFirst(maxAge: .seconds(60))
    }
)
```

Available modes:

- `.disabled` keeps the baseline request behaviour.
- `.networkOnly` always goes to the network, but can store successful responses.
- `.cacheFirst(maxAge:)` returns fresh cached data and revalidates stale cached data with `If-None-Match` when an ETag is present.
- `.staleWhileRevalidate(maxAge:staleWindow:)` returns stale data inside the stale window and refreshes it in the background.

When the server responds with `304 Not Modified`, InnoNetwork substitutes the
cached body before status validation and decoding for conditional cache modes.
Cache entries are keyed by HTTP method, absolute URL, and representation
headers that affect privacy or request identity, including `Authorization`.

Request coalescing can be enabled separately with ``RequestCoalescingPolicy``:

```swift
let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!
    ) { builder in
        builder.requestCoalescingPolicy = .getOnly
    }
)
```

Coalescing shares one raw transport result among identical in-flight requests;
each waiter still decodes independently. Non-`GET` methods are excluded by the
default `.getOnly` policy.

Use ``CircuitBreakerPolicy`` when repeated per-host failures should short-circuit
before transport:

```swift
builder.circuitBreakerPolicy = CircuitBreakerPolicy(
    failureThreshold: 3,
    windowSize: 5,
    resetAfter: .seconds(30)
)
```

Open-circuit failures are wrapped in ``CircuitBreakerOpenError`` and surfaced
through ``NetworkError/underlying(_:_:)`` so no new ``NetworkError`` enum case is
required.
