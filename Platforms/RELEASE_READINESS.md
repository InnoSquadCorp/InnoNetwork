# Android / Web 1.0.0 readiness record

Assessment date: 2026-10-18 KST. Swift baseline: `ac0363674c974b8fd0423f29d17ea7791d28dbcb`.
Cross-platform changes live on `feature/cross-platform-network-sessions`.
This is an installable local 1.0.0
candidate, not evidence of public Maven Central/npm publication. The root Swift
manifest, lockfile, sources, and tests remain equal to `origin/main`.

## Scope and exit criteria

The review covers Android's native session, typed client, KSP, and optional JSON
adapter; Web's native Fetch session/client; public API/ABI and package contents;
independent consumers; React lifecycle; and CI/release checks. Exit criteria are
reproduced defects fixed with passing controls, portable gates passing against
unchanged source, real installed-artifact execution, and explicit qualifications
for platforms or release operations not verified locally.

Swift runtime changes, full Swift feature parity, app-owned auth/refresh/replay,
background restoration, WebSockets, persistence, and React Native are excluded.
Native OkHttp/Fetch configuration remains the application boundary for TLS,
timeouts, cache, cookies, credentials, interceptors, and observability.

## Swift CodeQL completion contract — 2026-10-18

This follow-up was scoped before examining the remaining analysis result.
It verifies the existing run, not a new Swift implementation or release.
Documentation may be updated locally; no Swift source, test, manifest,
dependency pin, compiler flag, query suite, or Swift workflow step will be
changed to obtain a green result. A failure is investigated before any fix is
proposed. Do not cancel or replace the active build merely to speed this review.

### Frozen identities and inventory

- Worktree: `InnoNetwork-cross-platform`; branch
  `feature/cross-platform-network-sessions`; initially clean.
- Analysis subject and remote branch at verification closure:
  `942d3f8f65c6a50823015438bd4d607cb2f88964`.
- Remote `main` at verification closure / Swift comparison baseline:
  `ac0363674c974b8fd0423f29d17ea7791d28dbcb`.
- Existing [CodeQL run 39103447150](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/39103447150),
  attempt 1, `workflow_dispatch`; Swift job `117604339946`.
- Configured environment: `macos-15`, Xcode `26.0.1`, 60-minute job limit,
  CodeQL action `24c54180a607b1449ed407dd24f251e4e9147c8d`.
  Observed runner: macOS `15.7.9` (`24G830`), image
  `macos-15-arm64` / `20260907.0337.1`, runner `2.337.0`.
  The selected toolchain reports Apple Swift `6.2`
  (`swiftlang-6.2.0.19.9`, clang `1700.3.19.1`), target
  `x86_64-apple-macosx15.0`, and driver `1.127.14.1`.
  Preserve the observed image/target distinction; SDK version was not printed
  separately and is not inferred from the runner label.
- Executed Swift command: `xcrun swift --version` then `xcrun swift build`;
  default `Macros` trait; analysis suites `security-extended` and
  `security-and-quality`; SARIF category `/language:swift`.
- Runtime product inventory: `InnoNetwork`, `InnoNetworkAuthAWS`,
  `InnoNetworkDownload`, `InnoNetworkUpload`, `InnoNetworkWebSocket`,
  `InnoNetworkPersistentCache`, `InnoNetworkOpenAPI`, `InnoNetworkTrust`, and
  `InnoNetworkTestSupport`. Compiler-only support: `InnoNetworkMacroSupport`
  and the `InnoNetworkMacros` target. Verify observed extraction coverage
  rather than assuming the manifest inventory was fully analyzed.
- Source inventory: 250 tracked Swift files under `Sources`: 244 compilable
  files across those 11 targets and six DocC tutorial resources. There are
  556 tracked Swift files repository-wide, including 245 under `Tests`,
  30 under `Examples`, 19 under `Tools`, seven under `SmokeTests`, three
  under `skills`, one benchmark and the manifest. Inventory is not an
  extraction or executable-test claim; reconciliation follows below.

### Required evidence matrix

