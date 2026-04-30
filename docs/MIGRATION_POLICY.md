# Migration Policy

## Stable API

- Stable API changes require a migration note when call sites or behavior must change.
- Behavior changes without source breakage should still be documented if they affect retries, websocket lifecycle, downloads, or observability.

## Provisionally Stable API

- These APIs may evolve faster, but changes still require release notes and updated examples.

## Internal / Operational

- Internal details are not migration-contract items.
- Changes to persistence file format, telemetry payloads, or reconnect taxonomy internals do not require public migration docs unless they affect documented behavior.

## Planned Major Changes

- The 4.0.0 release keeps Protocol Buffers support in the separate
  `InnoNetworkProtobuf` package.
- Consumers that rely on protobuf endpoints keep using `DefaultNetworkClient`,
  but must add a second package dependency and import `InnoNetworkProtobuf`.
