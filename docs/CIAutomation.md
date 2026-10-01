# CI and dependency automation

## Scope and preserved contracts

The first automation change started from `9d8053d5f921ebf5c38cc2f816efe90c7db4a450`.
The Ready/cache/reuse follow-up starts from current `main`
`82d3c8d5c943bdd93ce39394774678f641b0e393`.
The initial change is automation-only; the later user-requested [dependency PR
integration](DependencyIntegration-2026-09-30.md) also updates Swift Crypto and
GitHub Actions pins. Swift tools 6.2, all five Apple deployment floors,
runtime/public API, default macro trait, dependency ranges, coverage behavior,
and the same-runner 20% performance ceiling remain unchanged.

`CI Plan` and `CI Required` run for every PR, main push, merge queue and manual
CI event. No workflow-level PR path filter may hide the required aggregate.
The planner reads exact base/head commit SHAs with NUL-delimited Git output.
Deleted, renamed, copied, type-changed, empty and unknown path evidence chooses
the full lane; malformed/unavailable evidence fails instead of producing green.
Both rename paths remain in the audit artifact. The final aggregate recomputes
the declared plan and accepts success for selected jobs, skipped for explicit
non-targets, or narrowly revalidated equivalent-tree PR proof described below. Failure, cancellation, unexpected skips, missing jobs and
extra jobs all fail.

- Sources, tests, examples, smoke tests, benchmarks, package/lock/tooling changes:
  every former CI protection plus CodeQL, TSAN, same-runner benchmarks, DocC and
  read-only release candidate validation
- Prose/SPI/site docs: docs contract checks, full DocC site and policy tests
- Known individual workflows: their mapped lanes and policy tests
- Dependabot of every update type, or a `release-validation` label: full lane
- `concurrency-review`: explicitly requests TSAN even for an otherwise narrow PR
- Main/manual/merge queue: full lane, except PR-only dependency comparison

The old 15 protected display names and `.github/required-status-checks.json` are
retained. Consumer Smoke still requires all three independent consumer lanes.
The baseline fixture asserts all old runner/matrix/test command contracts. Full
PR validation expands to 32 concrete jobs, including six release candidate jobs.
Scheduled/manual CodeQL, TSAN and benchmark entry points remain; their former
PR work now lives in CI and cannot escape the aggregate. Benchmark PR comments
are replaced by preserved artifacts, so PR benchmark code no longer holds
issue/pull-request write credentials. Scheduled trend append remains separate.

## Ready events and equivalent-tree main verification

Heavy PR CI runs on opened, synchronize, reopened, edited, labeled and unlabeled
events. Ready/draft changes reach the native Ready/coordinator workflows, so
marking an unchanged Draft ready does not cancel or restart the heavy matrix.
`edited` remains because base-branch retargeting must refresh the changed-path
selection and tested merge tree. Labels still select additional contracts and
therefore trigger CI.

Main push may reuse only five tree-dependent logical groups: swift-format lint,
Periphery, bounded target-sharded tests, the five Apple build-smoke variants, and
ThreadSanitizer. Admission requires a single-commit non-force squash push, one
merged same-repository PR, exact pre-merge main/base/head parents, and an identical
complete Git tree to the tested merge commit. The immutable reusable
`release-validation.yml` reference binds the original PR merge SHA. Every one of
the full PR's 32 concrete jobs, mandatory steps and native app/suite/job/check
identities must be successful at the latest run/attempt, completed within 24
hours before merge and still fresh at admission. Source run/attempt and current
main are checked again after paginated evidence reads to detect races.

Missing, stale, failed, forked, ambiguous, API-error, direct-push or changed-tree
evidence falls back to ordinary full CI before any job is skipped. The logical
plan remains full (except PR-only Dependency Review), and `CI Required` fetches
and verifies the same proof again. Later revocation fails closed. The aggregate
does not create status results for skipped jobs or weaken native required checks.

Coverage and macro artifact producers/uploaders, all consumer checks, docs and
DocC, benchmarks, CodeQL and release-candidate validation still execute freshly.
Main publishers consume only exact-main artifacts from their verified source
run. Reuse never downloads PR artifacts, logs, caches or executable code into a
privileged main workflow and cannot authorize release or deployment.

## Exact download cache and dependency snapshots

The cache key binds tracked package manifests/lockfiles, validated package pins,
the explicit cache implementation/profile contract, actual Swift binary/version,
selected Xcode,
every advertised SDK identity, OS/architecture and explicit job/platform profile.
Generated nested locks and downloaded packages are excluded. The root, 11 example,
five macro fixture and standalone OpenAPI package graphs remain distinct inputs.
Identical repeated Xcode SDK rows are coalesced only after each occurrence's
version/build/path agrees. An unused SDK may report an empty build field, which
is fingerprinted exactly; every profile-required SDK remains strict.

