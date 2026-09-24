# 6.0 OpenAPI extension execution

Baseline: `65c3acf`, approved 2026-09-25. Existing local release-hardening
commits and unrelated consumer work are preserved. This scope is implementation,
not publication approval. Generator output remains Preview; `@APIDefinition`
remains Stable. New runtime contracts begin Provisionally Stable.

## Design and scope

Problem: the current generator erases security scheme identity, scopes and
AND/OR selection. Codable decoding alone cannot validate `anyOf` semantics.
Constraints: preserve legacy bearer behavior; never generate credentials or
silently downgrade authentication; bound schema validation; keep unknown JSON.

Alternatives: endpoint interceptors alone cannot enforce identity and sharing
boundaries. Changing Stable `SessionAuthentication` would couple legacy callers
to new scheme selection. Use a separate opt-in contract and a security IR.
For `anyOf`, a first-success enum loses multiple matches; use preserved JSON
with validated views and a documented schema subset instead.

Failures must be explicit before transport where possible, contain no secrets,
and never trigger an anonymous/account fallback. Unsupported schema constraints
must fail generation, not be silently ignored.

## Ordered work and evidence

| Stage | Status | Required verification |
| --- | --- | --- |
| enum ledger repair | PASS, `3631a27` | provisional enum ledger check |
| six WatchKit consumer migrations | PASS, isolated commits below | all six full app builds, executable/plist checks, simulator install/launch |
| current Appbyul dependency migration | PASS, consumer `959f72b` | full iOS app build, CoreNetwork 20 + tabs 3 tests, DI/layer/localization, simulator launch |
| security IR | PASS, `c453d55` | 29 generator tests, typecheck, runtime roundtrip, two-run identical output |
| provider execution boundary | pending | cancellation, origin, redaction, identity, sharing and signing order |
| API key | pending | missing/conflicting key, header then explicit query/cookie, redirects |
| OAuth scope | pending | exact scopes, unknown metadata, expiry, isolated refresh, no escalation |
| AND/OR authentication | pending | atomic AND, explicit OR choice, anonymous alternative, retry identity |
| preserved JSON and bounded validator | pending | number precision, unknown fields, depth/work limits |
| named local-reference anyOf | pending | zero/one/multiple matches, encode validation, typed views |
| final release preflight/consumers | pending | final revision, all local gates; remote/device gates separate |

Each generator stage requires parser diagnostics, deterministic output, actual
Swift typecheck and runtime tests, including failing cases and passing controls.
The optional proposal appendix (external refs, full 3.1, Basic/OIDC login,
non-JSON responses, etc.) is not implicitly claimed as implemented by these stages.

## External acceptance boundaries

A connected development iPhone, dedicated resumable/quota/IdP services and an
actual exporter/collector are still required. Mock results do not close these
gates. Final-SHA CI requires publishing a validation branch/PR. No tag, Release,
main merge or secret provisioning is performed by this implementation work.

Late recheck on 2026-09-25: the physical iPhone changed from unavailable to
connected/paired, running iOS 27.0 with Developer Mode enabled. Installation of a
separate test app was requested, not performed.
This changes the prerequisite status, not the acceptance-test result.

## First implementation batch evidence

`3631a27` repairs the missing `ResponseCachePolicy.requestFreshness` enum ledger
entry. The complete `static-contracts` stage was rerun on `c453d55` and passed,
including API/docs inventory, trait builds and negative macro fixtures. This is
not a new all-14-gate release preflight.

`c453d55` adds a non-secret IR with API-key placement, exact OAuth scope names,
OR alternatives and deterministic AND members. It rejects malformed/over-budget
metadata and credential-slot collisions. The legacy renderer now refuses distinct
bearer identities instead of merging them. Extended security still fails closed
at rendering until the provider execution boundary is implemented. No new public
runtime symbols or credential injection are shipped by this commit.

Evidence logs: `/tmp/innonetwork6-static-contracts-fixed.log`,
`/tmp/innonetwork6-security-ir-tests-final.log`,
`/tmp/innonetwork6-security-ir-generated.log`,
`/tmp/innonetwork6-security-determinism.log`. Generator tests include passing
legacy controls and invalid scopes, origins, header collisions and resource limits.

## Consumer migration evidence

Watch consumers use isolated worktrees under
`/private/tmp/innonetwork6-consumers.wPbrCm/<name>-local`, each on
`codex/network6-watch-single-target`. Canonical consumer directories, including
dirty PRDs/brainstorms, were not edited. Existing temporary `Package.resolved`
changes were preserved outside the template commits. Validation therefore uses
the source commit plus that previously resolved dependency graph, not a claim of
remote-main acceptance.

| Consumer | Template commit | Full iOS app build | watchOS 27 install/launch |
| --- | --- | --- | --- |
| Bora | `47ac952` | PASS | PASS |
| CargoAirline | `d6c7688` | PASS | PASS |
| Circe | `ed8d88b` | PASS | PASS |
| Echo | `4ae7482` | PASS | PASS |
| Huginn | `a0d2a25` | PASS | PASS |
| Ithaca | `39508b7` | PASS | PASS |

The old WatchKit extension executable/resources/dependencies moved into a single
watchOS `.app`, retaining the watch app bundle ID, display name and companion ID.
Built plists contain `WKApplication`, not the legacy `WKWatchKitApp` or extension
configuration. No Watch feature was removed to obtain a green iOS build. This
follows [Apple's single-target migration](https://developer.apple.com/documentation/watchos-apps/migrating-to-a-single-target-watchos-app).
Signed device upgrade/data migration remains a separate acceptance test.

Latest Appbyul has its own clean worktree:
`/Users/changwooson/Developer/InnoSquad/Projects/Appbyul-network6-release-prep`,
branch `codex/network6-current-appbyul`, commit `959f72b`. InnoDI 5.1.0 / InnoFlow
5.1.1 / InnoRouter 5.2.1 resolve with SwiftSyntax 603.0.2. It preserves the current
renamed app's purchases, authentication and storage sources. Additional integration
fixes cover v6 error logging, actor isolation, C++ runtime linkage, dependency SDK
floors and the pinned Tuist 4.206.0 invocation. See that worktree's
`apple/NETWORK6_MIGRATION.md` for the complete evidence and unverified boundaries.

App and watch builds used the `65c3acf` runtime archive. `git diff 65c3acf c453d55
-- Sources` is empty: this batch changes root release metadata and the standalone
generator only. Default Appbyul remote dependency resolution separately passed at
the pinned `7b52580`; the new 6.0 public tag does not exist yet.
