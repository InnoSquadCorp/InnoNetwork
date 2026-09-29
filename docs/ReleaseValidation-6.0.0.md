# 6.0 Release Hardening and Operational Acceptance

Scope baseline: main `7b52580430881e7b222f589aee7a30e409ed17da`.
The initial follow-up kept the approved 6.0 feature scope. The user subsequently
approved request-freshness and generator extensions; see `REMAINING_WORK_6_0.md`
for their ordered delivery. New runtime APIs remain Provisionally Stable.
It is not a release-ready declaration and does not publish a tag.

## Final hardening candidate — 2026-09-29

The final local corrections are based on main
`0e22c24169fa99f63bc94fdbe756ec538ea64d6a`. They normalize pinning host aliases
and fail closed for invalid configuration, unify multipart framing and bounded
incremental scans, add awaited multipart backpressure, resolve local schema
references exactly, and reject overlapping resumable-upload IDs before any
checkpoint mutation. The built-in file store additionally owns a process lease;
custom stores must share one engine family or coordinate independent owners.
Cancellation tests observe handler installation rather than scheduler yields.
Release validation retains raw benchmark artifacts on failure and success.

Local Xcode 27 / Swift 6.4 verification of the combined source passed serial
coverage and all four bounded shards: 1,940 registered tests, 1,936 ordinary
passes and four opt-in live skips. The 89 focused tests, 20 cancellation/ownership
repetitions, separate-process recovery/ownership fixtures, 524-file formatting,
external API typecheck and docs/API contracts passed. The public ledger is
exactly 1,702 declarations: 307 Stable, 1,362 Provisional and 33 SPI. The only
additions are the Provisional awaited multipart overload and same-ID upload
error. No Stable API, dependency, performance baseline or 20% limit changed.

The multipart correction preserves body/error behavior in 15,000 differential
cases and exact 1 MiB acceptance / 1 MiB + 1 rejection controls. Three optimized
same-input 64 KiB byte-chunk header pairs changed from 5.87/5.77/5.83 seconds to
0.0149/0.0143/0.0140 seconds. This focused reproducer is not whole-library
performance evidence. Original failures, controls, raw measurements and full
logs remain in `.build/code-improvements-postfix-20260929/` and the preceding
review directories. Generator tests and generated integration fixtures from
the earlier unchanged generator correction are reused explicitly.

This record is local evidence, not a transfer of the prior main's green CI.
The final PR must pass its 15 protected checks, actual full TSAN and runtime/JSON
benchmarks; its fresh merged main then requires CI and manual Release validation
with all five platforms successful and Publish Release actually skipped.
Those remote gates remain pending when this candidate is committed. No tag,
publication, consumer migration or scheduled automation is authorized here.
Existing device/service, custom-store and consumer-adoption boundaries remain.

### PR review follow-up: IPv6 identity and multipart EOF

The first PR candidate `5775fb7` passed all seven local fast-preflight gates,
including 11 independent examples and fresh generator/output integration checks.
Review then identified an IPv6 identity gap: compressed/expanded spellings of
the same address could select different pin sets. Eleven lookup assertions and
three incorrect-pin checks failed on that candidate while same-spelling and
system-trust controls passed. The latter used an isolated IPv6 SAN certificate,
a fixed verification date and no keychain installation or network access.

The follow-up formats a successfully parsed IPv6 address with `inet_ntop` before
pin selection. Zones remain separate, IPv4-mapped IPv6 is not collapsed into
IPv4, and normal TLS hostname validation is preserved. Correct/wrong pins,
compressed/expanded/bracketed/scoped/mapped spellings and unrelated-address
controls are covered. No public declaration or performance limit was added.

A separate suggestion to return immediately after a multipart closing delimiter
was not adopted: MIME completion does not prove successful transport EOF.
The documented upstream-error contract must retain failures after the closing
delimiter; both overloads now test that case. Epilogue bytes remain discarded
without retaining a growing buffer, and unbounded sources need cancellation or
an upstream deadline. No multipart runtime behavior changed in this follow-up.

Focused checks passed 21 tests. The corrected source passed full serial coverage
and all four bounded shards: 1,941 registered, 1,937 ordinary passes and four
opt-in live skips. Public counts remain 1,702; no API addition followed the review.
Initial failures and controls remain in `.build/final-publication-20260929/`.
The superseded candidate's four remote workflows were cancelled, not passed.
Its replacement requires its own protected checks, full TSAN and benchmarks,
followed by fresh-main manual Release validation; no old-SHA pass is substituted.