Only SwiftPM repository mirrors and downloaded prebuilts are cached. Same-runner
benchmarks use the same narrow subdirectories in their existing dedicated cache
root. No compiled `.build` trees, coverage profiles, receipts or test/DocC/release
outputs are restored. Exact keys have no broad fallback. Restore-hit and bounded
file metadata/timing observations are diagnostic only; every selected assertion
still runs, and a hit is never evidence of validation or a claimed speedup.

Snapshot serialization now lives on eligible submission jobs, with
`cancel-in-progress: false` and `queue: max`, scoped by immutable main/head SHA.
Previously a no-op CI `workflow_run` could replace/cancel a main `push` submission
before its job-level condition was evaluated. Eligibility now runs before the
job enters the queue. Requested/in-progress duplicate wakes cannot interrupt a
valid submission. Recovery still authenticates actual current-main bot origin;
PR submission still loads trusted source, treats PR lockfiles only as bounded
data and rechecks exact head/base immediately before submitting. `ACCEPTED` and
`SUCCESS` API responses are acknowledged; incomplete graph comparison remains a
hard CI failure. An already missing historical base snapshot needs a separate
bounded recovery of that exact current-main submission.

## Candidate validation and publication

CI invokes `release-validation.yml` with `publish: false`. It has only read
permissions, asserts the exact checkout commit, rejects `publish: true`, and
contains no publication job. All existing release validation commands and five
platform tuples are compared against `release.yml` in an executable parity test.
Manual `Release` now exposes boolean `publish`, default `false`. With false,
all validation runs without signing or publication. Explicit true is accepted
only for an existing annotated SemVer tag at exact current main with ready
release notes; a branch dispatch fails tag validation. Both full validation and
all five platform builds must succeed. The publisher revalidates the current-main
tag before consuming this run's artifacts, signing and publishing the unchanged
asset set. Tag-push behavior remains available. A candidate pass is
not a release, tag, approval or authorization to publish.

DocC artifacts are built without Pages/repository write permissions. A trusted
main `docs-publish.yml` workflow uses only GitHub APIs and a checked-in trusted
publisher. It neither downloads nor executes source/artifact contents. It checks
source workflow identity, current run attempt, app/suite/job/check linkage,
required validation steps, artifact identity/digest, and exact current main twice
before deploying through the existing Pages configuration. The root and every
module URL are smoke-tested afterward in a separate read-only job. PRs, old main commits,
failed runs and unverified manual dispatches cannot publish. `DocC Pages` manual
runs produce preview artifacts only. Main push CI and authenticated Dependabot
recovery CI can publish; publication does not alter Pages settings.

The package is already listed in the public Swift Package Index package list.
`.spi.yml` points to the same DocC root as README. The policy verifies that DocC's
product inventory equals the manifest's exported library products. Local examples
continue to resolve the root package by relative path; they acquire no separate
root/Syntax pins. Root lock source URLs, immutable revisions and supported ranges
are checked offline, and existing hosted SwiftPM resolve/no-drift checks remain.
The standalone OpenAPI tool's remote dependency is included in Dependabot.

## Dependabot and trusted coordinator

Actions run weekly Monday 09:00 Asia/Seoul, Swift Monday 09:30. Minor/patch updates
are grouped by ecosystem; SwiftSyntax/toolchain and majors stay individual, not
ignored. All are eligible only after the same full exact-head validation.
Existing open Dependabot PRs are not closed, edited or merged by this change.

The default is standby: `DEPENDABOT_AUTO_MERGE_ENABLED` must be exactly `true`
before any bot auto-merge is enabled. The coordinator checks same-repository
Dependabot login/id/type, current main/base/head and exact test-merge parents,
latest CI run and attempt, all 32 concrete jobs and validation steps, associated
GitHub Actions app IDs, paginated check/status results and reviews. A failed,
pending, skipped, duplicate, foreign or stale result blocks. Required review,
requested reviewers and unresolved threads are not waived. No title/version
heuristic exempts a major update.

The writer loads trusted main scripts only, never PR code, artifacts or caches.
`Dependabot Ready` is now an unconditional native `pull_request_target` check,
using immutable `github.workflow_sha` source and read-only permissions. Human PRs
receive a policy pass without auto-merge approval. Bot readiness requires the full
current proof and enabled flag. No API creates or patches a Ready conclusion.
The native run title and evaluation step bind PR number, exact head, head/base
repository IDs, base main and immutable source. This also supports legitimate
fork runs whose REST `pull_requests` association is empty without treating branch
or display-name matches alone as provenance.

