# Migration Policy

## Stable API

- Stable API source-breaking or documented behavior-breaking changes require a
  major release and a migration note.
- Behavior changes without source breakage should still be documented if they
  affect retries, websocket lifecycle, downloads, or observability.

## Provisionally Stable API

- These APIs may evolve faster. Shape or behavior changes can ship in a minor
  release only with release notes, a migration note, and updated examples.

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
- The full `NetworkConfiguration.init(...)` initializer was removed from the
  public API before the 4.0.0 baseline, so it is not part of the 4.x source
  compatibility promise. New code should use `safeDefaults(baseURL:)`,
  `recommendedForProduction(baseURL:)`, `advanced(baseURL:resilience:auth:observability:cache:transport:)`,
  or configuration packs. The deprecated fluent modifiers were removed in
  5.0.0 with a field-by-field mapping in `Migration-5.0.0.md`.
