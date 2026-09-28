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
| provider execution boundary | PASS, `52e372f` | cancellation, origin, redaction, identity, sharing and signing order |
| API key | PASS, `52e372f` | missing/conflicting key, header then explicit query/cookie, redirects |
| OAuth scope | PASS, `ae19c7d` | exact scopes, unknown metadata, expiry, isolated refresh, no escalation |
| AND/OR authentication | PASS, `52e372f` / `ae19c7d` | atomic AND, explicit OR choice, anonymous alternative, retry identity |
| preserved JSON and bounded validator | PASS, `f00e430` | number precision, unknown fields, depth/work limits |
| named local-reference anyOf | implemented, focused validation below | zero/one/multiple matches, encode validation, typed views |
| final release preflight/consumers | pending | final revision, all local gates; remote/device gates separate |

Each generator stage requires parser diagnostics, deterministic output, actual
Swift typecheck and runtime tests, including failing cases and passing controls.
The optional proposal appendix (external refs, full 3.1, Basic/OIDC login,
non-JSON responses, etc.) is not implicitly claimed as implemented by these stages.

## External acceptance boundaries

### Named anyOf integration, 2026-09-28

Generated wrappers preserve every match, expose immutable JSON and throwing typed
views, and revalidate encoding. Strict OpenAPI 3.0 validation IR rejects unknown
constraints, non-boolean additionalProperties, ref siblings, formats and recursive
graphs. Nested models/arrays, API-key requests and 204 outputs use the preserved
codec. The generated fixture passes 4 actual URLSession/URLProtocol requests plus
zero/one/multiple-match, numeric-range and exact-body roundtrip checks; the legacy
credential fixture still passes 10 requests. Generated anyOf output is checked
twice for determinism and compiled in Swift 6 mode.

Integration found that custom decoder errors lacked promised response context.
`TransportPolicy.custom` now wraps unexpected errors as decoding failures, while
preserving cancellation and explicit NetworkError; focused tests cover all three.
The one new Stable encoding case brings the inventory to 1,691 / Stable 307 /
Provisional 1,351 / SPI 33; existing Stable declarations and macro are unchanged.
Logs: `/tmp/innonetwork6-anyof-output-final.log`,
`/tmp/innonetwork6-anyof-core-final.log`. Full final-revision gates remain separate.

A mixed-model follow-up aligns Date fields outside the anyOf validation subtree
with InnoNetwork's existing canonical formatted dates. The wire fixture includes
a `date-time` sibling to nested preserved values; it must decode and roundtrip
without switching existing JSON dates to Foundation reference-date numbers.
The initial full-preflight run began before this follow-up; final evidence must
identify the corrected revision rather than attributing that mixed run to one SHA.

### Preserved JSON foundation, 2026-09-28

Added the exact-byte document, document-aware Codable bridge, and bounded schema
subset in `docs/PRESERVED_JSON.md`. Twelve focused tests pass, including ordinary
Codable controls, nested raw subtrees, numeric/Unicode adversarial input, and
zero/one/multiple matches. Logs: `/tmp/innonetwork6-json-stage1-tests.log`.
The fresh symbol graph adds 34 Provisionally Stable declarations: total 1,690 /
Stable 306 / Provisional 1,351 / SPI 33. Generator anyOf and final release gates
remain pending; this does not renew consumer or external evidence.

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

## Second implementation batch: credential execution

Implementation commit: `52e372f`. Fresh local evidence on its source tree:

- Root bounded suite: 1,868 registered, 1,864 passed, four live-only tests skipped.
- Focused credential/adjacent regressions: 68 tests passed; macro suite: 54 passed,
  including the Stable macro's manual-payload contract with a named credential.
- Generator suite: 31 passed; generated output typechecks and executes six
  API-key/AND/OR requests, with identical output on the second generation.
- Static contracts, formatting, release-state negative fixtures and documentation
  helper fixtures passed. All nine public product DocC archives built and passed
  the archive contract, including the new request-credentials article.

Logs: `/tmp/innonetwork6-credential-full-tests-final.log`,
`/tmp/innonetwork6-credential-last-regression.log`,
`/tmp/innonetwork6-credential-macro.log`,
`/tmp/innonetwork6-credential-generator-tests-final.log`,
`/tmp/innonetwork6-credential-generated-final.log`,
`/tmp/innonetwork6-credential-static.log`,
`/tmp/innonetwork6-credential-docc.log`. Logs are local ephemeral artifacts,
not remote CI or a substitute for the remaining live acceptance gates.

The new opt-in provider boundary leaves Stable `SessionAuthentication` and
`@APIDefinition` unchanged. It adds 33 Provisionally Stable declarations:
1,649 total / 306 Stable / 1,310 Provisional / 33 SPI. The API budget, enum
guard, declaration ledger, release-state assertions and negative fixtures all
track this explicit addition; historical earlier-stage counts remain historical.

