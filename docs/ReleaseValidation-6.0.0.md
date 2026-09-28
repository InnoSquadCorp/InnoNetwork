# 6.0 Release Hardening and Operational Acceptance

Scope baseline: main `7b52580430881e7b222f589aee7a30e409ed17da`.
The initial follow-up kept the approved 6.0 feature scope. The user subsequently
approved request-freshness and generator extensions; see `REMAINING_WORK_6_0.md`
for their ordered delivery. New runtime APIs remain Provisionally Stable.
It is not a release-ready declaration and does not publish a tag.

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
