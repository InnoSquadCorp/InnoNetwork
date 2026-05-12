# Migration Policy

## Stable API

- Stable API changes require a migration note when call sites or behavior
  must change.
- Behavior changes without source breakage should still be documented if they
  affect retries, websocket lifecycle, downloads, or observability.

## Provisionally Stable API

- These APIs may evolve faster, but changes still require release notes and
  updated examples.

## Internal / Operational

- Internal details are not migration-contract items.
- Changes to persistence file format, telemetry payloads, or reconnect
  taxonomy internals do not require public migration docs unless they affect
  documented behavior.

## Future Major Releases

- Future major releases may change stable surfaces. When
  they do, the release notes must include before/after call-site examples for
  every breaking change and any behavior change covered by this policy.
- Behavior-only changes that do not break call sites still require release
  notes when they affect resilience, websocket lifecycle, downloads, or
  observability.
- The 4.x line keeps the full `NetworkConfiguration.init(...)` initializer
  public for source compatibility, but the direct initializer is deprecated.
  New code should use `safeDefaults(baseURL:)`,
  `recommendedForProduction(baseURL:)`, `advanced(baseURL:resilience:auth:observability:cache:transport:)`,
  configuration packs, or fluent modifiers instead. A future major may remove
  the direct initializer; that migration requires explicit before/after
  examples for every initializer argument that no longer maps one-to-one.