| Row | Check / passing condition | Evidence / follow-up status |
| --- | --- | --- |
| S1 — source preservation | All tracked `*.swift`, `Sources`, `Tests`, `Package.swift`, and `Package.resolved` match exact remote `main`; no local Swift edits | Fresh full Git comparison against `ac036367`: empty; both package files tracked; original checkout unchanged |
| S2 — configuration parity | Swift job's runner, Xcode, permissions, build command, query suites and action pins equal the baseline job | Fresh complete `jobs.analyze` block comparison: identical except irrelevant empty separator lines |
| S3 — checkout / chronology | Run attempt, event, job and uploaded analysis belong to subject SHA; old/cancelled attempts cannot establish success | Fresh run/job/analysis binding to `942d3f8f`; Swift job 06:16:58–06:45:14 UTC; attempt 1, not cancelled/skipped |
| S4 — build / extraction | Build completes successfully; record actual compiler, CLI, dependency revisions, targets and extraction warnings/coverage | Fresh completed log: build success 06:43:43 UTC, all 244 eligible package sources have compiler-log matches; CodeQL reports 253/556 files and zero unresolved AST nodes; one distinct baseline compiler warning, detailed below |
| S5 — queries / SARIF | Analysis and upload complete; matching analysis has no execution error; record query counts and results | Fresh analysis `1975038299`, CodeQL `2.27.2`, 28 catalog rules / 1 result / empty execution error; SARIF processing complete with no upload errors, detailed below |
| S6 — findings | Inspect results and current open alerts on the exact branch/SHA; distinguish scanner findings from workflow failures | Fresh normalized SARIF and alert #12 inspected: one high-severity password-hashing claim, static verdict `not_actionable` / high confidence because both input paths contain public keys, not passwords; alert remains open |
| S7 — language aggregate | All three CodeQL jobs and the parent run conclude successfully on the subject SHA | Fresh closure snapshot: Swift, java-kotlin, javascript-typescript jobs and parent all `success`; Java/Kotlin and TypeScript analyses report zero results |
| S8 — cross-platform controls | Preserve the exact-SHA five-job Cross-platform pass, three browser engines, 40 Android / 37 Web / 9 React tests and packed consumers | Reused passing execution `39103431000`; freshly read Android/browser/tarball/React logs and all five job conclusions; not a new device run |
| S9 — failure attribution | If failed, retain exact first failure, command, tools, dependency identities and logs; compare subject and clean baseline under equivalent conditions | Not triggered: no workflow/build/query/upload failure. The scanner claim and compiler warning are separately attributed below; no speculative patch or redundant baseline build was made |
| S10 — preservation / handoff | Remote main rechecked; only scoped documentation changes; original checkout preserved; evidence and exclusions reconciled | At verification closure, fresh remote API and Git checks: main `ac036367`, HEAD/remote feature branch both `942d3f8f`, ahead/behind `0/0`; only this document modified locally before the separately authorized documentation publication; original checkout's ahead-6/behind-37 and two untracked generated directories preserved |

If S4 or S5 fails, first separate runner/setup, dependency resolution, compiler,
extractor, query, resource/time-limit, upload/permission and cancellation causes.
The baseline control must use the same Swift command, Xcode/Swift, dependencies
and CodeQL settings in an isolated checkout or an exact-baseline remote run.
An old main success or identical source alone does not prove equal execution
conditions. Record different failure signatures separately. Re-run only when
it tests a concrete hypothesis; do not repeatedly re-run a deterministic failure.
Do not change the Swift implementation, silence findings, lower query coverage,
increase limits or dismiss alerts as part of diagnosis.

### Completed build, extraction and query evidence

The Build step ran 06:17:15–06:43:43 UTC (26m28s), including dependency
resolution and tool invocation; SwiftPM itself reported `Build complete!
(1274.32s)`. Analysis ran 06:43:43–06:45:04 UTC. Neither step timed out.
Dependency versions observed in the log match the unchanged lockfile:

