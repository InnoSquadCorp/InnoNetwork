# Encoded-request candidate migration

These notes describe the unpublished core 6.1 candidate, not a new publication
or a change to the released 6.0 tag. The macro-first Protobuf companion uses this
candidate; local consumer validation does not prove public dependency resolution.
The [candidate release notes](releases/6.1.0-encoded-request-candidate.md) are
separate from the older 6.1 roadmap record that was absorbed into core 6.0.

- Exhaustive switches over `NetworkConfigurationFailureReason` must handle
  `invalidPayload`. It reports codec/request validation failure without retaining
  user payloads or arbitrary encoder error text. The corresponding stable numeric
  classification is `NetworkErrorCode.configurationInvalidPayload`.
- Endpoint macros no longer accept member-level conditional compilation. A
  generated endpoint must have one visible contract: put `#if` around the whole
  declaration, or implement `APIDefinition` / `EncodedAPIDefinition` manually.
  This applies to inactive and nested branches as well as active payloads and
  policies. Conditional statements inside a method body are unaffected.
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

No new dependency version, release tag, deployment permission or remote CI result
is implied by these local corrections.
