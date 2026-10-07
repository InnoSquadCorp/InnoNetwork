# Opt-in stale validation cancellation

Status: executable workflow wiring proposed in a draft PR; activation is separate.
This change does not set the repository variable `INNO_JOB_CANCELLATION`.
Only the exact value `enabled` activates the new PR behavior.

## Admission and immutable workload scopes

- Feature-off retains the exact prior outer workflow group, cancellation and
  metadata queue behavior. Additional job groups are run/attempt-unique, so they
  introduce no cross-run serialization/cancellation when disabled
- Feature-on PRs receive unique outer admission groups and disable whole-workflow
  cancellation. Only reviewed validation jobs get a stable active job key
- Keys distinguish repository, caller workflow, workflow file, job workload,
  PR/base branch, validation label lane and reviewed matrix cell. Release-validation
  never collides with ordinary validation; run-asan/concurrency-review are included
  where those labels affect the repository contract
- Planners, final aggregators, metadata observers, state/history writers and
  permission-bearing external upload/security jobs are excluded. Reusable callers
  containing unthreaded child aggregates/writers remain a documented safe fallback
- Dedicated release/publication/history workflow concurrency is unchanged

## Product partition before job admission

The existing CI Plan step now emits `product-key` via `ci_product_key.py`.
It reads exact Git anchors, the manifest-bound reviewed dependency graph and
regular changed source modes, then hashes the selected product/target workload.
No Swift/Xcode/compiler/build is invoked. Candidate SHA/run ID is not in the
stable workload digest. The digest only partitions cancellation; it grants no
permission to narrow compilation or skip a test.

Uncertain/missing/unknown/mixed/type-changed/generated/untracked inputs return an
empty key. A product-scoped job without a key remains run-unique and cannot
cancel another run. Reusable product leaves accept an optional `product-key`
input from their caller; direct legacy invocations without it under-cancel safely.
Fixed full-package test jobs use their fixed job workload, not a source subset.

## Metadata proof observer

The aggregate's original read-only authoritative metadata verifier is wrapped by
`metadata_wait.py`. Feature-off calls it exactly once with the original arguments.
Feature-on retries the unchanged fail-closed verifier for at most 21,000 seconds;
only a genuine successful proof returns success. Failure/timeout/cancellation is
never translated into a green result. Metadata cannot share an active cancellation
key with validation.

Only enabled metadata aggregate jobs receive a 360-minute budget. This can occupy
an Ubuntu runner while macOS jobs wait in queues; the cost is explicit. Exact
head/base/attempt/current-main checks remain in the verifier. If the candidate
changes, an older metadata observer cannot bless the new candidate.

## Reviewed wiring

- .github/workflows/ci.yml: 15 cancellable validation jobs; exclusions: ci-plan, upload-core-coverage, consumer-smoke, upload-macro-coverage, codeql, release-candidate, ci-required

## Observer accumulation is an explicit fallback

Repeated metadata events currently create independent bounded observers. They can
occupy more than one Ubuntu runner while the same source validation is pending.
Observer-only cancellation is deliberately not enabled: the existing DI/Flow/Router
provenance readers reject cancelled metadata runs, so adding cancellation alone
could leave a later valid candidate blocked. Coalescing requires a separate proof
that a cancelled observer was superseded by a newer exact successful observer.
Do not claim this preparation coalesces metadata or has measured queue savings.
The rollout remains off by default, with the 360-minute per-observer limit above.

## Validation and remaining limits

Local tests verify default preservation, keys/collisions, product-key uncertainty,
metadata outcome handling, source mode checks and exact workflow headers. Pinned
actionlint validates the emitted YAML. No live run was cancelled as a test.

GitHub ordering is based on when jobs start waiting, not commit dispatch order;
an older run with delayed prerequisites can enter a group after a newer one.
The exact-candidate gates prevent accepting stale evidence, but this design does
not claim atomic newest-commit scheduling. See the official [concurrency rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

Before activation, separately approve a hosted overlap test covering same-product,
different-product, matrix/lane, metadata, cancelled-source and excluded stateful
paths. GitHub native scheduling and Apple compiler/runtime behavior remain
unverified in this cloud VM.
