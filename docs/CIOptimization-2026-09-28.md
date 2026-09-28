# Consumer CI local optimization validation — 2026-09-28

Evidence phase: **local implementation and validation before publication**.
The user subsequently authorized publishing the combined corrective candidate,
protected main merge and hosted CI timing verification. Remote results must be
bound to the final candidate/merged-main SHA; none are claimed by this local record.
Local measurement checkout: `codex/6.0-terminal-observation`, base HEAD
`322b84bf80c3577ad9c9612b9667d3902bccd27a`.
The previously approved dirty RFC cache outlining attribute and release record
were preserved; this report is not remote validation of that runtime change.
No runner, protection, dependency, performance threshold or release workflow
configuration was changed. The scheduled continuation remains deleted.

## Changes

- Split the former serial smoke job into independent examples, macros and
  OpenAPI jobs; keep `Consumer Smoke` as the required fail-closed aggregate.
- Require real success for all three lanes, including failure/cancel/skip and
  malformed/missing-result negative controls. Preserve all 15 protected names.
- Keep all 11 discovered example builds and both adopter executions. Keep source
  macro tests, fresh negative fixtures, coverage generation/upload and OpenAPI
  build/test/generated runtime checks. Coverage upload depends on its producer.
- Add pinned, lane-isolated caches with exact toolchain/SDK/OS/architecture/image,
  workspace, manifest/lock and build-policy fingerprints. Never skip validation
  on a hit. Keep root compiled products and coverage out of caches.
- Run new workflow/cache/gate fixture checks in Docs CI and local release preflight.
  Document completing local iterations before publishing a single coherent
  candidate, without weakening final-SHA CI/TSAN/benchmark/release requirements.

The aggregate follows the documented [GitHub job-dependency behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds):
`always()` schedules the check after failures; the explicit result validator,
not the scheduling expression alone, decides whether it succeeds.

## Fresh local evidence

Environment: Xcode 27.0 `27A266a`, Swift 6.4, arm64, macOS build `26A428`.
This is **not** the canonical hosted Xcode 26.0.1 / Swift 6.2 environment.

| Validation | Result |
| --- | --- |
| Workflow wiring / adversarial mutations | 9 Ruby tests, 38 assertions passed; system Ruby 2.6 and installed Ruby both checked |
| Aggregate result / cache fingerprint controls | 14 Python tests passed; failure, cancelled, skipped, missing/duplicate/malformed data rejected |
| Toolchain, SDK, architecture, OS/image, dependency pins, manifest, policy and lane changes | Invalidate cache fingerprints; build products do not |
| Local action output / workflow syntax | Fingerprint multi-line output checked; actionlint passed with only existing `xcode-27` custom label declared locally |
| Consumer lane | Trait/default graph, clean core opt-out, 11 independent packages and two adopter executables passed |
| Macro lane | 54 tests / 3 suites, 5 fresh negative compile fixtures, nonempty LCOV report passed |
| OpenAPI lane | CLI build, 48 tests / 6 suites, generated parse/typecheck/security/anyOf/recursive/3.1 runtime fixtures passed |
| Contracts | Docs/API 1,700 declarations, 15 required-check policy, five platform matrix contract, release workflow, examples and local preflight fixtures passed |
| Cached input invalidation | Valid executable passed; invalid source edit failed with the expected compiler error despite warm products; corrected source rebuilt and ran |

Actual platform builds, TSAN and the full runtime suite were **not rerun for this
CI-only edit**. Prior runtime validation is separate evidence, not a substitute
for a future final candidate's remote gates.

## Cache archive / restore experiment

The actual `MacroAdopterSmoke` consumer was built with three new isolated scratch
directories. Each build directory was archived, moved aside, restored to the
same absolute path, rebuilt and executed successfully (`MacroAdopterSmoke OK`).
Other builds and benchmarks were not run concurrently with these measurements.
Existing machine dependency-download caches were not purged. No source repository
or user consumer build directory was moved or deleted.

| Seconds | Trial 1 | Trial 2 | Trial 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| New scratch build | 18.16 | 15.59 | 15.32 | 15.59 |
| Local archive creation | 5.25 | 5.53 | 5.05 | 5.25 |
| Local archive restore | 4.48 | 4.74 | 4.55 | 4.55 |
| Build after restore | 2.64 | 2.65 | 2.45 | 2.64 |
| Restore + build | 7.12 | 7.39 | 7.00 | 7.12 |

These are local tar timings, **not** hosted cache transfer/compression or complete
CI duration. Archive-save overhead is reported separately. A fresh hosted checkout
can also require recompiling changed source timestamps. Measure cache bytes,
restore/save time, hit rate, eviction and end-to-end time before asserting a remote
speedup; macro coverage/negative fixtures intentionally retain clean compilation.

## Runner boundary and preserved evidence

Read-only metadata from historical CI run
[36410633156](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36410633156)
shows Consumer Smoke waiting 936 seconds and executing for 2,031 seconds. Its
serial expensive steps were examples 1,042 seconds, macro diagnostics 423 seconds,
macro tests 263 seconds and generated OpenAPI checks 146 seconds. Four Apple jobs
overlapped within that run; this does not establish the organization-wide limit.
Repository runner inventory returned zero dedicated runners. Organization runner
inventory returned HTTP 403 requiring admin permission; no permission escalation
or runner configuration change was attempted. Splitting alone cannot guarantee
shorter queues with constrained capacity.

Raw local evidence: `.build/ci-optimization-local/`, including lane logs,
`ci-36410633156-jobs.json`, `cache-reuse-summary.json`,
`cache-probe.FghNSw/{1,2,3}/` and source-invalidation logs. The first actionlint
invocation reported only the pre-existing custom runner label; the follow-up used
a diagnostic-only label declaration without modifying runner configuration.

Preserved original dirty-file SHA-256 values:

- RFC policy: `0e1a22af38600b1738daa1d74feef42c47f2254f84b42dcfabf673525a2bfe12`
- Release validation record: `6f024497cb9cedecc2736c2da79ab26daaa16345d564baa1346182b5342871f8`

`Derived/`, `InnoNetwork.xcodeproj/`, prior failure/profiling evidence and the JSON
baseline branch remain untouched. No commit, push, remote CI dispatch, PR mutation,
merge, tag or publication was performed during this local validation phase.
