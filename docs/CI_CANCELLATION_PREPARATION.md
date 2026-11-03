# Default-on stale validation cancellation

Status: scoped cancellation is enabled for PR validation by default.
Unset/empty `INNO_JOB_CANCELLATION` or `enabled` uses the new behavior;
`disabled` or unknown values restore prior admission. Workflow expressions
normalize the variable; the metadata gate does not read it.

## Admission and immutable workload scopes

- Feature-off retains the exact prior outer workflow group, cancellation and
  metadata queue behavior. Additional job groups are run/attempt-unique, so they
  introduce no cross-run serialization/cancellation when disabled
- Feature-on PRs disable whole-workflow cancellation. Their outer admission group
  is keyed by head, base branch and lane labels, so a metadata run queues behind
  its validation without a runner. Only reviewed validation jobs get a stable
  active job key
- Keys distinguish repository, caller workflow, workflow file, job workload,
  PR/base branch, validation label lane and reviewed matrix cell. Release-validation
  never collides with ordinary validation; concurrency-review is included
  because it affects this repository contract
- Planners, final aggregators, metadata gates, state/history writers and
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

## Metadata gate

The aggregate's read-only authoritative metadata verifier runs exactly once with
its original arguments in both modes, within the original 5-minute job limit.
Feature-off queues a metadata run behind validation in the shared PR group.
Feature-on queues it behind the validation of the same head, base branch and lane
labels. Neither holds a runner while waiting. Only a genuine successful proof
returns success. Failure/timeout/cancellation is never translated into a green
result. Metadata cannot share an active job cancellation key with validation.

The former `metadata_wait.py` wrapper retried for up to 21,000 seconds under a
360-minute job budget. On 2026-10-29 six concurrent Dependabot rebases left 18
such observers holding Ubuntu runners. Twelve watched superseded heads that could
never pass, and an unrelated PR's CI could not start for five hours. Exact
head/base/attempt/current-main checks remain in the verifier. If the candidate
changes, an older gate cannot bless the new candidate; it fails immediately.
How readers treat a failed gate is described in
[CI automation](CIAutomation.md#metadata-only-gate).

## Reviewed wiring

- .github/workflows/ci.yml: 15 cancellable validation jobs; exclusions: ci-plan, upload-core-coverage, consumer-smoke, upload-macro-coverage, codeql, release-candidate, ci-required

## Repeated metadata events

Each metadata event still creates its own gate, but a gate holds an Ubuntu runner
only for one bounded proof after its validation finishes. Gate cancellation is
still not enabled and is no longer needed to free runners. This repository's
readers judge each metadata run by its latest attempt, so a failed earlier
attempt no longer blocks a successful rerun. The sibling DI/Flow/Router readers
are unchanged. Do not claim this coalesces metadata or has measured queue savings.

## Validation and remaining limits

Local tests verify default preservation, keys/collisions, product-key uncertainty,
metadata outcome handling, source mode checks and exact workflow headers. Pinned
actionlint validates the emitted YAML. No live run was cancelled as a test.

GitHub ordering is based on when jobs start waiting, not commit dispatch order;
an older run with delayed prerequisites can enter a group after a newer one.
The exact-candidate gates prevent accepting stale evidence, but this design does
not claim atomic newest-commit scheduling. See the official [concurrency rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

Hosted overlap validation still needs to cover same-product,
different-product, matrix/lane, metadata, cancelled-source and excluded stateful
paths. GitHub native scheduling and Apple compiler/runtime behavior remain
unverified in this cloud VM.