The trusted coordinator can request only a bounded rerun of a verified native
Ready reporter when its verdict changed. It verifies current attempt, source
compatibility and prior writer claims before its single request; uncertain
writes are read back, never blindly retried. Historical native/coordinator
transport checks are excluded only with exact job/app/head/suite/source binding.
The literal unevaluated skipped matrix name is allowed only for an empty native
skip paired with a successful immutable-source inspector. Serialized writers
retain pending jobs with `queue: max`.

Native `enablePullRequestAutoMerge(expectedHeadOid: ...)` happens only after
repeated CI/metadata/native-Ready reads. No immediate merge API or bypass path
exists. Native strict checks and required PR/resolved-thread rules must be
verified, including the runtime token's explicit never-bypass signal; missing
protection evidence leaves the coordinator in standby. No repository setting or
approval count changes here. Metadata reconciliation can revoke ineligible bot
auto-merge approvals. Scheduled discovery includes retargeted open bot PRs;
normal default-branch `edited` delivery also reaches the cancellation path.

GitHub events cannot form an atomic lock with the merge operation. A review or
new failing external check can race the final proof and native completion.
Strict native required checks and the repository's existing native review rules
are the safety boundary; scheduled/event reconciliation reduces, but cannot
eliminate, this residual race. Do not describe the coordinator as race-free.

## Activation is a separately approved operation

This PR does not change repository settings, rulesets, permissions, review rules,
credentials, the standby flag or existing PR merge state. After reviewing and
merging the automation, maintainers must separately:

1. Wait for the exact new main full CI, docs and snapshot results. Confirm all
   actual job/step names match the reviewed fixture; a fixture is not live proof
2. Export the complete current native rulesets and review requirements. Preserve
   existing review rules and unrelated checks. Add strict GitHub Actions app
   `15368`-bound `CI Required` and `Dependabot Merge Ready` checks from
   `.github/automation-required-status-checks.json`. Do not replace the full
   ruleset with this small checks-only manifest
3. Audit every applicable repository/inherited ruleset and GitHub Actions bypass
   permission with an appropriately authorized account. Verify the coordinator
   has no bypass. An API-redacted/missing bypass list is not an empty list; do not
   create an admin credential just to bypass this prerequisite. Unsupported or
   unverifiable inherited protection must remain blocked
4. Confirm native squash/auto-merge support and the app's least-privilege check,
   PR, contents and Actions permissions, without loosening required review
5. Verify standby behavior and a fresh full Dependabot PR (major/toolchain
   eligibility requires the same proof). Set the flag last, only with explicit
   approval; clearing it and cancelling pending native auto-merges disables it

The coordinator recovers `GITHUB_TOKEN`-suppressed main push events by locating
an actual same-repository Dependabot PR whose merge SHA equals current main.
It dispatches only the fixed main CI with a verified PR marker and checks for an
existing native/recovery run first. A moved main or uncertain dispatch fails
closed. That marker is reverified inside CI. The dependency snapshot workflow
independently authenticates the recovery run/bot/current-main relationship;
Pages waits for successful verified main CI. Recovery cannot cancel a native
main CI because their concurrency keys differ. It does not retry a failed main
CI, publish a release, or retag anything.

## Existing 6.1 candidate integration order

PR #132 (`7957642bca41773bae12a5e201ed063d3e4ca08c`, observed 2026-10-01)
is independent and unchanged.
Its companion InnoNetwork-Protobuf PR #2 is also unchanged. Its broader feature/API and companion-release scope is not changed here.
Open bot PRs #134–#137 likewise remain untouched; dependency base-snapshot
failures are distinct from their existing contract, benchmark and test failures.

The safe proposed order is automation review/full CI and a separately approved
merge first; then rebase #132 on that new main, reconcile CI/CODEOWNERS/consumer
contract overlap, add its tenth product and macro-support checks to both the
inventory and coordinator proof, and rerun its exact-head full candidate CI.
If #132 lands first, rebase this automation instead and redo that inventory
mapping before merge or activation. Never copy a green result between heads.
The companion's public dependency-resolution gate still waits for a separately
approved core 6.1 release; pinned paired-candidate success does not replace it.

## Local verification boundary

The cloud Linux VM can run Python/Ruby policy tests, adversarial API transcripts,
YAML/actionlint, shell fixture tests and the old static contract validators. It
cannot run Apple-only Swift/Xcode builds. Report hosted Apple results separately
and only for the actual uploaded commit. This branch may be uploaded as Draft;
no full Swift pass, merge, Ready approval or publication is implied by local
policy success.
