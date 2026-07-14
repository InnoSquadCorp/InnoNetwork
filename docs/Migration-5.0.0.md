# Migration Guide: 5.0.0

InnoNetwork 5.0 makes request identity, signing, redirects, and configuration
composition explicit. The changes below intentionally remove 4.x migration
bridges that could make the bytes sent on the wire differ from the request a
policy observed.

## Required source changes

| 4.x usage | 5.0 replacement |
| --- | --- |
| `RequestExecutionNext.execute(request)` | `RequestExecutionNext.execute()` |
| `.with(retry:)`, `.with(circuitBreaker:)`, `.with(coalescing:)`, `.with(executionPolicies:)` | `ResiliencePack` passed to `NetworkConfiguration.advanced(...)` |
| `.with(refresh:)` | `AuthPack(refreshToken:)` |
| `.with(eventObservers:)` | `ObservabilityPack(eventObservers:)` |
| `.with(cache:)` | `CachePack(responseCache:)` |
| Public `StateReducer` / `StateReduction` | An application-owned reducer type, or a feature-local reducer |
| Body signing in `RequestInterceptor` | `RequestSigner.signatureHeaders(for:body:)` |

## Request execution policies preserve request identity

`RequestExecutionNext.execute(_:)` is replaced by the zero-argument
`RequestExecutionNext.execute()`. A policy can still short-circuit by calling
`next` zero times or replay the same transport request by calling it multiple
times, but it cannot substitute another `URLRequest`.

Move URL, header, and body adaptation into a `RequestInterceptor`:

```swift
struct HeaderInterceptor: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("example", forHTTPHeaderField: "X-Example")
        return request
    }
}

struct TracingPolicy: RequestExecutionPolicy {
    func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        recordStart(request: input.request, context: context)
        let response = try await next.execute()
        recordFinish(response: response, context: context)
        return response
    }
}
```

This keeps cache, coalescing, retry, signing, and transport identity aligned
around the executor-owned request.

## Compose configuration with packs

The seven deprecated `NetworkConfiguration.with(...)` modifiers are removed.
Construct the complete policy set at one call site:

```swift
let configuration = NetworkConfiguration.advanced(
    baseURL: baseURL,
    resilience: ResiliencePack(
        retry: ExponentialBackoffRetryPolicy(maxRetries: 2),
        coalescing: .getOnly,
        circuitBreaker: CircuitBreakerPolicy(failureThreshold: 5),
        customExecutionPolicies: [reachabilityPolicy]
    ),
    auth: AuthPack(refreshToken: refreshPolicy),
    observability: ObservabilityPack(eventObservers: [observer]),
    cache: CachePack(responseCache: cache)
)
```

Pack fields default to `nil`, so specify only the axes the client owns. To
disable a policy that a preset enables, construct an explicit advanced
configuration instead of mutating that preset after construction.

## Own reducer vocabulary at the feature boundary

`StateReducer` and `StateReduction` are no longer public API. They only
described package lifecycle mechanics and did not provide transport behavior.
Applications that used the generic names should define a small local protocol
or return a feature-specific tuple/value from their reducer. There is no
runtime migration and no replacement module to import.

## Sign the final body, not a preliminary request

Body-aware authentication moves to `RequestSigner`. In 5.0 the executor:

1. encodes the payload and snapshots caller-owned files;
2. runs configuration and endpoint request interceptors;
3. applies the current refresh token;
4. runs configuration signers, then endpoint signers; and
5. sends the exact `RequestBody` observed by the signers.

Signing runs for every retry and refresh replay. HMAC, request-minted JWT, and
AWS SigV4 reference implementations now conform to `RequestSigner` despite
their legacy `Interceptor` suffixes. Opaque `httpBodyStream` values are
rejected; use data or explicit file payloads.

Signed requests bypass response-cache reads and writes, request coalescing,
and URLSession caching. They also reject every automatic redirect because a
URLSession-generated follow-up cannot pass through the asynchronous signer.
Issue a new typed request after validating an intentional redirect target.

See the [Request Signing guide](../Sources/InnoNetwork/InnoNetwork.docc/Articles/RequestSigning.md)
for custom signer and file-lifetime examples.

## Redirect defaults are stricter

The default redirect policy now denies HTTPS-to-HTTP downgrade, strips the
expanded sensitive-header set when authority changes, and denies cross-origin
`307`/`308` redirects for unsafe methods. Signed requests deny automatic
redirects even when the target is same-origin.

If an API contract requires a redirect that the defaults reject, treat the 3xx
as application data, validate the target explicitly, and start a new typed
request. Do not forward authorization, cookie, proxy authorization, API-key,
or signature headers across authority boundaries.

## Code generation remains local and experimental

`Packages/InnoNetworkCodegen` is a nested SwiftPM package with a path
dependency on the repository root. The root 5.0 tag does not vend an
`InnoNetworkCodegen` product, so the nested package is supported only from a
complete local checkout. Its macro contract remains experimental until it is
distributed as an independent package or moved into the root package graph.

## Pre-flight checklist

- [ ] Replace every `next.execute(request)` call with `next.execute()` and
  move adaptation to `RequestInterceptor`.
- [ ] Replace the seven `.with(...)` modifiers with configuration packs.
- [ ] Move adopter-defined `StateReducer` conformances to app-owned types.
- [ ] Move body-dependent authentication to `RequestSigner`.
- [ ] Verify any redirect-dependent endpoint against the stricter policy.
- [ ] Exercise signed data and file uploads, retries, and refresh replays.
- [ ] Build codegen users from a complete local checkout.

## See also

- [API_STABILITY.md](../API_STABILITY.md) for the 5.x compatibility contract.
- [Migration-4.0.0.md](Migration-4.0.0.md) for the original public baseline.
- [MIGRATION_POLICY.md](MIGRATION_POLICY.md) for the general migration policy.
