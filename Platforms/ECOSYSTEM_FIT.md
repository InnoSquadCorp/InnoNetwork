# Android and React ecosystem fit

Reviewed 2026-10-18 against the cross-platform candidate, with Swift excluded.
The decision is **native transport plus optional typed endpoints**, not a shared
application framework or a line-for-line Swift API port.

## Android

The layering fits an existing `ViewModel -> repository -> HTTP client` stack:

- Inject the application's shared `OkHttpClient` into `OkHttpNetworkSession`.
  Keep interceptors, authenticators, timeouts, cache, cookies, TLS and event
  listeners there. Constructor injection works with manual wiring, Hilt or Koin;
  the library adds no container, global scope, ViewModel or Compose dependency.
- One-shot calls are suspending functions; caller cancellation reaches the
  native call. Repository/ViewModel lifetime and `StateFlow` stay app-owned.
- Buffered I/O runs on OkHttp callbacks. `DefaultNetworkClient` decodes on
  `Dispatchers.Default` by default, with an injectable `CoroutineDispatcher` for
  tests or application policy. Request construction and status predicates must
  be lightweight. Synchronous JSON helpers and streaming reads remain explicit
  caller work: move blocking streaming consumption to an application I/O
  dispatcher and close/cancel the stream.
- KSP generates native requests, not service proxies or runtime reflection.
  Its optional annotations are idiomatic compile-time assistance. Kotlin does
  not need a Swift-macro emulation layer.

This can replace Retrofit's endpoint/execution layer for the documented REST
subset, but **is not a drop-in Retrofit replacement**. Existing interfaces and
converter/call-adapter registrations require migration. Repeated query fields,
dynamic URLs and richer multipart policies use manual `APIDefinition` and
native OkHttp bodies; they are not implicit annotation support. It does not
replace OkHttp or automatically recreate every Retrofit extension.

Evidence: native transport/client/serialization tests, generated positive and
negative KSP fixtures, an independently resolved Maven consumer, R8 packaging,
and prior API 26 runtime checks. Hilt/Koin application builds, older Kotlin/AGP
lines, and API 21-25 device execution have not been qualified. The documented
Kotlin/KSP/AGP/JDK tuple is a tested toolchain, not a universal compatibility
claim. See [readiness](RELEASE_READINESS.md).

## React and TypeScript

The core is a Fetch data source, not a React server-state framework:

- Native `Request`/`RequestInit`/`Response`/`AbortSignal` remain visible. Plain
  objects with `satisfies APIDefinition<T>` and explicit runtime decoders need
  no Babel plugin, decorator transform, provider or generated React hook.
- For shared server state, compose it under TanStack Query, SWR or framework
  loaders. Those layers should own cache keys, freshness, deduplication,
  invalidation, retries and UI state. Do not add a competing transport cache or
  a second retry loop. Feed the query/loader's signal into `definition.init`.
- Typed client requests reject unaccepted HTTP statuses. Low-level `data()`
  deliberately resolves HTTP errors; a query function using it must call
  `requireSuccessful()` if HTTP errors should reject the query.
- Direct effects are a minimal lifecycle example, not the preferred shared
  application data layer. They require cleanup and stale-result guards. Keep
  clients, input objects and callback dependencies stable when appropriate;
  inline callbacks are reactive dependencies, not an excuse to omit them.
- SSR authentication must be scoped to each incoming request/user. Do not
  share credential-bearing sessions across server requests. Cache keys must
  include application tenant/user identity where necessary, or be cleared on
  identity changes. Next.js extended Fetch caching/revalidation options are not
  automatically preserved by a generic native `Request`; use framework-native
  fetching or a server-owned injected Fetch adapter for those policies.

The React consumer exercises a real `@tanstack/react-query` integration:
typed `useQuery`, shared-key deduplication/freshness, unmount-to-Fetch
cancellation, and HTTP rejection without hidden retries. Its dependency exists
only in the consumer fixture; the published core still has zero runtime
dependencies. Separate direct-effect tests cover StrictMode, unmount and stale
results. This is not SWR, Next.js hydration, React Native or every bundler proof.

## Confirmed correction, candidates and optional work

- Confirmed and corrected: Android typed decoding previously ran on the caller
  thread. A reproducer failed before the dispatcher change while the normal
  request control passed; regressions now cover default/injected execution and
  cancellation propagation.
- No additional confirmed ecosystem-specific defect is currently open in this
  bounded review. Remote CI failures are tracked separately in the readiness
  record; an unqualified framework/toolchain is not counted as passing.
- Optional future work: Retrofit migration helpers or additional KSP field
  shapes, older toolchain qualification, framework-specific SSR examples.
  Add them for real consumer demand; they are not reasons to embed UI state,
  DI or a second cache/retry system in the transport.

## Primary contracts checked

- [Android coroutine guidance](https://developer.android.com/kotlin/coroutines/coroutines-best-practices): main-safe suspension, injected dispatchers and caller-owned lifetime.
- [OkHttp calls](https://lysine.dev/okhttp/features/calls/): asynchronous callbacks, native cancellation and transport follow-ups.
- [Retrofit declarations](https://lysine.dev/retrofit/declarations/): service declarations and suspending execution are a layer above the transport.
- [React effects](https://react.dev/reference/react/useEffect): cleanup, reactive dependencies and client-only effects.
- [TanStack Query cancellation](https://tanstack.com/query/latest/docs/framework/react/guides/query-cancellation): query-owned signals and cancellation.
- [TanStack query functions](https://tanstack.com/query/latest/docs/framework/react/guides/query-functions): errors must reject the query function.
- [Next.js Fetch](https://nextjs.org/docs/app/api-reference/functions/fetch): framework-specific cache, revalidation and tag options are separate from native Fetch.
