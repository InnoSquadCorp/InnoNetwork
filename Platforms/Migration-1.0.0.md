# Android and Web migration to 1.0.0

## From the 0.1 source preview

Change Android coordinates from `0.1.0-SNAPSHOT` to `1.0.0` and Web resolution
to the `1.0.0` package or tarball. The low-level native session, HTTP-status
semantics, response ceiling, streaming ownership, and typed client shapes remain
the same. The 1.0 line adds compatibility gates and Android KSP endpoint generation.

## Android: replacing Retrofit execution

Keep the application's configured `OkHttpClient`. Interceptors, authenticators,
TLS, cookies, cache, connection pooling, proxy selection, and `EventListener`
remain native OkHttp concerns. Construct `OkHttpNetworkSession(okHttpClient)` and
give `DefaultNetworkClient` the application's base `HttpUrl`.

Typed response decoding now uses `Dispatchers.Default` by default; an optional
third constructor argument injects the application's decoding dispatcher. The
two-argument constructor is retained. Decoders must not assume the caller's
thread or perform UI work. Cancellation remains structured.

| Retrofit concept | InnoNetwork 1.0 |
| --- | --- |
| `@GET`, `@POST`, related methods | `@InnoEndpoint(method, path)` |
| `@Path` | `@InnoPath` on a non-null scalar property |
| `@Query` | `@InnoQuery`; null is omitted |
| `@Header` | `@InnoHeader`; null is omitted |
| `@Body` | `@InnoBody` on a native OkHttp `RequestBody` |
| converter factory | explicit decoder, optionally kotlinx.serialization |
| `Call<T>` cancellation | coroutine cancellation propagated to `Call.cancel()` |
| streaming response | `OkHttpNetworkSession.open()` with caller-owned `use` |

KSP generates only the native request adapter. It does not own transport,
serialization, retry, authentication, DTO reflection, or application lifecycle.
Implement `APIDefinition` manually for dynamic URLs, repeated fields, multipart
policies, or other requests outside the intentionally small annotation model.

## Web and React

Keep native `RequestInit`, `Headers`, credentials, CORS, CSP, and `AbortSignal`
semantics. Use a plain object with `satisfies APIDefinition<Output>` as the
compile-time endpoint contract. React owns its request lifecycle and aborts the
controller during effect cleanup; the core package has no React dependency.

Default headers are origin-scoped when a base URL is configured. Set
`defaultHeaderPolicy: "all"` only when every initial and redirected destination
is trusted to receive the same values. Origin-scoped defaults disable automatic
redirect following; use native `redirect: "manual"` for caller-owned redirect
handling. JSON reaches endpoint decoders as `unknown`; continue validating it
with a caller-selected schema or type guard.

For React server state, pass TanStack Query's query-function `signal` through
the endpoint's `init`; keep caching, retries and invalidation in Query. See the
[tested query adapter](../SmokeTests/ReactConsumer/src/messageQueryOptions.ts)
and [ecosystem assessment](ECOSYSTEM_FIT.md), including SSR limitations.