| Dependency | Version | Pinned revision |
| --- | --- | --- |
| swift-asn1 | 1.7.1 | `a9a5efd40eaf558a2bcd48d64b1d1646be686008` |
| swift-crypto | 5.0.0 | `a9d1d5ab8951ada40cafff8c8e2b551dfde4f390` |
| swift-http-types | 1.8.0 | `bff4b6903cdc99dda49649dd52f46c11cfd3ed50` |
| swift-openapi-runtime | 1.13.0 | `50ad7976f18fec6c09466d2aebf7be3dc9476cfb` |
| swift-syntax | 604.0.0 | `050f1a346fbbac0ca2cfb15a95274f7bd1cf0ccf` |

Remote resolution printed versions, not checkout commit hashes; the revisions
above are the subject's tracked lockfile identities, not a separately collected
remote checkout-hash receipt.

| Package target | Eligible tracked files | Observed compiler matches |
| --- | --- | --- |
| InnoNetwork | 130 | 130 |
| InnoNetworkAuthAWS | 1 | 1 |
| InnoNetworkDownload | 43 | 43 |
| InnoNetworkMacroSupport | 7 | 7 |
| InnoNetworkMacros | 2 | 2 |
| InnoNetworkOpenAPI | 2 | 2 |
| InnoNetworkPersistentCache | 10 | 10 |
| InnoNetworkTestSupport | 7 | 7 |
| InnoNetworkTrust | 1 | 1 |
| InnoNetworkUpload | 11 | 11 |
| InnoNetworkWebSocket | 30 | 30 |
| Total | 244 | 244 |

This reconciliation matches target + source basename against the completed
compiler log; it is not a per-file CodeQL extraction report. Six DocC resource
snippets are excluded from compilable package sources. SwiftPM additionally
compiled smoke/benchmark executables and generated resource accessors, but did
not execute those programs. CodeQL's own aggregate is **253 of 556 Swift files**
(about 45.5% of repository inventory), 1,501,530 extracted AST nodes and zero
unresolved AST nodes. These measurements must not be restated as full-repository
or full-platform coverage. The log reports two raw diagnostic messages without
their bodies; the normalized SARIF export does not retain the per-file
extraction/diagnostic detail, so that detail remains unverified.

CodeQL CLI `2.27.2` used `codeql/swift-queries` `1.3.12`
(`a7057b836bf29767461026718b14d20790b9085f`). The log shows 30 completed
evaluations: 25 security queries and five diagnostic/metric queries. GitHub's
normalized SARIF/analysis catalog reports 28 rules (25 security and three metric
entries); this catalog count is not the same as the query-execution count.
Analysis `1975038299`, category `/language:swift`, records the exact branch and
subject SHA, one result and empty execution error. SARIF upload
`6fadcc52-cabf-11f1-9fd0-6e373f76165e` reports `processing_status: complete` and
`errors: null`; the job log independently confirms completed processing at
06:45:04 UTC. The parent run completed successfully at 06:45:15 UTC.

### Scanner finding, compiler warning and disposition

