# Version, dependency and product boundaries

The supported release line is stable **6.1.x** (`>=6.1.0, <6.2.0`). The validated
baseline is public InnoNetwork **6.1.0**, commit
`79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16`, with Swift tools 6.2 and Swift 6
language mode. Deployment floors are iOS/tvOS 16, macOS 14, watchOS 9 and
visionOS 1. This is Apple-platform Swift guidance, not Android/Web guidance.

The 6.1.0 manifest requires SwiftSyntax `604.0.0..<604.1.0`, Swift Crypto
`5.0.0..<6.0.0`, HTTP Types `1.6.0..<2.0.0`, and OpenAPI Runtime `1.0.0..<2.0.0`.
The fixture lock and [support record](support.json) preserve the actual resolved
revisions, including transitive ASN.1. Disabling `Macros` avoids compiling
Core macros; it does not remove dependency resolution.

For a different stable 6.1.x patch, compare the consumer's exact source/release
notes with this baseline for the APIs and products in use, including manifest
constraints and relevant behavior fixes. Preserve its resolved patch and validate
the changed consumer. The support record's `version` and `revision` identify
the tested baseline, while `supported_release_line` and `supported_range` declare
the intended scope. A planned or newly published 6.1.1 is in that scope once
stable and published, but receives its own validation evidence only after tests.
Adding a new validated baseline requires updating the exact fixture pins and
evidence together; a version-range declaration alone does not update them.

The previous 6.0 manifest used SwiftSyntax `603.0.1..<603.1.0` and Crypto
`4.0.0..<5.0.0`. A graph with another package requiring those old-only ranges
cannot resolve 6.1. Check actual manifests before changing them. InnoDI 7.0.0's
SwiftSyntax 604.0.0 requirement overlaps this release, but this skill's Core-only
fixture is not proof that a combined application or every companion resolves.

## Select only needed products

| Product | Boundary |
| --- | --- |
| `InnoNetwork` | JSON and encoded requests, operation handles, policy pipeline |
| `InnoNetworkTestSupport` | Public mocks/stubs in test targets only |
| `InnoNetworkDownload`, `InnoNetworkUpload` | File/background transfer; own manager, restoration and shutdown lifecycle |
| `InnoNetworkWebSocket` | Connection, heartbeat/reconnect and close lifecycle |
| `InnoNetworkPersistentCache` | Disk cache; one active owner per directory, no multiprocess shared-writer guarantee |
| `InnoNetworkOpenAPI` | Full-pipeline request adapter or thin generated-client transport; choose deliberately |
| `InnoNetworkAuthAWS`, `InnoNetworkTrust` | Opt-in signing/pinning, requiring application-specific acceptance |
| `InnoNetworkMacroSupport` | Compiler-host support, never an application runtime dependency |

The four HLS products moved to the independently versioned InnoStream package
in 6.0. Core 6.1 does not publish the Stream or Protobuf companions. Verify their
own public tags, manifests and consumer builds before suggesting their APIs.
Optional product ownership details are outside this fixture's validation;
read the exact release's product documentation when implementing them.

## Migration checks

Handle `.invalidPayload` in exhaustive configuration-failure switches.
Review JSON generic operation bounds, conditional macro payloads, encoded
credential support, and cache telemetry aggregation rather than assuming
minor-version source compatibility for Provisionally Stable APIs. Persistent
cache snapshots aggregate by eviction reason; length is not a batch count.

Some 6.1-tagged documents still call the release a candidate. The actual
[non-prerelease GitHub Release](https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.1.0)
was verified on 2026-10-07. Preserve the historical document context, and use
the exact source and resolved consumer as API evidence.

Sources:
[6.1 manifest](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/Package.swift),
[migration notes](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/docs/Migration-EncodedRequests.md),
[product guide](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/README.md#product-selection-guide).
