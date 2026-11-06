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
- Android/Web packages, their consumer smoke trees and the scripts only their
  lanes run, except Markdown: policy, Dependency Review and CodeQL. See
  [Android and Web changes](#android-and-web-changes)
- Prose/SPI/site docs: docs contract checks, full DocC site and policy tests
- Known individual workflows: their mapped lanes and policy tests
- Dependabot of every update type, or a `release-validation` label: full lane
- `concurrency-review`: explicitly requests TSAN even for an otherwise narrow PR
- Main/manual/merge queue: full lane, except PR-only dependency comparison

The old 15 display names and `.github/required-status-checks.json` remain the
logical coverage inventory. The actual native check list is the two app-bound
aggregates in `.github/automation-required-status-checks.json`; the legacy list
must not be restored as native requirements for path-selected/metadata runs.
Consumer Smoke still requires all three independent consumer lanes.
The baseline fixture asserts all old runner/matrix/test command contracts. Full
PR validation expands to 34 concrete jobs, including six release candidate jobs.
Scheduled/manual CodeQL, TSAN and benchmark entry points remain; their former
PR work now lives in CI and cannot escape the aggregate. Benchmark PR comments
are replaced by preserved artifacts, so PR benchmark code no longer holds
issue/pull-request write credentials. Scheduled trend append remains separate.

## Android and Web changes

`Platforms/Android`, `Platforms/Web`, the `SmokeTests` Android, Web,
WebTarball, React and Browser consumers, and the scripts listed in
`PLATFORM_SCRIPTS` in `Scripts/ci-policy.py` are not SwiftPM inputs.
`Package.swift` names every target path (`Sources/`, `Tests/`, `Benchmarks/`,
`SmokeTests/InnoNetwork*`), and no Apple job in `ci.yml`, step in
`release-validation.yml` or composite action refers to these paths. A change
confined to them selects the policy job, Dependency Review (npm locks are in
the dependency graph) and both CodeQL jobs. `codeql-cross-platform` is the only
`ci.yml` job that compiles Android and Web, and the Swift CodeQL job comes with
it because CodeQL uploads all three configurations or none (see below). The
path-filtered `cross-platform.yml` workflow still builds and tests the change.
For the 15 files of #177 this skips benchmarks, build and test, the consumer
lanes and the release candidate.

The rule runs before the release-name rule, because Gradle's
`libs.versions.toml` is a dependency catalog, not Swift release metadata.
Markdown keeps the docs rules. A Swift, shared or unknown path in the same PR,
or any deletion, rename or mode change, still selects the full lane. So do
Dependabot PRs and the `release-validation` label, since the Dependabot
coordinator's proof expects the full job set. `test_ci_policy.py` fails when an
Apple job, `Package.swift` or another script starts reading these paths, or
when `cross-platform.yml` stops covering one of them.

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
the full PR's 34 concrete jobs, mandatory steps and native app/suite/job/check
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

CodeQL keeps its original uncached build/analyze/SARIF path and permissions.
The first hosted run completed CodeQL analysis but failed the newly added cache
post-check because its before/after fingerprint did not agree. The exact changed
identity field was not exposed in that log. CodeQL's independently instrumented
build environment is outside this cache observation contract; removing only its
cache wrapper avoids weakening the strict identity checks for other lanes.

Scheduled CodeQL records Swift, java-kotlin and javascript-typescript
configurations on main. When a PR uploads only some of them, GitHub reports the
PR's CodeQL check as neutral ("configurations not found"), and the Dependabot
coordinator blocks on any non-success extra check. So whenever CI plans CodeQL
it uploads all three: the Swift job is unchanged, and `codeql-cross-platform`
repeats the scheduled Android/Web builds without caches or conditional steps.
The planner always selects both jobs together.

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

## Benchmark evidence follow-up

The `f7b6f8e` run retained a -23.77% paired throughput regression for
`events/task-event-fanout-single` with unchanged runtime and benchmark sources.
Its three pairs were -25.10%, -23.77%, +5.29%, and no binary hash or CPU profile
was captured, so the original cause remains unresolved. The next measurement
adds bounded process-boundary provenance and fixed same-binary/order controls
as documented in [Benchmarks](../Benchmarks/README.md#ci-sample-provenance-and-bounded-diagnostics).
The original 20% gate, complete-delivery workload, baseline and runtime code are
not changed. Diagnostic results cannot turn an original failure into success.
Malformed/nonfinite data and unmatched workloads are rejected before any
performance verdict, and executable/build failures do not launch more controls.

Dependabot #157 (`2233b25841df37000d06564c6a7f325c70213011`) also retained a
28.96% paired throughput regression for `persistence/append-log-compaction`
(20% limit, 42.98% pair spread) in run `38194730770`. Its captured base/head
`Sources`, `Benchmarks`, root manifest and lock identities and measured file
hashes all agree; its separately built binary hashes differ. The PR changes
only the standalone OpenAPI tool's Yams dependency. This supports investigating
measurement/build variation, not attributing the result to a runtime source
change or declaring the gate passed. The existing fixed controls measure only
the event-fanout workload and cannot diagnose this compaction failure.

Noise-driven guard failures (2026-11-05). PR #179 (CI policy) and PR #177
(Android only) failed `client/request-pipeline` (-25.18%, pairs -31.16/-25.18/
+9.36) and `events/task-event-fanout-single` (-29.61%, pairs -40.48/-29.61/
-4.89) with identical runtime sources. Across the 66 identical-source CI
comparisons from 2026-10-06 to 2026-11-05, 10 failed (15.2%); all 16 failing
guards had at least one pair inside the limit, and none had every pair beyond
it. Within-run pair noise (about 8-18 percentage points standard deviation per
guard) dominates between-run noise (about 3-9), so more pairs in the same job
are effective.
The comparator now reports such guards as inconclusive (exit 3, bound receipt)
and the runner measures one fixed round of four more pairs; only those guards
are re-judged by the 20% limit on the median of all seven pairs. A guard whose
three pairs all exceed 20% still fails without confirmation. See
[Benchmarks](../Benchmarks/README.md#inconclusive-guards-and-the-confirmation-round).

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

The publisher treats `syncing_files`, `finished_file_sync`, `updating_pages`,
and `purging_cdn` from the [GitHub Pages status schema](https://github.com/github/rest-api-description/blob/6b4be6b6054d4e344ba0e57c89ff6be99427fa23/descriptions/api.github.com/api.github.com.json),
plus the exact `deployment_queued` value observed in a
[real Flow deployment response](https://github.com/InnoSquadCorp/InnoFlow/actions/runs/36887168389/job/110453338248),
as intermediate states. They never count as success: only `succeed` does.
The existing 600-second deadline, 120-poll cap, terminal failures, cancellation,
and immutable source/artifact checks remain in place. Unknown values are escaped
and logged before cancellation, including when the cancellation request fails.
This protocol fix has offline state-machine coverage; Network's actual privileged
Pages publication remains a separate post-merge verification.

The package is already listed in the public Swift Package Index package list.
`.spi.yml` points to the same DocC root as README. The policy verifies that DocC's
product inventory equals the manifest's exported library products. Local examples
continue to resolve the root package by relative path; they acquire no separate
root/Syntax pins. Root lock source URLs, immutable revisions and supported ranges
are checked offline, and existing hosted SwiftPM resolve/no-drift checks remain.
The standalone OpenAPI tool's remote dependency is included in Dependabot.

## Dependabot and trusted coordinator

Actions run weekly Monday 09:00 Asia/Seoul, Swift Monday 09:30, Web Monday 10:30.
Gradle runs monthly and is always replaced by a maintainer, as described
below. Minor/patch updates
are grouped by ecosystem; SwiftSyntax/toolchain and majors stay individual, not
ignored. All are eligible only after the same full exact-head validation.
Existing open Dependabot PRs are not closed, edited or merged by this change.

The default is standby: `DEPENDABOT_AUTO_MERGE_ENABLED` must be exactly `true`
before any bot auto-merge is enabled. The coordinator checks same-repository
Dependabot login/id/type, current main/base/head and exact test-merge parents,
latest CI run and attempt, all 34 concrete jobs and validation steps, associated
GitHub Actions app IDs, paginated check/status results and reviews. A failed,
pending, skipped, duplicate, foreign or stale result blocks. This includes
third-party checks, so CodeRabbit does not publish its review progress check:
it skips bot PRs, and the skipped check would block every Dependabot head.
Required review, submitted blocking reviews and unresolved threads are not
waived. Optional
requested reviewers/teams do not veto auto-merge by themselves; submitted
`PENDING`/`CHANGES_REQUESTED`, native `REVIEW_REQUIRED` and unresolved threads
still block. No title/version
heuristic exempts a major update.

The writer loads trusted main scripts only, never PR code, artifacts or caches.
`Dependabot Ready` is now an unconditional native `pull_request_target` check,
using immutable `github.workflow_sha` source and read-only permissions. Human PRs
receive a policy pass without auto-merge approval. Bot readiness requires the full
current proof, enabled flag and a verified native-arm receipt for this exact
reporter rerun. An ordinary proof-only bot snapshot stays false, preventing a
second lifecycle reporter from releasing the gate while arming is incomplete.
No API creates or patches a Ready conclusion.
The native run title and evaluation step bind PR number, exact head, head/base
repository IDs, base main and immutable source. This also supports legitimate
fork runs whose REST `pull_requests` association is empty without treating branch
or display-name matches alone as provenance.

Read-only REST responses can omit repository merge-setting fields. The reporter
then queries the same repository's GraphQL settings, binding both numeric ID and
full name and requiring real true booleans. Explicit false, malformed values,
disagreement or unavailable evidence still block; no permission is expanded.
This does not change native protection or the meaning of Ready.

Read-only reporters have independent per-PR/run concurrency groups. Admission
order is not workflow run-number order, so an older admission must not cancel a
newer reporter. The latest run/attempt and exact PR/head/source are still checked
before and after evaluation; a cancelled latest reporter never falls back to an
older successful verdict. A superseded event-bound reporter cancelled before
runner assignment may have a real native check with zero steps. Only a verified
historical cancelled run/job/check with no assigned runner and exact native
identity is attributed as transport, never as a successful Ready verdict. A
previous attempt of the same rerun is additionally read from its authoritative
attempt endpoint and checked against the run's immutable identity.

The trusted coordinator can request only a bounded rerun of a verified native
Ready reporter when its verdict changed. It verifies current attempt, source
compatibility and prior writer claims before its single request; uncertain
writes are read back, never blindly retried. Every wake that sees the same
failed reporter plans the same refresh, and the per-PR group admits those
writers in no fixed order. A separate claim step therefore decides first: a
writer defers when an older writer for the same reporter attempt is still
queued, and a writer that defers or stops in its claim leaves its request step
skipped. A skipped request proves no rerun was asked for, so the last writer
admitted makes the single request. A request step that ran without a confirmed
rerun still blocks every later writer for that attempt. Historical native/coordinator
transport checks are excluded only with exact job/app/head/suite/source binding.
The literal unevaluated skipped matrix name is allowed only for an empty native
skip paired with a successful immutable-source inspector. Serialized writers
retain pending jobs with `queue: max`. The planner waits for bot coordination;
the refresh writer may retain an armed bot only with its exact successful
coordinator receipt and fresh matching proof. All coordinator checkouts use
immutable `github.workflow_sha`, matching the definition that ran.

Native `enablePullRequestAutoMerge(expectedHeadOid: ...)` occurs behind a verified
terminal failed native Ready barrier, after two matching full proofs. A third
full proof and the unchanged failure barrier are required after enabling, before
emitting a receipt. No immediate merge API or bypass path exists. App-bound native checks and required PR/resolved-thread rules must be
verified, including the runtime token's explicit never-bypass signal; missing
protection evidence leaves the coordinator in standby. No repository setting or
approval count changes here. Metadata reconciliation can revoke ineligible bot
auto-merge approvals. Scheduled discovery includes retargeted open bot PRs;
normal default-branch `edited` delivery also reaches the cancellation path.

### Rebasing Dependabot PRs onto current main

The coordinator proves only a bot PR whose base is current main. After any main
push, every other open Dependabot PR is blocked until it is rebased, and
Dependabot does not rebase a PR that is only behind. `dependabot-rebase.yml`
moves one PR at a time. On a main push, a completed PR CI run or the hourly
schedule, it waits while any Dependabot PR is rebasing, running CI or waiting
for auto-merge, then comments `@dependabot rebase` on the oldest behind PR.
Rebasing every PR at once lets only one merge and spends full CI on the rest.
A failed CI, a green PR still open an hour later, or a command left unanswered
for an hour releases the queue to the next PR. Gradle PRs are skipped, as the
next section explains.

Dependabot answers only users with push access, so the command cannot come
from `GITHUB_TOKEN` or a GitHub App. The comment is posted with the optional
`DEPENDABOT_COMMAND_TOKEN` secret: a fine-grained token of a user with push
access, limited to this repository with Pull requests read/write. Every read
uses the read-only job token. The secret appears only in that step, and the
coordinator workflow itself still has no secret. Without the secret the job
only logs its plan, and it does not run while `DEPENDABOT_AUTO_MERGE_ENABLED`
is not `true`.
A command holds the queue only when its author currently has write access to
the repository. A MEMBER or COLLABORATOR association alone does not mean that.
The token owner's write access is checked the same way before the job posts,
so a refused command is never posted again on every wake. Commands count only
after main actually moved to its current SHA, taken from the repository
activity record, not the commit date, which can predate the push. If
Dependabot still refuses a command, the job warns and moves on.

### Gradle updates land through a human replacement PR

Dependabot cannot write Gradle dependency-verification metadata
([dependabot-core#1996](https://github.com/dependabot/dependabot-core/issues/1996)).
`Platforms/Android` and `SmokeTests/AndroidConsumer` set `verify-metadata` to
true, so every Gradle PR fails CI at its first new artifact. An OkHttp patch
fails just like an AGP update. A wrapper update also fails
`check_android_wrapper_integrity.sh`, which pins the distribution URL and the
distribution and wrapper JAR checksums. #169 hit both and also needed code
changes: Kotlin 2.4.21 and KSP 2.3.12 deprecations broke the build under
`allWarningsAsErrors`. #177 replaced it.

Gradle Dependabot PRs are therefore monthly tickets, not merge candidates.
Gradle dependencies are not submitted to the dependency graph, so these PRs are
also the only automated signal of Android updates, and they stay enabled. The
rebase queue skips `dependabot/gradle/` branches, so a ticket neither holds the
queue nor reruns full CI after every main push. Its CI fails by design, and the
coordinator never arms it.

A maintainer replaces each ticket:

1. On a branch from current main, apply the ticket's versions. For a wrapper
   update, run the Gradle `wrapper` task with the official distribution
   SHA-256. Then pin the new URL and both checksums in
   `Scripts/check_android_wrapper_integrity.sh`
2. Run `Scripts/regenerate_android_verification_metadata.sh` with JDK 17. It
   empties both component lists and runs every Gradle task CI runs in a fresh
   Gradle user home. A warm cache skips POM and `.module` files that a clean
   CI runner still verifies. AGP resolves only the host's aapt2 jar, so the
   script adds the other hosts' jars from Google Maven after checking each
   against the published SHA-1. Both files must stay strict
3. Review the component diff. Accepting new groups and transitive artifacts is
   the decision these files record. Fix any code the update breaks, then run
   `Scripts/check_cross_platform.sh`
4. Open the replacement PR and link the ticket. Dependabot closes the ticket
   once main has its versions; otherwise close it by hand

Regenerating the metadata in CI and pushing it to the Dependabot branch was
rejected:

- A `GITHUB_TOKEN` push starts no CI, so the coordinator would never see an
  exact-head validation. It would need a new push-capable credential
- Generation runs the new plugins and compiler before anything verifies them.
  The writer would either run them while holding that credential or consume a
  PR artifact, and privileged workflows here never do either
- Hashes accepted with no review would make strict verification
  trust-on-first-use for every bot update, and the coordinator would merge them
- Dependabot stops rebasing a branch with a pushed commit unless the commit
  says `[dependabot skip]`. Then every rebase drops the commit, so each rebase
  runs CI twice
- It still cannot fix updates that need code changes, like #169

### Existing native integration profile

The observed main ruleset uses the two aggregates and an explicit `strict=false`.
The coordinator respects either boolean strict setting without changing it.
Missing, null, numeric and string values fail closed. The same current
main/base/head, ordered test-merge parents, latest full CI run/attempt and native
Ready identity are still verified repeatedly before native enable. This policy
alignment changes no required checks, approvals, bypass actors or token scope.

`check_required_status_checks.py --ruleset-json <export>` audits both explicit
native profiles and keeps the logical fifteen-check inventory independently
enforced. It requires the complete main-scoped, active repository ruleset,
GitHub Actions app identity, resolved review threads and an empty bypass list.
`--require-auto-merge` additionally requires the complete export; it no longer
requires changing the native strict setting. Neither mode proves live CI/Ready,
the enable flag, runtime no-bypass capability, all inherited protection, or
permission to merge. Other applicable protections still need their own audit.

Network uses a read-only native Ready reporter, unlike repositories with an
API-written gate. A clean PR with Ready already green must first refresh back to
false while unarmed. Enabling is allowed only against the latest controlled
failed reporter run/attempt/job/check. GitHub owns the native verdict throughout.

The coordinator performs two identical full proofs, enables expected-head squash
auto-merge, reads back the exact request, rechecks the full proof and the same
failed barrier, then emits a receipt. Its final receipt step and exact `bot-ready
(PR)` job must both finish successfully; the entire workflow need not finish,
which avoids a planner/refresh dependency cycle. A crash, failed step or lost
receipt never authorizes Ready success and causes protective cancellation.

The receipt binds a canonical SHA-256 of PR/node/head/base/test-merge/CI run and
attempt, exact failed reporter run/attempt/job/check, immutable coordinator source
and the current native request. Request identity includes method, Actions bot
identity, enabled timestamp and the latest unique enable/squash timeline event
ID. Request and event timestamps need not be identical, but each must fall
inside the successful issuing job's execution interval. [AutoMergeRequest](https://docs.github.com/en/graphql/reference/pulls#automergerequest)
has no unique request ID; the event ID also distinguishes disable/re-enable
within the same timestamp. Disabled/rebase events, malformed identity and any
changed request fail closed. No credential or new permission is involved.

A receipt is trusted only through authoritative Actions workflow/run/attempt,
job/check app/suite/URL, successful source inspector and successful receipt step.
Background runs are bound to their main source, not mistaken for PR-head runs.
Untrusted run origins are filtered from list metadata before detail/job reads,
then revalidated against the authoritative detail before receipt text is
interpreted. Ready planning and refresh wait for bot coordination but may
continue after a sibling matrix leg fails; cancelled/unknown results remain
blocked. Each PR still requires its own successful receipt job and fresh proof,
so an aggregate failure neither approves that failed leg nor suppresses an
independently verified sibling. Before
any enable, the current issuer run/attempt is verified and must have been created
no earlier than the selected reporter, matching bounded receipt discovery. An
older queued coordinator defers to the next reporter completion wake.
The read-only reporter can succeed only at exactly the original failed attempt
plus one, with fresh full proof matching the receipt. Queued/running handshakes
are preserved only after the same request and original failure are reverified;
empty pending jobs exempt no check IDs and never count as successful evidence.
A newer lifecycle reporter, failed/cancelled rerun, attempt+2, moved head/base/CI,
new blocker, obsolete source or ambiguous receipt causes protective cancellation.

Unknown enable responses receive one authoritative outcome read, never a blind
retry or direct merge fallback. The refresh writer still verifies durable writer
claims before its bounded single rerun. Missing receipts or uncertain cancellation
remain errors or blocked decisions, not permission to invent Ready success.

Metadata-only CI also verifies authoritative `git/ref/heads/main` before and
after its proof, alongside head/base, ordered merge parents, source tree,
labels, attempt and native check identity. A checkout or validation on an
older main passes only with the main-moved equivalence proof (default-on
`INNO_MAIN_MOVED_REUSE`); without that proof a main advance fails, as does
same-SHA retargeting. Human PRs retain their read-only Ready flow and are never
automatically merged by this coordinator.

### Metadata-only gate

A non-lane `labeled`/`unlabeled` event or a body-only `edited` event starts a
metadata-only CI run. Every validation job is skipped. Only `CI Required` runs,
and it calls `verify-ci-metadata.py` once within its 5-minute limit. It succeeds
only when the latest real validation of the exact head, base and lane labels has
already succeeded. Anything else, including an obsolete head, fails at once.
Dependabot edits the PR body on every rebase, and review bots edit it after
pushes, so these runs are frequent.

The cached PR base (event payload, PR API and run title) can stay at the
branch's old merge-base after main advances, while `refs/pull/N/merge` is
already rebuilt on current main. On PR #173 the payload kept `b46900d` while the
merge `f21e04cf` had parents `[8977ec2, ac46a07]`, so a body-edit gate rejected
the merge its own validation had tested, and re-running it could not help. The
gate now reads the base from the checkout: a first parent other than the cached
base counts only when the second parent is the head, the first parent is the
authoritative `git/ref/heads/main`, and `compare/{cached}...{parent}` is a
fast-forward from the cached base. The validation title's base is resolved the
same way from its `source` commit, so a validation of the same merge is reused
directly and a regenerated one still needs an identical tree. A first parent
that is neither the cached base nor current main, or reversed parents, still
fails. A checkout or validation on an older main passes only with the
main-moved equivalence proof above. The PR binding keeps comparing the cached
base, so a base refresh during the proof also fails.

GitHub does not document how it picks among same-name checks in different check
suites. PR #139 merged without a bypass even though an older suite had a failed
`CI Required` and a newer suite a successful one. PR #142 first gave metadata
runs no `CI Required` at all, and the required check stayed Expected. GitHub may
therefore judge the newest suite. So a metadata run must report the real verdict
itself, after its validation has finished.

With job cancellation on, each PR run is admitted by head, base branch and lane
labels. A metadata run shares that group with its validation and waits in the
`max` queue without a runner. It then proves the finished run in one call.
A new head, retargeted base or lane change still gets its own group and starts
at once. Older-head metadata runs wait for their own head's run, which job-level
cancellation shortens, and then fail immediately.

`ci-metadata-policy.py` gives the coordinator, native Ready and main reuse the
same view. Every attempt of a metadata run must still show only skipped
validation jobs and a skipped real aggregate step. Only the latest attempt is
the run's verdict, so a timed-out or cancelled earlier attempt no longer blocks a
successful rerun. A failed or cancelled latest gate keeps blocking until that run
is re-run, or until a newer metadata run with a newer check proves validation. A
later aggregate from the older validation suite never replaces it.
Exemption never counts as validation, and every other gate result blocks.

A gate can still fail first if it is admitted before a newer validation of the
same head, for example after a lane label change. Re-run that metadata job once
the validation succeeds. Nothing reruns it automatically.

GitHub events do not form an atomic lock with merging. `expectedHeadOid` pins
the head, not main after the final read. With `strict=false`, an unobserved main
advance after the final proof can race native completion; repeated reads do not
supply strict base protection. New blocking reviews or external results can
also race. GitHub enforces the configured native checks/review rules; this
coordinator is not race-free and makes no stronger guarantee than that policy.
Fresh exact-main validation remains required for release/publication.

## Native Ready bootstrap and recovery

Installing or changing the trusted Ready workflow/policies does not create a
native reporter for every already-open PR. The initial main deployment at
`d4a569c58b9a190b2798f84c104cce63d686064e` demonstrated this: bulk planning reached
manual draft #132 before bots #134–#137 and stopped because #132 had no reporter.
Fresh events later gave #137 a reporter, but its single-PR planner success did
not establish recovery for the other open PRs.

The planner now isolates two verified lifecycle gaps per PR:
`missing_native_reporter` and `obsolete_reporter_policy`. It emits their exact
PR/head pairs in `blocked` and the job summary, excludes them from rerun
`targets`, and continues planning other PRs. An empty `targets=[]` means the
refresh writer is intentionally skipped. A successful planning job is **not**
a successful Ready verdict. Missing/obsolete reporters still fail the native
Ready requirement and cannot arm bot auto-merge. API/permission errors,
malformed identities, foreign ancestry, invalid provenance and ambiguous
reporter failures still fail the whole plan without publishing partial targets.

Bootstrap remains a separately authorized maintainer action:

1. After deploying the change to trusted main, read the latest bulk planner
   summary and recheck each listed PR's current head, open state and main base.
   Record the exact heads; stop/replan if they moved. This policy change itself
   makes old reporter policy blobs incompatible, including a previously seeded
   #137 reporter, so inspect **all** currently open PRs rather than relying on
   the original four-PR incident list
2. With approval for the specific PR metadata change, use the GitHub UI or a
   maintainer-authenticated API/CLI to make one appropriate real event already
   subscribed by `dependabot-ready.yml`, such as `edited`, `labeled` or
   `unlabeled`. Preserve the intended title/body/labels and draft state; do not
   close/reopen a PR or mark draft #132 ready merely to seed a check. These
   metadata events also trigger ordinary PR CI. If temporary metadata needs
   restoration, include that restoration in the approval and verify the newest
   resulting reporter after both events. No such metadata mutation is performed
   by the planner
3. Verify GitHub created a **new** `pull_request_target` run of the fixed
   `Dependabot Ready` workflow. Its trusted title/evaluation step must bind the
   current PR number, exact head, head/base repository IDs, main base and new
   immutable trusted source. Confirm the native GitHub Actions app/job/suite
   association and successful evaluation. A bot in standby must still finish
   with the deliberate failing Ready verdict; a manual PR may pass the policy
   check without authorizing auto-merge or removing draft/review requirements
4. Verify a subsequent bulk planner no longer lists these exact PR/head pairs
   as lifecycle-blocked, and independently verify every required CI/review/Ready
   gate before considering merge eligibility. If no event appears or provenance
   is invalid, leave it blocked and diagnose the event rather than synthesizing
   a green check. Enabling the bot flag remains separately approved

There is no supported first-run bootstrap using the existing read-only reporter
and bounded Actions rerun writer. A [workflow dispatch](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)
requires `workflow_dispatch`; adding that event would not preserve this
`pull_request_target` PR-head provenance contract. [Rerunning](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)
retains the original event's SHA/ref and privileges, so it cannot create an
absent run or refresh an obsolete workflow definition. Mutating labels with
the workflow's [GITHUB_TOKEN](https://docs.github.com/en/actions/concepts/security/github_token)
does not trigger the needed new run. Do not work around these boundaries with
new credentials, broader permissions, fabricated status/check results, or an
automatic edit/label/close/reopen loop.

## Activation is a separately approved operation

This PR does not change repository settings, rulesets, permissions, review rules,
credentials, the standby flag or existing PR merge state. After reviewing and
merging the automation, maintainers must separately:

1. Wait for the exact new main full CI, docs and snapshot results. Confirm all
   actual job/step names match the reviewed fixture; a fixture is not live proof
2. Export the complete current native rulesets and review requirements. Preserve
   existing review rules and unrelated checks. Autonomous activation requires
   GitHub Actions app
   `15368`-bound `CI Required` and `Dependabot Merge Ready` checks from
   `.github/automation-required-status-checks.json`. Do not replace the full
   ruleset with this small checks-only manifest.
   The existing explicit `strict=false` policy is supported without changing it.
   Any protection-setting change still needs separate approval; release
   preparation is not that approval
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
It dispatches only the fixed main dependency snapshot workflow and the fixed
main CI with a verified PR marker, and checks for an existing native/recovery
run first. A moved main or uncertain dispatch fails closed. That marker is
reverified inside CI. The snapshot is dispatched directly because a
`GITHUB_TOKEN`-dispatched CI run never wakes the snapshot workflow's
`workflow_run` trigger (#155, #157 and #160 each left current main without a
base snapshot, failing every bot PR's Dependency Review until a manual
submission). It goes before CI, so an uncertain CI dispatch leaves the plan open
and the next wake dispatches both again; a duplicate submission of the same
main SHA is harmless. Pages waits for successful verified main CI. Recovery
cannot cancel a native main CI because their concurrency keys differ. It does
not retry a failed main CI, publish a release, or retag anything.

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
