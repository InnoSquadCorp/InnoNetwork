# Migration Guide: 6.0.0

This guide describes the unreleased InnoNetwork 6.0 draft. There is no
`6.0.0` tag yet; keep production applications on `5.1.0` until the release
notes are marked ready and the tag is published.

The previously planned 6.1 candidates are included in this 6.0 release scope.
The unified baseline contains 1,614 public declarations. `@APIDefinition`
remains Stable; the advanced additions below retain their Provisionally
Stable classifications.

## Package boundary changes

InnoNetwork 6 removes the temporary `InnoNetworkNext` preview product and the
four HLS products. Operation-first APIs move into the root `InnoNetwork`
module, while HLS moves to the independently versioned InnoStream package.

Before:

```swift
dependencies: [
    .package(
        url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
        .upToNextMajor(from: "5.1.0")
    )
],
targets: [
    .target(
        name: "MediaFeature",
        dependencies: [
            .product(name: "InnoNetworkNext", package: "InnoNetwork"),
            .product(name: "InnoNetworkHLS", package: "InnoNetwork"),
        ]
    )
]
```

After both release tags exist:

```swift
dependencies: [
    .package(
        url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
        .upToNextMajor(from: "6.0.0")
    ),
    .package(
        url: "https://github.com/InnoSquadCorp/InnoStream.git",
        .upToNextMajor(from: "1.0.0")
    ),
],
targets: [
    .target(
        name: "MediaFeature",
        dependencies: [
            .product(name: "InnoNetwork", package: "InnoNetwork"),
            .product(name: "InnoNetworkHLS", package: "InnoStream"),
        ]
    )
]
```

Apply the same package-owner change to `InnoNetworkHLSLive`,
`InnoNetworkHLSAVFoundation`, and `InnoNetworkHLSAudio`. Source imports keep
their existing module names. Replace `import InnoNetworkNext` with
`import InnoNetwork`.

## Stable macro-first endpoint contract

`@APIDefinition(method:path:auth:)` is Stable in 6.0. Existing macro-first
endpoint declarations require no source migration. The default-enabled
`Macros` trait and the explicit `traits: []` core-only opt-out are also Stable;
manual `APIDefinition` conformance remains the supported fallback when a
consumer does not want compiler plug-in compilation.

For 6.x, existing accepted declarations retain their generated method,
percent-encoded path, authentication, conformance, and payload-witness meaning.
Future optional macro arguments must have defaults. Diagnostic wording and
Fix-It formatting may improve without constituting a source-breaking change.

## Operation recovery contract

`OperationNetworkClient.start(_:)` infers replay safety from the HTTP method.
GET, HEAD, OPTIONS, and TRACE may recommend retry after a transient failure.
Unsafe methods stay terminal unless the application owns a stable idempotency
key that is reused across operation restarts:

```swift
let operation = client.start(
    CreateOrder(idempotencyKey: orderAttemptID),
    replaySafety: .stableIdempotencyKey
)
```

A 401 recommends `.reauthenticate` only for session-authenticated endpoints.
A 403 remains terminal. Reauthentication never authorizes automatic replay;
the application still decides whether to start another operation.

## Advanced capability migration

The opt-in features in the following section are also part of 6.0; they do not
require a later 6.1 dependency.

- **Operation deadlines:** opt into `NetworkOperationDeadline` on buffered
  operation starts when the whole operation needs one monotonic budget.
  `NetworkFailure.deadlineStage` describes the exhausted stage. Existing
  starts without a deadline keep their behavior. Separately returned streams
  use `StreamingTimeoutPolicy`, not the buffered operation deadline.
- **Streaming decoders:** stateful `StreamingAPIDefinition` implementations
  should provide `makeDecoder()` so each response and reconnect owns isolated
  decoder state. Stateless `decode(line:)` implementations remain compatible.
  SSE now preserves empty data and significant newlines, inherits IDs, and
  handles CR/LF/CRLF framing. Review consumers that depended on the old parser
  behavior. Cursor resume requires lossless buffering and an application-owned
  replay/deduplication contract; invalid cursors cannot trigger fallback resume.
- **Cache persistence:** custom stores should persist and restore
  `CachedResponse.rfc9111InitialAge` along with the existing response fields.
  This preserves upstream age and transport delay across reopen. The built-in
  persistent cache handles legacy records conservatively. `staleIfError` and
  `requestOnlyIfCached` remain explicit policy wrappers; no-cache and no-store
  restrictions, validator matching, and concurrent invalidation apply to them.
- **Admission and quotas:** configure `RequestAdmissionPolicy` and
  `AdvancedRateLimitPolicy` explicitly. Token-bucket and sliding-window
  algorithms are alternatives selected for the application's server quota
  contract. IETF RateLimit draft-11 feedback is separately opt-in; valid
  `Retry-After` takes precedence. These policies do not infer a server's quota.
- **Managed uploads:** pause/resume preserves durable user intent. Retrying a
  failed upload requires refreshed inputs with the original destination,
  case-sensitive HTTP method, and application-owned `Idempotency-Key`.
  `ResumableUploadEngine` is a separate adapter-based capability that commits
  server-confirmed offsets from one immutable file snapshot. Validate the
  application's backend adapter and crash/restart behavior before adoption.
- **Span export:** `NetworkSpanObserver` exports logical requests and physical
  attempts through a bounded queue. Cache hits and coalesced followers have
  logical spans without invented transport attempts. Applications own exporter
  lifetime and shutdown; request and response bodies are excluded.

See the [streaming guide](../Sources/InnoNetwork/InnoNetwork.docc/Articles/StreamingGuide.md),
[cache guide](../Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md),
[admission and quota guide](../Sources/InnoNetwork/InnoNetwork.docc/Articles/AdmissionAndRateLimiting.md),
[upload guide](../Sources/InnoNetworkUpload/InnoNetworkUpload.docc/InnoNetworkUpload.md),
and [span export guide](../Sources/InnoNetwork/InnoNetwork.docc/Articles/ObservabilityExporters.md)
for configuration and lifetime examples.

## Validation order

1. Build InnoNetwork and InnoStream together with `INNONETWORK_LOCAL_PATH`.
2. Build non-HLS consumers against the local InnoNetwork 6 candidate.
3. Publish and verify InnoNetwork `6.0.0`.
4. Resolve InnoStream without a local override, then publish and verify
   InnoStream `1.0.0`.
5. Resolve migrated HLS consumers from a clean checkout using only the two
   published tags.
6. Publish companion packages only after their clean tagged-dependency smoke
   passes.

Local-path builds prove source compatibility but do not prove remote package
identity, tag availability, or a clean resolver graph.
