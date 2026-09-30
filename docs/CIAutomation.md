# CI and dependency automation

## Scope and preserved contracts

This change starts from `main` at `9d8053d5f921ebf5c38cc2f816efe90c7db4a450`.
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
the declared plan and accepts success for selected jobs and skipped only for
explicit non-targets. Failure, cancellation, unexpected skips, missing jobs and
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

## Candidate validation and publication

CI invokes `release-validation.yml` with `publish: false`. It has only read
permissions, asserts the exact checkout commit, rejects `publish: true`, and
contains no publication job. All existing release validation commands and five
platform tuples are compared against `release.yml` in an executable parity test.
The existing tag-only release workflow, main-tag validation, signature generation,
release asset set and publication conditions are unchanged. A candidate pass is
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
Manual PRs receive the Ready policy check without enabling auto-merge. Native
`enablePullRequestAutoMerge(expectedHeadOid: ...)` is used, with a pending Ready
check while the proof is re-read. No immediate merge API or bypass path exists.
Metadata reconciliation cancels ineligible approvals and native auto-merge.
Scheduled discovery includes retargeted open PRs to repair missed, delayed or
suppressed lifecycle notifications. [Current GitHub documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target) places
`pull_request_target` in the default-branch context, so normal `edited` delivery
can already reach the cancellation path; retargeting is not assumed to suppress
that event. This is reconciliation hardening, not proof of a native merge bypass. Write outcomes are read
back; uncertain writes are never blindly retried.

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

PR #132 (`79e1900ed283c129ab9523c7661c2f1a8e9cdc3c`) is independent and unchanged.
Its companion InnoNetwork-Protobuf PR #2 is also unchanged. Their known Periphery
and artifact transport failures are not repaired by editing runtime code here.

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
