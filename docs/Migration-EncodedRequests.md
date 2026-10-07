# Encoded-request migration for Core 6.1.0

These notes describe [published Core 6.1.0](https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.1.0),
released on 2026-10-07 UTC, without changing the released 6.0 tag. The macro-first
Protobuf companion targets this boundary, but its own publication and compatible
dependency graph must be verified before adoption; local consumer validation
does not prove public dependency resolution for that companion.
The [6.1.0 release notes](releases/6.1.0.md) are separate from the
[archived roadmap record](releases/archive/6.1.0-superseded-roadmap.md) that was
absorbed into core 6.0. Stable source compatibility is retained for this minor;
Provisionally Stable migrations are called out below.

- Exhaustive switches over `NetworkConfigurationFailureReason` must handle
  `invalidPayload`. It reports codec/request validation failure without retaining
  user payloads or arbitrary encoder error text. The corresponding stable numeric
  classification is `NetworkErrorCode.configurationInvalidPayload`.
- The Stable JSON macro continues accepting conditional helpers, nested types,
  and explicit policy witnesses. As in 6.0, member-level conditional `body/query`
  declarations do not participate in payload inference; a warning now makes that
  limitation explicit without changing the generated wire contract. Use `#if`
  around the whole endpoint, or an unconditional `Parameter` + `parameters`
  pair, when the payload varies by configuration. A complete manual payload
  pair remains authoritative and receives no conditional-payload warning.
  Projects treating warnings as errors must apply one of those migrations;
  this is not new support for inferring conditional payloads.
- New encoded companion macros reject member-level conditionals, including
  inactive/nested branches. Use a whole-endpoint conditional or a manual
  `EncodedAPIDefinition`. These new factories must not silently skip copied
  payloads or policies. Conditional statements inside methods are unaffected.
- Escaped property names match unescaped path placeholders (for example, the
  Swift property named `class` matches `/{class}`). Generated references are
  qualified with `self`, so internal helper names cannot shadow endpoint values.
- Encoded endpoints support session bearer authentication and request signers.
  Named `RequestSecurityProviding` credentials are not supported by this boundary.
  A named `EncodedAPIDefinition` declaring that conformance fails with
  `RequestSecurityFailure.unsupportedExecution` before its request factory or
  transport runs, through both the client and operation routes. Use the existing
  `APIDefinition` or `MultipartAPIDefinition` credential integration when required.
- Coalescing shares only equivalent effective response limits. Different limits
  may cause separate physical requests; individual success/failure must not depend
  on which caller starts first. Client-wide response caps still apply.
- Corrupt persistent-cache numeric metadata triggers the existing cache-owned
  recovery boundary; unrelated files remain untouched. Valid entries have their
  accounted cost refreshed from body size and headers on reopen.
- Persistent-cache telemetry snapshots now contain one aggregate per eviction
  reason in first-observed reason order, not one event per chronological batch.
  Counts and byte totals saturate independently at `Int.max`; draining starts
  a new aggregation epoch without resetting lifetime statistics. Consumers must
  not interpret snapshot length as an eviction or batch count.
- Each persistent-cache directory has one active owner. Share the same actor
  inside a process, and use separate subdirectories for independent processes
  or extensions. Stop using the previous owner before reopening the same path;
  an App Group directory helper does not provide locking or shared-writer support.
- Invalid download log sequence values use the existing valid-prefix recovery
  transaction. An exhausted valid range is checkpointed durably and rebased
  before appending; no public task ID or lifecycle contract changes.

## Dependency graph compatibility

Core 6.1.0 requires SwiftSyntax `604.0.0..<604.1.0` and
Swift Crypto `5.0.0..<6.0.0`. The published 6.0.0 manifest allows SwiftSyntax
`603.0.1..<603.1.0` and Crypto `4.0.0..<5.0.0`. These ranges do not overlap.
Resolve a clean consumer graph before adoption, including every other package
that constrains these dependencies. `traits: []` removes compiled Core macros,
not SwiftPM's manifest dependency resolution. A local Core path override does
not remove another package's incompatible SwiftSyntax constraint either.

The Swift tools 6.2 and deployment-floor contract stays unchanged; the dependency
updates still require both supported compiler lanes and minimum-platform builds.
The current MacroSupport surface is minor-bound to Core 6.1 and SwiftSyntax
604.0.x. Companion macros must align that range and revalidate Debug/Release,
macro-disabled and JSON-coexistence consumers against the exact intended Core
revision. Do not infer that a retained Crypto 4 lock is an independent companion
manifest constraint: inspect the manifest and perform resolution first.

See [the dependency update evidence](DependencyIntegration-2026-10-02.md).
Core-only consumers do not need to adopt Protobuf or Stream. Those packages'
release and application-specific gates remain separate from Core publication.

## Operation client generic wrappers

`OperationNetworkClient` is Provisionally Stable. Its type-level `Base` bound
changes from `NetworkClient` to `Sendable` so binary-only clients can use the
same operation lifecycle. JSON `start` methods now require `Base: NetworkClient`
at the method level. Existing concrete JSON calls are unchanged, but generic
extensions/wrappers that previously inherited that bound must state it explicitly.

Before (6.0):

```swift
extension OperationNetworkClient {
    func startLogged<Request: APIDefinition>(_ request: Request) -> NetworkOperation<Request.APIResponse> {
        start(request)
    }
}
```

After (compiles with both 6.0 and 6.1):

<!-- compile-check -->
```swift
import InnoNetwork

extension OperationNetworkClient where Base: NetworkClient {
    func startLogged<Request: APIDefinition>(_ request: Request) -> NetworkOperation<Request.APIResponse> {
        start(request)
    }
}
```

Likewise, spell `Base: NetworkClient` on generic JSON forwarding functions.
For new binary-only wrappers use `Base: EncodedRequestClient`; do not require
JSON conformance merely to execute an encoded request.

The Core public-tag consumer evidence is recorded in the release notes. It does
not replace companion release gates or application-specific deployment checks.