- **Reported scanner finding:** [open alert #12](https://github.com/InnoSquadCorp/InnoNetwork/security/code-scanning/12),
  `swift/weak-password-hashing`, security severity high / 7.5, result level
  warning, at `Sources/InnoNetworkTrust/PublicKeyPinning.swift:361`.
  The SARIF calls the output of `SecKeyCopyExternalRepresentation` at line 303
  a password. Both reported flows were traced: raw public-key bytes at 306,
  and their SPKI DER at 311–316, reach private `pinHashes` at 360–363.
  `SecCertificateCopyKey` at 302 obtains a certificate **public key**, confirmed
  against Apple's Security SDK contract; those are the private sink's only two
  production callers, for both supported pin scopes. The digest is a public-key
  fingerprint used in pin-set intersection, not a stored password verifier.
  Static triage verdict: `not_actionable`, high confidence, no exploitability
  rank. The source policy was resolved first; no dynamic security validation or
  unrelated vulnerability discovery was performed. This does not certify the
  complete TLS/pinning implementation. The same alert occurs on exact main
  `ac036367`; existing-main provenance alone is not the reason for the verdict.
  No Swift fix, suppression, dismissal, upstream report or external message was
  made. CodeQL's internal source-model implementation was not inspected.
- **Observed compiler warning:** `Sources/InnoNetwork/NetworkMonitor.swift:134`
  emits `switch must be exhaustive`, with a note to add `.vpnInactive`.
  The existing `#if compiler(>=6.4)` case is excluded by this Swift 6.2
  toolchain. The file is byte-identical to main, `@unknown default` remains,
  and this is a warning rather than the cause of a failed job. Its future
  toolchain/runtime implications require separate main-branch review; no
  change or runtime-resolution claim is made here.
- **Confirmed execution failure:** none in the subject CodeQL run.
  **Unresolved candidates:** no additional imported scanner inputs; the
  warning's runtime/toolchain implications were not tested. **Optional work:**
  maintainer-approved false-positive disposition/model report and a separate
  main-branch warning review. **Unverified boundaries:** listed below, including
  uncompiled platform branches and the rest of the repository inventory.

The static triage contract and GitHub-normalized SARIF are retained outside the checkout
in Codex Security's managed artifact collection
`InnoNetwork-cross-platform/artifacts-6a5181cffd49fb14dd8e2975cd57d6ec7f35b0e5710e44c10c98bed18e20a12d/artifacts/swift-codeql-12/`.
It contains `triage.json` (`triage-finding/v0`), `triage.md`, normalized
`analysis-1975038299.sarif`, alert/instance snapshots, resolved policy, static
source trace and Apple SDK public-key contract. The report does not change
GitHub's still-open alert state.

### Explicit exclusions and exit criteria

This is not a fresh full Swift unit/integration, TSAN, benchmark, five-Apple-OS,
device, background-restoration, macro-E2E, or live-service acceptance run.
`swift build` and static analysis do not prove runtime cancellation, race
freedom, performance, external authentication or all-product feature behavior.
File extraction counts do not establish branch coverage: macOS compilation
does not validate iOS/tvOS/watchOS/visionOS-only conditional implementations.
Sibling Stream/Protobuf packages and public Maven/npm publication, signing,
provenance, tags and releases are excluded. Previous Android/browser/device
checks remain separately dated evidence; known Chromium telemetry and macOS
Firefox qualifications are retained.

Close every row with fresh evidence, explicitly reused evidence, or a concrete
limitation. Completion means exact-subject CodeQL success with preserved Swift,
or a documented failure and evidence-backed cause/remaining uncertainty handed
back without a speculative Swift patch. A cancelled, skipped, missing or
unuploaded Swift analysis is not a successful validation. Any newly changed
remote main must be reported rather than silently redefining this frozen run.

Evidence is retained locally under
`output/swift-codeql-942d3f8f.WrvGhc/`: frozen run/job/analysis JSON, revision
identities, the empty Swift-main diff, scope patch and source-checksum results.
The completed Swift log, run/job/analysis/upload snapshots and
`compiler-source-reconciliation.json` are retained there as well.
GitHub's normalized Kotlin/TypeScript SARIF exports were also read and contain
zero results. Their rule catalogs live under `tool.extensions`, not
`tool.driver.rules`; absent driver rule arrays are not interpreted as zero
rules executed. Rule counts, semantic tool versions, provenance and execution
status are cross-checked against analysis metadata and original job logs.
Swift's normalized SARIF and triage are in the managed collection above.
Only this readiness document changed in the follow-up. Fresh local checks passed:
`bash Scripts/check_docs_contract_sync.sh`,
`python3 Scripts/check_current_readmes.py`,
`python3 Scripts/tests/test_current_readmes.py` (six tests), and
`git diff --check`. These are documentation regression checks, not a fresh full
Swift runtime test run. The verification pass itself made no commit, push,
merge, tag, registry publication or GitHub alert mutation.

### Separately authorized documentation publication — 2026-10-18

The subsequent publication request covers only this readiness document on
`feature/cross-platform-network-sessions`. Swift source, tests, manifests,
dependency pins and workflows remain unchanged. The CodeQL and browser evidence
above remains bound to `942d3f8f`, not relabeled as a fresh execution against the
later documentation-only commit. Publication identity and remote parity are
reported from Git history and the handoff; this does not authorize a release,
tag, registry publication or alert dismissal.

Before publication, the documentation-contract gate, six README checker tests
and `Scripts/check_cross_platform.sh` passed again. The portable gate permits
Gradle up-to-date/cache reuse; this is not a claim that every Android test was
newly executed. Browser engines and CodeQL were not rerun for the document-only
change; their exact-subject evidence remains separately identified above.

## Main integration and layout preflight — 2026-10-18

The subsequent request authorizes the cross-platform PR and main merge, not
registry publication or a Swift release. The protected Swift baseline remains
`ac0363674c974b8fd0423f29d17ea7791d28dbcb`; root Swift files, manifest, lockfile,
targets/resources and package entry point are preserved. Instead of moving
SwiftPM into a platform subdirectory, [native layout and releasing](RELEASING.md)
records the compatibility decision and independent release paths. This is a
local, reversible layout/check change; that focused document and the PR carry
the design rather than a separate broad architecture proposal.

The layout checker and positive/negative controls validate canonical roots,
Android modules/composite/preview paths, npm package metadata/entry points,
Web/React consumer paths and licenses. Portable validation and every Android/Web
CI matrix leg invoke them; the local bundle includes their exact source hashes.
They are static checks of this repository's declaration conventions, not a full
Gradle/Swift parser or a substitute for installed-artifact execution.

Fresh local `xcrun swift test` completed successfully on Xcode 27 / Swift 6.4
without Swift edits. Cross-platform source run
[39108007778](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/39108007778)
at `165b97fb` also passed all five jobs, including three native browser engines
and React lifecycle tests, before the layout-only follow-up. That previous run
is not relabeled as validation of the later layout checker. Exact PR-head CI,
local package bundles and merge identities must be read from their own receipts
and PR checks; Swift CodeQL findings/qualifications above remain separate.

## Confirmed corrections in the cross-platform implementation

- Buffered Android callback exceptions now settle the suspended caller. Bodies
  close before result delivery, cancelled calls do not read late responses, and
  already cancelled coroutines do not create native calls.
- KSP emits collision-safe names/imports, handles default and keyword packages,
  diagnoses inaccessible properties, preserves trailing slashes, and accepts
  native `RequestBody` subtypes. Literal/runtime dot-segment guards remain.
- Web ceilings use decoded bytes rather than compressed wire length. Bodyless
  HTTP responses work even when an engine exposes an empty non-null stream.
  A size failure does not wait indefinitely for a stream's cancellation hook.
- Pre-aborted/late-resolved requests and async decoder cancellation retain the
  cancellation contract; obsolete decoded results are not delivered.
- Node-only consumers no longer require DOM-only type names. Real tarballs
  include resolvable source maps. Maven binaries, sources, and docs embed the
  current license, checked against the repository license.
- Wrapper integrity is checked before execution. Test-count gates exclude
  skipped tests and reject failed/error results. The independent Android
  consumer builds an actual API-21-targeted R8-minified APK.
- Android typed decoding is main-safe by default through an injectable
  dispatcher, with a retained two-argument constructor and cancellation tests.
  A real TanStack Query consumer now covers typed queries, deduplication,
  freshness, signal forwarding and HTTP rejection without hidden retries.

The preceding pass's redaction, origin-scoped default-header redirect guard,
bounded buffering, immutable buffered data, and native request escape hatches
are retained and included in the regression gates.

## Validation matrix

| Boundary | Evidence | Result / limit |
| --- | --- | --- |
| Normal HTTP and typed decoding | Android 17 transport, 7 client, 3 serialization tests; Web 37 tests | Fresh local checks |
| I/O, status, decoding failure | Native MockWebServer and Fetch fixtures; custom callback read/close failures | Caller settles; HTTP failures stay values until explicitly rejected |
| Cancellation and ownership | Awaiting headers, body buffering, pre-cancel, late response, stream handoff race, async decoder abort | Fresh controlled and native checks |
| Concurrency and React replacement | 8 concurrent Android requests; React StrictMode, unmount, input replacement, invalid payload; real TanStack Query | Android runtime and 9 React tests |
| Resource limits | Declared/chunked bodies, gzip, one-byte chunks, empty HEAD stream, never-settling cleanup | Bounded buffered path; streaming remains caller-owned |
| KSP authoring | 5 parser tests; 8 Maven-consumer tests; deterministic negative diagnostics | Packages/names, native body subtypes, trailing slash, dot segments covered |
| Observability and security | Native EventListener/Fetch injection, URL redaction, separate redirect destination with zero requests, dependency verification | No custom TLS stack or exporter claim |
| Compatibility and artifacts | JVM signatures, Kotlin ABI, explicit API, lint, Maven structure/license/checksums, packed npm declarations/runtime | Fresh local checks; no registry signature/provenance claim |
| Android packaging/runtime | Exact-head API-21-targeted D8/R8 APK; earlier actual API 26 emulator execution | Earlier KSP, JSON, concurrency, gzip, limit, stream and cancellation checks passed before final dispatcher/fixture follow-ups; exact-head device execution and API 21-25 execution unverified |
| TypeScript/runtime consumers | TypeScript 7.0.2, DOM and Node-only projects; installed tarball on Node 22.0.0; maintainer Node 24/26; React consumer also typechecked with TS 5.9.3 | Prior execution reused; this is not an actual Appbyul application build |
| Native browser engines | Playwright 1.64.1: Chromium 156 and WebKit 27.2; independent native Fetch/stream controls and actual truncated-body rejection | WebKit engine evidence, not iOS Safari device evidence; Chromium telemetry qualification below |
| Firefox | Firefox 157 passes on Linux at `942d3f8f` in [run 39103431000](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/39103431000); macOS launch control fails before library code | Remote execution reused, log freshly checked; macOS environment qualification remains |
| Retry/restoration | No library retry or restoration layer in Android/Web 1.0 | Intentionally outside this release; native policy remains explicit |
| Remote CI / release | Exact-source [run 39103431000](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/39103431000): Android JDK 17/21 and Node 22/24/26 all pass, including three browser engines, installed tarball and 9 React tests | All five jobs passed; CodeQL Swift tracked above; no registry ownership, signing/provenance, tags or publication claim |

The [ecosystem assessment](ECOSYSTEM_FIT.md) records Android repository/DI/
coroutine integration and React query/SSR boundaries, including tested and
unqualified consumers. Initial CI failures are retained as diagnostic evidence,
not converted to a passing result because Firefox passed independently.

Initial Chromium runs recorded `ERR_ABORTED` after the page had decoded complete
no-store response streams, matching the observable class in
[upstream issue 42742](https://github.com/microsoft/playwright/issues/42742).
An independent native Fetch reader now reproduces that diagnostic without
InnoNetwork, while native `.text()`/no-cache stream controls pass. The precise
Chromium/DevTools implementation cause remains unestablished.

The gate qualifies only `ERR_ABORTED`, Chromium, HTTP 200, no-store, exact
fully validated fixture URLs, after the native stream reproduced the same
diagnostic in that invocation. Eight matcher controls prevent general abort/
error suppression. Page errors, wrong payloads, actual truncated bodies,
unmatched requests and other engines remain blocking. Truncated HTTP bodies
must produce a transport failure in every engine. Qualified diagnostics are
logged, not counted as network failures or silently discarded.

Strict Gradle verification was retained; missing parent/BOM/module metadata
was cross-checked byte-for-byte against Maven Central before adding checksums.
CodeQL's Android lane forces compilation rather than accepting cached outputs.
The exact-source Kotlin scan covered all 15 Kotlin library source files
(38 repository Kotlin files include tests/consumers outside that build).
The test app's backup-enabled finding was addressed with explicit
`allowBackup=false`, a fresh minified build/lint, and exact-head analysis
`1974986678`: 240 rules, no execution error, zero results. TypeScript analysis
`1974985018` reports 201 rules, no execution error, zero results. Both identify
`942d3f8f` and CodeQL CLI `2.27.2`. The completed Swift evidence is recorded
separately above; none of these scans certify an absence of vulnerabilities.

The Firefox failure matches the startup class discussed in
[Playwright issue 42768](https://github.com/microsoft/playwright/issues/42768),
but this checkout does not establish its OS-level root cause. It is not counted
as a passing browser result, and no macOS privacy permissions or personal
browser profiles were changed. Browser tooling was updated to the stable
[Playwright 1.64.1 release](https://github.com/microsoft/playwright/releases/tag/v1.64.1).

All test counts above refer to checks run during this implementation pass, not
copied historical results. A green local suite does not prove absence of defects
or certify platform/release operations listed as unverified.

In the Swift follow-up, prior test/device executions are reused, not relabeled
as fresh executions. Exact-head remote logs, SHA bindings and analysis records
are freshly inspected. The clean-source local bundle
`output/innonetwork-1.0.0.5y7xCg` identifies `942d3f8f`, portable validation
passed and no source drift; 104 artifact checksums were verified. All 123
source-manifest entries except this intentionally updated readiness document
were rechecked during follow-up and still match. Its receipt/README snapshot
has not been rewritten to pretend the later Swift result was already known.

## Reproduce and use the candidate

From the repository root:

```bash
Scripts/check_cross_platform.sh
npm --prefix Platforms/Web run test:browser
INNO_BROWSER=webkit npm --prefix Platforms/Web run test:browser
# On a host with all engines available; Firefox failure remains a hard failure:
npm --prefix Platforms/Web run test:browsers
# Explicit connected device/emulator, after the minified consumer build:
node Scripts/check_android_device_smoke.mjs <adb-serial>
```

Build an installable bundle with:

```bash
bash Scripts/prepare_cross_platform_release.sh
```

It runs all portable gates, refuses sources changed during validation, and
creates a new `output/innonetwork-1.0.0.*` folder containing:

- `maven/`: four complete 1.0.0 modules with sources, docs, metadata and checksums;
- `npm/innosquad-innonetwork-1.0.0.tgz`: actual installable Web package;
- `SOURCE_SHA256SUMS`: the reviewed cross-platform source identity;
- `receipt.json`: base revision, dirty-source flag, runtime, and local gate result;
- `SHA256SUMS`: bundle artifact integrity checks.

Use `maven { url = uri("/absolute/path/to/bundle/maven") }` in the consumer's
dependency resolution settings, and depend on
`com.innosquad.innonetwork:innonetwork:1.0.0` plus the optional modules. Install
the npm tarball directly with `npm install /absolute/path/to/bundle/npm/innosquad-innonetwork-1.0.0.tgz`.
These local distributions need no public registry credentials. Checksums are
integrity records, not publisher signatures. Remote release qualification
must be completed before declaring a public release. Linux Firefox runtime
evidence is separate from macOS Firefox startup and registry publication.

## Native contracts consulted

- [Fetch Standard](https://fetch.spec.whatwg.org/): decoded response bodies and bodyless HTTP responses.
- [Streams Standard](https://streams.spec.whatwg.org/): cancellation returns the underlying source's promise.
- [Kotlin cancellable continuations](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/suspend-cancellable-coroutine.html): prompt cancellation and resource handoff.
- [React StrictMode](https://react.dev/reference/react/StrictMode): effect setup/cleanup replay.
- [CodeQL compiled-language builds](https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages): supported Swift build commands and macOS extraction boundary.
- [Code scanning REST API](https://docs.github.com/en/rest/code-scanning/code-scanning): exact-commit analysis metadata, SARIF and alert evidence.
- [Apple SecCertificateCopyKey](https://developer.apple.com/documentation/security/seccertificatecopykey(_:)): certificate public-key extraction; its contract was also read in the local Apple SDK header.
- [RFC 7469 section 2.4](https://www.rfc-editor.org/rfc/rfc7469#section-2.4): SHA-256/SPKI fingerprint semantics only, not a recommendation to deploy browser HPKP.
