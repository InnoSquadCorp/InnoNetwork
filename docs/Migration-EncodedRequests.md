# Encoded-request candidate migration

These notes describe the unpublished core 6.1 candidate, not a new publication
or a change to the released 6.0 tag. The macro-first Protobuf companion uses this
candidate; local consumer validation does not prove public dependency resolution.
The [candidate release notes](releases/6.1.0.md) are separate from the
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

After (compiles with both 6.0 and this 6.1 candidate):

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

No new dependency version, release tag, deployment permission or remote CI result
is implied by these local corrections.