## Post-CI-split cancellation follow-up — 2026-09-29

[PR #127](https://github.com/InnoSquadCorp/InnoNetwork/pull/127) passed its exact
candidate's 15 required checks, full TSAN and runtime/JSON benchmarks, then
protected-squash merged to `9a67373f02446ca88fa9c0c13d17221167945660` with an
identical tree. Its [main CI](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36430176295)
failed only `valueAwaiterCancellationPropagates` in the Xcode 26 bounded core
shard. All other executed jobs, including the three consumer lanes and their
required aggregate, succeeded; CodeQL also succeeded. This is not a green
final-main or final Release result.

The test cancelled its value-awaiting task, yielded once, and advanced the
virtual deadline. Request entry and deadline registration do not prove that
the separate value task installed its cancellation handler. A controlled late
entry reproduced `.timeout` / `.requestPreparation` instead of `.cancelled` /
nil; awaiting actual cancellation completion before advancing passed. The test
and relevant production files were unchanged from `7918e11`. Local evidence
uses Xcode 27 / Swift 6.4, not the unavailable hosted Xcode 26 / Swift 6.2.

The correction waits for the terminal cancellation result before advancing
time. Both ordinary and deliberately delayed value entry retain the cancelled
kind, nil deadline stage, and zero clock waiters; reading the result again after
deadline advancement must return the same failure. A one-minute test limit
forwards cancellation to owned tasks, and the fake's start observation is
cancellation-aware. Runtime semantics, API, CI workflow and performance limits
are unchanged. The original remote failure and deterministic failing/control
logs are preserved in `.build/ci-optimization-remote/cancellation-*` and
`main-bounded-failed.log`.

All 19 operation tests and 20 consecutive repeats passed locally. Full serial
coverage and four bounded shards passed 1,923 registered tests (1,919 ordinary
passes and four opt-in live skips). Formatting over 517 Swift files, the unchanged
1,700-declaration docs/API contract and the documentation consumer build passed.
The new exact candidate's remote gates and fresh merged-main manual Release
validation remain required. Existing consumer snapshots and real-device/
dedicated-service exclusions below still apply.

## Post-merge Release validation — 2026-09-28

[Ready PR #126](https://github.com/InnoSquadCorp/InnoNetwork/pull/126) was
protected-squash merged to `7918e11c13c0db25b76bdca8417afd840187498f`, with a tree
identical to `9ef40c014619dbd076abdad2e119ab3d5da16151`. That candidate passed all
15 required checks, full TSAN and runtime/JSON benchmark guards. No bypass or
threshold change was used.

The first [manual Release run](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36401406352)
on exact main `7918e11` passed all five platform builds and both benchmark lanes,
and actually skipped Publish Release. It nevertheless **failed** serial coverage:
`lifecycleEventsWithRetry` saw zero `requestFinished` events in its early snapshot.
Downstream coverage reporting, sharded tests, DocC and SBOM/artifact preparation
did not run; candidate passes do not close this final-main gate.

The test waited for eight arbitrary events instead of the terminal callback.
Policy decision events can satisfy that count while delivery of the terminal
event is still pending; observer execution intentionally does not block request
completion. Holding only that callback reproduced the same assertion failure
locally; the ungated control passed. The relevant runtime and test files were
unchanged by the Ready PR, so this is not a Ready metadata runtime regression.

The corrective change is test-only: an actor-owned, buffered terminal signal
replaces count-based polling, preserving the complete retry/correlation/outcome
assertions. Gated and ungated variants cover delayed terminal delivery; separate
checks cover already-recorded success/failure and cancellation of the waiter.
No production behavior, performance baseline, workflow, or validation limit is
changed. A new exact-head protected PR and final-main manual Release pass remain
required. The initial failure log, deterministic reproducer patch, passing control
and correction logs are retained in `.build/release-continuation/lifecycle-*`
and `final-release-7918e11-failed.{log,json}`.

Fresh local correction validation (Xcode 27.0 / Swift 6.4): all seven lifecycle
tests passed after formatting and in 20 consecutive focused coverage runs.
Full serial coverage passed all eight products: 1,923 registered tests,
1,919 ordinary passes and four explicitly skipped opt-in live tests. Formatting
over 517 Swift files and the docs/public API contracts also passed; the public
surface remains 1,700 declarations (307 Stable / 1,360 Provisional / 33 SPI).
These local results do not substitute for the corrective PR's remote checks.

### Corrective PR bounded-shard follow-up

The Xcode 26 bounded-shard job on `9bcefc3` subsequently failed the existing
`concurrentRequiredSessionAuthenticationSingleFlightsRefresh` test: nine token
reads and two refreshes rather than eight reads/one refresh. The modified
observability tests passed. The auth test and production coordinator are
identical between PR base `7918e11` and `9bcefc3`.

A controlled final token read held until another request completed reproduced
the same 9/2 failure on both revisions under local Xcode 27 / Swift 6.4. This
does not claim a local Swift 6.2 run. The fake always returned nil, even after a
successful refresh, and its eight-read barrier did not prove all eight callers
had joined the in-flight refresh. The coordinator correctly re-reads when a
provider call spans a completed refresh generation; the stateless fake then
reported another missing token.

The fixture now models caller-owned token storage and tests both normal overlap
and a delayed stale read. Exactly one refresh and eight correctly authorized
transports remain required; the delayed variant additionally requires a token
re-read. It does not suppress a failed assertion or change auth runtime behavior.
Its waiters are cancellation-aware. A separate review observation also led to
awaiting explicit terminal-observer entry before cancelling its waiter, rather
than racing task creation. This signal proves entry into the observation method,
not an undocumented internal AsyncStream suspension point.

The original hosted log, deterministic reproduction patch and base/head control
logs remain under `.build/release-continuation/` with `shards-failed-9bcefc3` and
`auth-delayed-*` names. New-head remote checks and final merged-main Release
validation are still required; prior successful jobs are revision-specific.

The final local correction passed 43 focused tests and 20 consecutive repeats.
Removing only token persistence made the delayed-read variant fail with two
refreshes, confirming that the one-refresh invariant is still enforced; restoring
persistence passed again. Full serial coverage and all four bounded shards
passed 1,923 registered tests (1,919 ordinary passes / four opt-in live skips).
Formatting passed over 517 Swift files. No production source was modified.

### Corrective PR cache performance follow-up

The first [benchmark attempt on `322b84b`](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36410949203/attempts/1)
failed the unchanged 20% runtime guard: cache revalidation paired median
-24.2435%, with pairs -24.2435/-28.8857/-11.5734% and 17.3123 percentage-point
spread. The JSON lane did not execute. Full logs and artifact 10966195389 remain
under `.build/release-continuation/benchmarks-322b84b-failed*`. One unchanged-
condition rerun was requested, not an open-ended retry-until-green procedure.

Runtime, harness, dependency and workflow sources were identical between
`7918e11`, `9bcefc3` and `322b84b`, but the guard compares historical `a4aaaba`,
so that identity alone does not rule out an older regression. Fresh local
Xcode 27 / Swift 6.4 pairs passed all 14 runtime and five JSON guards, with
cache median -12.4612% and 3.5527pp spread. This is not a reproduction under
the hosted Xcode 26 / Swift 6.2 environment; hosted variability is still not
attributed to a specific machine cause.

Local Release profiles and disassembly isolated a genuine code-generation
cost: inlining `prepareWithRFC9111` into the common preparation dispatch
hoisted the adapter's payload-heavy stack temporaries into plain `cacheFirst`
calls. Historical/current stack-probe self samples were 131/937 ms for the
same 50-million-iteration diagnostic. Changing the ternary return to an `if`,
or disabling inlining only on the recursive dispatch, did not remove the
prologue and were reverted as negative controls.

Keeping the RFC adapter as an out-of-line call removes those common-path
temporaries without changing any directive, age, freshness or payload logic.
Original/modified local cache pairs improved +11.5440/+11.3011/+13.9064%
(median +11.5440%). The modified profile reduced stack-probe samples to
142 ms; profiles are diagnostic evidence, not acceptance measurements.
The raw traces, exported samples, assembly, negative-control patches and
paired JSON results are retained as `cache-*` under the continuation directory.
The complete dirty outlining candidate then passed all 14 runtime and five JSON
paired guards at the unchanged 20% threshold. Cache revalidation median was
-4.54% versus historical `a4aaaba`; results are retained in
`benchmarks-cache-outlining/` and `cache-outlining-benchmarks.log`. These local
Xcode 27 / Swift 6.4 results include the recorded four-line source patch, not the
unmodified `322b84b` tree.
Neither the benchmark harness nor a baseline, guard limit or public API was
changed. New exact-head remote checks and final merged-main Release validation
remain required; successful checks on the preceding test-only candidate do
not validate this runtime optimization.

## Current readiness transition — 2026-09-28

[PR #125](https://github.com/InnoSquadCorp/InnoNetwork/pull/125) was squash-merged
through protection to `bcb97e1f9912a341a906482f4b51dee760cb836e`. Its single parent
is `7b52580430881e7b222f589aee7a30e409ed17da`; the merged tree is identical to the
validated candidate `21a3decb67554dcdc66ec00db54b38bb2192cb1e`. No administrator
bypass or protection change was used. The JSON source-retention branch remains
at its reviewed `b358692e1e583b5cef1c97bb65208729b313f574` revision.

Fresh candidate evidence, not inferred from earlier local passes:

- [Required CI](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36388673299)
  and [CodeQL](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36388673335):
  all 15 required statuses passed, including Xcode 26/27 and five Apple platforms.
  Consumer Smoke now builds the generator under Swift 6.2, passes all 48 generator
  tests, and executes the generated-output integration checks. This closes the
  original type-inference failure; its initial failing log is still preserved.
- [Full TSAN](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36388673253):
  all eight test products passed; 1,921 registered, 1,917 ordinary passes and
  four opt-in live skips. No sanitizer suppression was introduced.
- [Benchmarks](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36388673237):
  runtime and JSON guards passed with unchanged 20% thresholds. Event paired
  median +19.87%, pair spread 79.1 percentage points; revalidation -6.00%,
  coalescing +5.05%; JSON deltas -10.08% to +6.48%. The event variability remains
  substantial, so this is gate acceptance, not a stable speedup guarantee.

The subsequent Ready transition changes validation policy and coordinated
documentation, including stale DocC symbol links, not runtime behavior or API
declarations. Ready means the release contents are
approved; it does not claim a tag, GitHub Release, or newly resolvable package.
The intended release date must be reconfirmed before a separately authorized
publication. Fresh CI for the Ready commit, its protected merge, and final manual
Release validation on the exact resulting main SHA remain mandatory.

Fresh local checks for the Ready metadata and validation policy passed:

- Full root suite: 1,921 registered / 1,917 ordinary passes / four live skips.
- Draft/Ready fixtures, historical committed-Draft validation despite a Ready
  worktree, tag/candidate/artifact/preflight fixtures, and the manual-workflow
  publication exclusion all passed. No validation threshold was weakened.
- Public API remains exactly 1,700 declarations: 307 Stable, 1,360 Provisional,
  33 SPI. Formatting passed over 517 Swift files.
- DocSmoke executed; three extracted migration snippets and three Stable examples
  compiled; all 11 independent consumer examples built; macro/OpenAPI adopter
  executables passed. These do not replace the separately scoped app snapshots.
- All nine public-product DocC archives passed. The first build exposed five stale
  symbol links in resilience, upload and WebSocket documentation; their actual
  declarations were checked and only the links were corrected. A repeat build
  reports no warnings/errors from this repository's `Sources/` paths. Dependency
  documentation warnings in the original full build are not represented as fixed.

The full root/example suite ran before the final comment-only symbol-link repair;
DocC, adopter execution, formatting and public API contracts were rerun afterward.
Logs use the `ready-*` prefix in `.build/release-continuation/`, with the initial
DocC warnings retained separately from `ready-docc-fixed.log`.

Earlier app/companion snapshots remain bound to `b1dc8d1`, including Capto's
Flow 5.1.1 / Router 5.2.1 graph. Their acceptance is not silently extended to
latest companion majors or device/dedicated-service behavior. Those boundaries
and the remaining clean published-tag checks are listed below.

Local and remote logs are preserved in `.build/release-continuation/`, including
`required-before-merge-21a3dec.json`, `consumer-full-21a3dec.log`,
`tsan-remote-21a3dec.log`, and the raw `benchmarks-remote-21a3dec/` artifact.
The detailed chronological records below retain their original revision scopes.

## Implemented checks

| Area | Change and passing control |
| --- | --- |
| Cache contract | RFC matrix now states current Age is returned on reuse. Existing hit, stale recovery, and 304 tests exercise that behavior; docs-contract sync rejects the obsolete unsupported claim. |
| VCR privacy | Recording and mismatch errors remove URL user-info and fragments. Transport receives the original URL. Tests preserve path encoding, IPv6/port/query identity, custom query policy, legacy replay order, and explicit disk migration without rewriting the source. |
| Upload ID history | Contiguous and sparse stateless-session workloads preserve exact IDs and suppress a late callback. Manager shutdown and channel finish release history; finished channels reject subsequent events. |
| Resumable process recovery | A worker exits after durable chunk acceptance before acknowledgement, or after finalization before checkpoint cleanup. A fresh worker reopens the real file checkpoint store, probes the durable fixture, sends no duplicate bytes, uses fresh credentials, reuses the session, and removes the checkpoint after success. |

The VCR privacy tests fail against the baseline implementation and pass after
the change. The channel-finish assertions likewise fail before its cleanup fix.
The recovery adapter is a deterministic file-backed stand-in, not a production
HTTP backend. Abrupt fixture exit is deliberate and affects only that worker.

## Earlier local evidence — 2026-09-24, before the additional scope

The validated runtime, test, fixture, manifest, and workflow files are captured
by `1330ace10f6c6bd56f675f36ff2cdcc183f0cb2b` (including VCR change `558a10f`).
The subsequent documentation commit records these results without changing
those files.

- Xcode 27.0 (27A266a), Apple Swift 6.4, macOS arm64.
- Full serial suite: 1,837 registered tests, 1,833 passed and 4 explicitly
  skipped external-service tests; command exit 0.
- Upload repetition: 10,000 contiguous and 10,000 sparse tasks, plus 10,000
  overflow events for each ID pattern. Four argument cases passed; late
  callbacks did not recreate tasks and both histories cleared on termination.
  Test execution was 2.845 seconds, not a long-duration production soak.
- Two fresh-process recoveries passed after rebuilding the fixture.
- Public API contract: 1,614 declarations unchanged (306 Stable,
  1,275 Provisionally Stable, 33 SPI); docs-contract sync passed.
- The independent `Examples/TestSupportSmoke` consumer built and ran.
- Swift formatting, shell syntax, YAML parsing, release-state fixtures,
  documentation assertion helpers, preflight wiring fixtures, and
  publication-safety workflow fixtures passed.

Local logs use the prefix `/tmp/innonetwork6-hardening-`, including
`full-test.log`, `upload-soak.log`, `process-recovery-final.log`, `docs.log`,
and `format.log`. These temporary logs can be removed by environment cleanup;
the committed commands and fixtures are the reproducible record.
Final-candidate remote CI and device/backend acceptance were not run.

## Reproduce

Additional-scope verification on 2026-09-24 covers runtime changes through
`e19e2bd` and generator changes through `32ae536`, plus the committed soak probes:

- Full serial suite: 1,849 registered tests, 1,845 passed, 4 external skips;
  all 8 test-product summaries passed, command exit 0.
- Generator: 20 tests passed; generated operations typecheck; executable
  composition/nullable roundtrip and negative contracts passed.
- iOS Simulator `InnoNetwork-Package` build: succeeded with signing disabled.
- Bounded-duration component soak: 4,847,266 reconnect attempts and 4,114,034
  ordered streaming deliveries, 30 seconds each. The span buffer never exceeded
  32, terminal request/attempt state cleared, and exported plus dropped counts
  equalled produced spans. Cancellation released the streaming producer.
- Two fresh-process resume fixtures passed, including orphan snapshot cleanup.

New logs use `/tmp/innonetwork6-remaining-`: `full-final.log`, `soak.log`,
`codegen-final2.log`, `generated-final2.log`, `ios.log`,
`recovery-final.log`, `docs-final.log` and `format-final.log`.
The soak is a component-state bound, not heap/RSS measurement or a production
service certification. Final remote CI, consumers and the other three device
platform builds remain separate gates.

Run from the repository root:

```sh
xcrun swift test --jobs 2 --no-parallel
bash Scripts/check_docs_contract_sync.sh
bash Scripts/test_resumable_process_recovery.sh
bash Scripts/tests/test_run_local_release_preflight.sh
bash Scripts/format.sh --lint
INNO_UPLOAD_SOAK_ITERATIONS=10000 xcrun swift test --skip-build --no-parallel --filter UploadIdentifierRetentionTests
INNO_STREAM_SOAK_SECONDS=30 xcrun swift test --jobs 2 --no-parallel --filter StreamingResourceSoakTests
```

The process fixture runs in CI, release validation, and the local preflight's
documentation-smoke gate. It leaves a small credential-free evidence directory
containing checkpoints/backend state. The resumed worker now reclaims the
interrupted worker's orphan snapshot. It never terminates a compiler, build,
test runner, or unrelated app.

The long-run test defaults to 1,000 operations per pattern; explicit runs allow
1–100,000. A run with N sequential IDs needs one range; N isolated IDs need N
ranges until shutdown when the test explicitly configures that capacity.
Production defaults cap each identifier history at 4,096 ranges, with fail-closed
admission on exhaustion. Whole-command RSS includes SwiftPM and test-runner overhead and
must not be reported as the ID container's allocation size. A finite
`maximumRetainedTerminalTasks` is not the callback-history ceiling;
`maximumIdentifierRanges` is the separate bound.

## External acceptance matrix — still required for the relevant adoption

| Boundary | Procedure and acceptance evidence | Current limitation |
| --- | --- | --- |
| iOS background daemon | On a dedicated physical iPhone, suspend/resume an upload/download; exercise system termination and relaunch, user-paused restoration, and exactly-once completion. Record device/OS/app/library revisions and server byte counts. Test explicit user force-quit separately because its OS behavior differs. | Discovery on 2026-09-25 found the iPhone connected/paired with Developer Mode enabled. Test-app installation was requested but not performed; this is prerequisite evidence, not device acceptance or a current connection claim. Simulator and macOS checks do not close this row. |
| Protected storage | While the physical device is locked, exercise configured protection classes, delayed callbacks and relaunch. Verify unreadable files fail without corrupting checkpoints and become usable when permitted. | No physical-device run or power-loss test was performed. |
| Real resumable service | With a dedicated test account and disposable object, interrupt before/after each acknowledgement, expire credentials, change source identity, and retry finalization. Verify server offsets/checksum and no duplicate creation or credential persistence. | The local durable adapter proves engine recovery, not a specific backend's contract. Test service/account has not been supplied. |
| Real quota/identity provider | Replay a documented quota/burst pattern, cancellation and 429/Retry-After behavior; exercise realm-separated credential refresh. Record rate/latency and server observations without credentials. | No service-specific quota model or IdP account has been supplied. Keep advanced APIs Provisionally Stable. |
| Long-lived streaming/export | Use a bounded-duration load and a slow/failing exporter; capture memory trend, drops, completion and cancellation behavior, with a named consumer adapter. | Local 30-second component workloads now cover blocked export, exact drops, bounded retained state and cancellation. App RSS trends, overnight load and a real exporter remain unverified. |
| Publication | Re-run final-SHA remote checks, close consumer gates, then change Draft to Ready and follow tagged companion-dependency validation order. | This local hardening invalidates using the earlier main CI as final-candidate proof. No tag is published by these checks. |

Do not store account secrets or real payloads in fixtures. Obtain the dedicated
environment before running tests that create server resources or alter app
lifecycle. Feature-scoped managers should shut down once work is finished;
shutdown cancels active transfers, so do not rotate during background work to
reclaim history.

## Approved additional scope

The user approved request freshness and preview-generator path/auth/schema
extensions after the initial hardening report. They are now implemented in
`bb5d425` and `38e5480`, after upload resource hardening `c6de363`.
Request freshness is opt-in; generated authentication supports explicit HTTP
bearer requirements and rejects unsupported security forms. Composition support
is the documented serialization subset, not full JSON Schema validation.
The candidate inventory is 1,700 declarations: 307 Stable, 1,360 Provisionally
Stable and 33 SPI. Publication/device/service gates remain independent.

### Named-credential extension (2026-09-25)

The subsequent approved extension adds the origin-bound provider contract and
generator output for API keys, scoped OAuth and explicit AND/OR selection.
OAuth validates grants/expiry and isolates bounded renewal without escalation.
The subsequent preserved-JSON and named-reference anyOf stages are implemented
through `e53ec95`, including mixed-model dates and Codable container fixes.
See `OPENAPI_EXPANSION_EXECUTION.md` for the final-code local gates and renewed
seven-app compile evidence. Earlier `65c3acf` simulator launches remain historical;
app compilation does not prove adoption of the new provider path. Remote CI,
physical-device acceptance and dedicated service/IdP/exporter gates remain open.

## Root release preparation snapshot — 2026-09-28

Frozen input: `b1dc8d1ea2cc26cc89e77bb0a5c4b7d5f63c1ab3`, after all approved
schema/codec extensions. This section records completed root checks, not a
release-ready declaration. The accompanying release-note/migration edits change
documentation only. Remote `main` was `7b52580430881e7b222f589aee7a30e409ed17da`;
its earlier CI is not evidence for these 30 local commits.

- `bash Scripts/run_local_release_preflight.sh --full` passed all 14 gates on
  Xcode 27 / Swift 6.4: script fixtures, dependency lock, static contracts,
  documentation/process recovery, 11 independent examples, generator/runtime
  integration, bounded tests, resource soak, runtime and macro coverage,
  benchmark guards, both SBOM profiles, all-product DocC and five platforms.
- Root inventory: 1,916 tests, including four opt-in live tests skipped in the
  ordinary suite. Both bounded shards and serial coverage passed. Generator:
  45 tests; official schema examples: 355 cases in 18 pinned files.
- A separate `INNO_LIVE=1` run passed all four public HTTP/WebSocket tests with
  synthetic payloads. It does not certify a dedicated backend, IdP or exporter.
- Runtime line coverage: 88.73%; macro line coverage: 90.22%. These percentages
  describe the instrumented local run, not a proof of defect absence.
- Runtime guards (14) and dedicated JSON guards (5) passed unchanged 20%
  thresholds in three interleaved same-runner pairs. Cache revalidation was
  -13.53%; coalescing +9.58% with 33.6% pair spread, so the latter is not a
  reliable improvement claim. JSON guarded deltas ranged from -2.92% to -0.68%.
- Thirty-second resource probes completed 7,133,788 span attempts and 5,574,541
  ordered stream deliveries, with exact exported/dropped accounting and
  cancellation completion. They do not measure production RSS or overnight load.
- macOS/iOS package builds and all nine public targets on tvOS, watchOS and
  visionOS passed. All nine public-product DocC archives were checked.
- The live required-check ruleset matched all 15 checked-in requirements, with
  up-to-date branches required and no configured bypass actor in that ruleset.

The root log is `/tmp/innonetwork-b1dc8d1-release-full.log`; artifacts are in
`.build/local-release-preflight/`. Consumer/companion snapshots, commands,
source revisions and logs are under
`/tmp/innonetwork-b1dc8d1-readiness.fSbEFt/`. Temporary evidence can be removed by
environment cleanup; commands and the final candidate PR validation summary
are the reproducible handoff. App builds are tracked separately and are not
implied by the root package's example builds.

Publication remains Draft. The approved next action is a candidate branch push
and PR for final-SHA CI, not merge, tag or release. Before publication, complete
consumer checks and required PR CI, deliberately approve the atomic Ready
transition, merge through protection, and run the full manual Release workflow
on fresh `main`. That workflow must pass on the exact commit to be tagged.
Tagged-dependency checks for InnoStream/Protobuf follow the publication order in
`RELEASE_POLICY.md`; they cannot be replaced by local path overrides.

Device discovery on 2026-09-28 reported the paired iPhone unavailable. No
physical-device lifecycle/protected-storage acceptance was performed. Dedicated
backend, IdP, quota and exporter environments remain unsupplied. These are
feature-adoption boundaries, not newly diagnosed root-library defects or checks
silently waived by the local passes above.

### Remote compatibility follow-up

The first candidate PR (`#125`, `c07e45d`) passed the Xcode 26 bounded test
shards but failed the iOS package build: Xcode 26 treated the recovery fixture's
`main.swift` as an implicit entry point in addition to its `@main` declaration.
The fixture is renamed to `RecoverySmoke.swift`; no public-library source,
dependency, recovery behavior or compiler safety flag changes. The original
failure remains recorded, and final-SHA remote platform validation is required
after this build-compatibility correction.

The same initial CI also exposed a heartbeat test-ordering race. Advancing the
test clock did not prove that timeout cancellation had completed before the
blocked dispatch was released, and checking a zero ping count could pass before
the dispatch decision. The test now observes the timeout callback, releases the
gate, and waits for the actual dispatch decision before asserting no ping. An
internal optional completion observer (nil in production) supplies that final
barrier without changing dispatch/cancellation policy. The test gate registers
arrival/continuation atomically and remembers release-before-arrival.

Fresh local follow-up: all 15 heartbeat timing tests passed; a separate copy
with the cancellation guard deliberately removed failed both no-ping assertions,
and restoring the guard passed all 15 again. Full serial coverage passed 1,917
registered tests (1,913 ordinary passes; four opt-in live skips). Recovery fixture,
format/API/docs contracts, local iOS build and nine-product DocC checks passed.
The performance and consumer evidence above remains bound to `b1dc8d1`; it is
not relabelled as a new measurement after these CI follow-ups. The final PR SHA
must receive new remote checks.

### Swift 6.2 generator build follow-up — 2026-09-28

Candidate `bbbe4af13718103feb8721569776e4a5586fb9d6` passed the
[remote benchmark run](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36384626112)
and [full TSAN run](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36384626070).
The benchmark guard thresholds remain 20%; the event paired median was +21.13%
with a 32.0 percentage-point pair spread. This is passing gate evidence, not
proof that hosted variability has disappeared. Raw paired measurements and the
initial failure remain preserved.

However, its required
[Consumer Smoke job](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36384626077/job/108807397932)
failed while building `openapi-to-innonetwork`, before its generator tests and
generated-output validation could run. Xcode 26.0.1 (17A400), Apple Swift 6.2
(`swiftlang-6.2.0.19.9`), rejected the five-way child-schema collection expression
in `needsCompiledSchema` with a type-checking-time diagnostic. The compiler did
not report a runtime test failure. This generator source was added in the PR;
it is absent from the `7b525804` main baseline, so the failure must not be
attributed to the event-delivery optimization or dismissed as a baseline flake.

The follow-up splits the overloaded collection expression into separately typed
appends, preserving properties/anyOf/allOf/oneOf/items traversal and the existing
reference/depth checks. It does not raise compiler budgets, change a public API,
broaden the supported schema subset, or weaken a validation gate. Three new
parameterized tests cover 13 cases: nested constraint selection, fail-closed
unsupported assertions, and ordinary typed-model controls. The constrained
allOf/oneOf cases retain their existing explicit rejection by the schema compiler.

The added characterization tests passed against the original source on local
Swift 6.4 before the expression change. After the change, all 48 generator tests
passed; all generated files from six integration fixtures were byte-identical
to the original generator. Generated-output parse/typecheck and executable
security/composition/anyOf/constraints/recursive/3.1-subset checks also passed,
along with repository formatting and the unchanged 1,700-declaration API/docs
contract. Local Swift 6.4 is not a reproduction or a pass of
the Swift 6.2 compiler failure: that toolchain is not installed locally. The
replacement PR head must pass Consumer Smoke and the other required checks,
plus benchmarks and full TSAN, before protected merge. The old head's successes
do not replace exact-head validation.

Evidence copies are under `.build/release-continuation/`: the original
`consumer-full-bbbe4af.log`, `benchmarks-remote-bbbe4af/` raw artifact, and
`generator-control-bbbe4af.log`, `generator-fixed.log`, `generator-before/`,
and `generator-after/` local controls. Reproduce the generator checks with
`xcrun swift test --package-path Tools/openapi-to-innonetwork` and
`bash Scripts/test_openapi_generated_output.sh`.

### Consumer snapshot results

The 12 non-HLS app snapshots passed their full app builds: Appbyul, BlPia, Bora,
CargoAirline, Circe, Echo, Huginn, Ithaca, Pythia, Vulcan, Walden and HaruFit.
Vulcan used macOS; the others used iOS Simulator. Pythia/Vulcan additionally
passed explicit CoreNetwork builds because their app paths do not exercise
that module. HaruFit only declares the dependency and has no active call site;
its app build is not runtime-adoption evidence. Original HEADs, working-tree
states and consumer lock files were compared and preserved.

Capto `4efbacf` passed macOS/iOS builds and Domain 2, DesignSystem 1 and Download
43 tests with this Network candidate, Stream `79489f4`, Flow **5.1.1** and Router
**5.2.1**. The current local Flow 6 / Router 6.x graph does **not** pass: Capto
still uses the two-argument Reducer and removed NavigationStore/NavigationHost
contracts. That separate consumer migration is not silently treated as fixed.
Canonical fixture paths and explicit temporary manifest paths were necessary
to avoid Tuist reusing a previous graph; mismatched-graph attempts are excluded
from the passing evidence. No consumer production source or lock was changed.

Protobuf `9d622d7` passed 17 tests plus its standalone consumer. Stream's host
suite command passed, with environment-dependent HLS acceptance still excluded.
Local path-based checks do not prove clean published-tag resolution or that
any consumer migration has been merged into its remote main.
