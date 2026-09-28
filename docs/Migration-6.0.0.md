# Migration Guide: 6.0.0

This guide describes the approved InnoNetwork 6.0 compatibility reset.
Readiness does not prove publication. Keep production applications on the
tagged 5.x line until the `6.0.0` tag and GitHub Release are published.

The previously planned 6.1 candidates are included in this 6.0 release scope.
The unified baseline contains 1,700 public declarations. `@APIDefinition`
remains Stable; the advanced additions below retain their Provisionally
Stable classifications.

## Preserved JSON and preview-generated schemas

The new `RequestEncodingPolicy.preservedJSON(limits:)` case supports generated
anyOf bodies. Exhaustive switches over this Stable enum must handle the new 6.0
case. Existing `.json` endpoints are unchanged. Preserved models must use
`PreservedJSONCoding`; Foundation codecs fail explicitly. This adds one Stable
case without changing the Stable macro. Custom response decoder failures now
carry `NetworkError.decoding` response context; explicit network errors and
cancellation retain their identity. See [the detailed contract](PRESERVED_JSON.md).

Regenerate and compile clients when adopting the Preview generator extensions.
Constrained or recursive schemas and the explicit 3.1 subset produce immutable
preserved wrappers with validation at construction, decoding and encoding;
callers must handle throwing construction instead of assuming mutable typed
properties. Typed projections are explicit views: they can lose unknown fields
or numeric precision and do not replace the preserved wire representation.

Declare the supported 3.1 dialect explicitly; 3.0 `nullable` is rejected in 3.1,
where type/null is used instead. External references, unsupported pattern syntax
and advanced vocabularies still fail generation before output. Review the
[schema support matrix](SCHEMA_SUPPORT_MATRIX.md) before regenerating a client.
These additions do not change the Stable `@APIDefinition` contract.

Encoding now applies the byte limit to aggregate retained intermediate state
as well as final output. It can fail earlier, including when a later overwrite
would have reduced the final document; do not rely on oversized temporary
representations. This is a codec resource contract, not a total-process RSS cap.

## Named request credentials (opt-in)

Existing `SessionAuthentication` and `@APIDefinition` declarations need no
migration. New API-key and explicit AND/OR endpoints additionally conform to
`RequestSecurityProviding`, use `.anonymous` session authentication, and receive
an application-owned `RequestCredentialProvider`. Generated constructors ask for
the HTTPS credential origin and provider; query/cookie declarations require
explicit opt-in flags. These requests disable sharing and automatic redirects.
Scoped OAuth additionally requires attested granted scopes and expiry. Optional
`OAuthCredentialRefreshing` supplies identity-bound renewal; the library never
widens scopes or launches login UI. Streaming through this contract remains unsupported.
See [request credentials](../Sources/InnoNetwork/InnoNetwork.docc/Articles/RequestCredentials.md).

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

## VCR fixture privacy

VCR recording and replay remove URL user-info and fragments from request
identity and mismatch diagnostics. Existing cassette URLs normalize in memory
when passed to `VCRURLSession`, preserving sequential response order. Save the
session's `cassette` snapshot to migrate a reviewed fixture; raw
`VCRCassette.load` and `write` do not sanitize the original file. Separate
authentication scenarios into different cassettes instead of relying on URL
credentials to distinguish requests. Response bodies still require review.

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