Selection is owned by one logical request and retained across retries. Secrets
are acquired only after local admission, injected atomically, then signed in
the existing configuration-before-endpoint order. HTTPS origin, frozen
principal/realm, duplicate slots and overlapping legacy/default session auth
fail closed. Provider/signer failure descriptions are discarded. Native
authentication challenges cannot select a second authentication method.

The API-key stage includes header and explicitly enabled query/cookie placement.
The same execution primitive now supports API-key/bearer AND and explicit OR,
including an explicitly selected anonymous alternative. OAuth combinations are
still pending, not silently rendered as bearer. New credential requests bypass
cache/coalescing/URLCache, cookie jars and all automatic redirects. Authenticated
sharing is intentionally not implemented in this stage.

| Validation boundary | Evidence |
| --- | --- |
| normal header/query/cookie and AND/OR | new runtime tests plus six generated requests through native URLSession/URLProtocol |
| missing/invalid credentials, partial AND, slot conflicts, invalid selection | no-dispatch assertions and passing controls |
| account change, retry, origin mutation | fixed selection, per-attempt acquisition, identity/origin rejection |
| cancellation/admission/resource ceilings | cancelled provider cannot dispatch; queued request has no credentials; name/group/value limits |
| observation and VCR | unsigned public request, redacted response URL, dynamic cassette fields, sanitized error text |
| execution surfaces | buffered/multipart succeed; streaming rejects before provider selection |
| native session defaults | conflicting Authorization/Cookie/custom-key defaults rejected before native tasks |
| generated contract | inherited/overridden security, explicit opt-ins, actual typecheck, six-request runtime, byte-identical second output |

Application callbacks are trusted. In particular, raw Foundation metrics can
contain wire request snapshots; metrics reporters must scrub them. VCR response
bodies are not arbitrary secret scrubbers: do not record sensitive/credential-
echoing payloads. These limitations are part of the DocC contract, not claimed
as redacted by the field-name mechanism.

At the end of this batch, the next stage was OAuth scope/expiry metadata and
isolated refresh, followed by bounded preserved JSON and named local-reference
`anyOf`. This batch is
not the final release validation and does not refresh the earlier app/device/
service/platform evidence. No push, merge, tag or Release is implied.

## Third implementation batch: scoped OAuth

Implementation commit: `ae19c7d`.

Adds `.oauth2(id:scopes:)`, defaulted granted-scope/expiry metadata on opaque
credentials, and the optional `OAuthCredentialRefreshing` protocol. Unknown,
malformed or insufficient grants fail before transport. Scope spelling is exact;
server-suggested scopes never replace the declared requirement. The library does
not decode a JWT as proof of permission or launch login UI.

Expired tokens can renew once per logical request. The same one-renewal budget
also bounds reactive GET/HEAD replay after one unambiguous `401` Bearer
`invalid_token` challenge. Unsafe methods, ambiguous challenges and insufficient
scopes do not trigger automatic replay/escalation. Identity and expiry are
checked again after renewal, other AND members and asynchronous signers.

Overlapping renewal work shares only within a reused `RequestSecurity` value,
partitioned by scheme, exact scopes, realm and principal. Origin/provider are
fixed by the owning configuration. The coordinator retains no completed token
cache and bounds work to 64 groups/128 waiters per group. Waiter cancellation
does not cancel peers; the final cancellation cancels the provider task. Apps
still coordinate refresh-token rotation across independent configurations and
own token persistence, IdP-wide cooldown and issuer/audience attestation.

The public budget increases by seven to 1,656 total / 306 Stable / 1,317
Provisionally Stable / 33 SPI. The unreleased credential initializer gains
defaulted metadata arguments, preserving existing source calls. Stable
`@APIDefinition` and legacy session authentication are unchanged.

Fresh verification:

- 41 focused tests across scoped OAuth, named credentials, existing realm auth
  and request signing passed. They include missing metadata, exact scope case,
  wrong identity, secret-safe failures, expiry during signing, one-renewal budget,
  quoted-header parser attacks, cancellation isolation and both concurrency caps.
- Root bounded suite: 1,879 registered, 1,875 passed and four live-only skipped.
- 31 generator tests passed. Generated source typechecks, is byte-identical
  across two runs, and executes ten native URLSession/URLProtocol requests,
  including OAuth+API-key AND, explicit OAuth OR and a 401/renewal/replay sequence.
- The complete static-contracts gate passed, including public API/docs budgets,
  enum ledger, trait builds and negative macro fixtures. Release-state negative
  fixtures passed. All nine public product DocC archives built and passed the
  archive contract with the scoped OAuth documentation.

Logs use `/tmp/innonetwork6-oauth-` with suffixes `tests.log`, `full-tests-final.log`,
`generator-final.log`, `generated.log`, `static.log`, `release-fixtures.log` and
`docc.log`. Final formatting also passed (`lint-final.log`, 492 Swift files).
These are local, ephemeral evidence, not real IdP acceptance or CI.

Next: preserved JSON/validator, named local-reference `anyOf`, then the complete
final-revision release preflight and consumer matrix. Physical-device/service
acceptance and remote publication remain separate gates; no push or release
is authorized by this batch.
