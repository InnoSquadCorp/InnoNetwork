# Event delivery performance follow-up — 2026-09-28

Status: Local candidate; remote validation and protected merge pending.

## Scope and decision

- Problem: PR #125 head `1faa2985ca47f7aec828c3cdbfb5caad747fa47b`
  failed the 20% single-listener guard by measuring -20.97%. Preserve the
  failing artifact rather than treating another passing attempt as a fix.
- Constraints: preserve public API, event ordering, completion waits,
  independent listener queues, cancellation, and the existing 20% guard.
- Alternatives: raise the threshold/reset the baseline; change runtime
  dispatch without measuring; or profile, reduce demonstrated unnecessary
  scheduling, and use longer matched observations. Only the last is selected.
- Failure behavior: a failed guard, unresolved sanitizer warning, or pending
  required check continues to block the release decision. No suppression,
  bypass, threshold exemption, tag, or publication is part of this change.
- Validation: same-binary controls, before/after paired release measurements,
  listener-count/order/cancellation/retirement tests, full regression tests,
  unchanged benchmark guards, then final-SHA remote checks.

## Evidence and limits

Artifacts are retained at `/tmp/innonetwork-event-regression.rcIvCK` for this
session. Earlier hosted raw samples remain at
`/tmp/innonetwork-b1dc8d1-readiness.fSbEFt/remote-final-benchmark`.

The hosted failing pairs were -20.97%, -36.21%, and +3.60% (39.80 percentage
points of spread). TaskEventHub, EventDeliveryChain, their state helpers and
policy were identical to PR base `7b52580430881e7b222f589aee7a30e409ed17da`.
The earlier head's -7.16% passing guard is historical evidence, not a pass for
the final candidate. The hosted scheduler/thermal state was not captured, so
its exact contribution is unresolved.

On Xcode 27.0 (27A266a), Swift 6.4, six unmodified-binary local observations
had about 10.4% spread at 50,000 events and 1.8% at 300,000. A 15-second
Time Profiler capture of the actual complete-delivery path showed task
creation and executor enqueue costs. It motivated a one-listener fast path:
await the existing delivery chain directly instead of making a task group
with exactly one child. Zero listeners return immediately; two or more retain
the existing parallel group. The public contract and per-listener queue do
not change.

Three interleaved before/after pairs measured +18.78% at the original 50,000
events and +18.16% at 300,000 events. The latter paired spread was 11.97
percentage points. These are local measurements, not guaranteed hosted gains.
Increasing the guard's sample duration is separate from the runtime gain:
both baseline and candidate receive the exact same harness.

## Sanitizer boundary

The final-head remote TSAN run `36379606544` reported an initialization/read
race on the immutable lock reference in `StreamingOutputAcknowledgement`.
Its implementation also predates the PR. The original production soak failed
locally at the same init/read pair. A minimal 100,000-value control initially
passed with a main-actor consumer, but moving that consumer to the concurrent
executor reproduced the same warning. This demonstrates why the first control
did not cover the failing topology.

Changing the acknowledgement to a value containing `OSAllocatedUnfairLock`
removes the redundant per-output heap wrapper and its separately published
reference field. Lock copies share their allocated state, so cancellation and
consumption retain the single-lock, exactly-once resume protocol. The identical
concurrent-executor control then passed 100,000 handoffs under TSAN. There is
no sanitizer suppression or unsafe concurrency annotation. The finding is an
init/read publication warning, not evidence of unguarded mutation of the
acknowledgement state. Whether the original report reflects missing runtime
instrumentation is not established and is not needed to justify eliminating
the redundant allocation.

The changed production path passed 51 focused tests across event hubs,
streaming output and resource soak suites under TSAN. The 30-second streaming
soak delivered 1,165,879 ordered values and completed cancellation; the
30-second span control exactly accounted for 1,242,652 attempts. The original
production-path init/read warning did not recur in that run. The subsequent
full serial TSAN command passed all eight test-product summaries: 1,921
registered tests, 1,917 ordinary passes and four explicit opt-in live skips.
Final-SHA remote verification remains required before closing the patch.

## Squash-safe benchmark provenance

The repository allows squash merges only. The reviewed JSON baseline is a PR
commit, so requiring it to be an ancestor of main after squash would break
release validation. Its SHA remains unchanged; it is retained on origin at
`refs/heads/benchmark-baselines/json-6.0`. For this explicitly named JSON
archive only, a non-ancestor source must match that remote ref exactly. A
clean main-only clone can fetch the verified ref and must verify it again
after fetch. Missing/moved/invalid refs fail rather than resetting the
baseline. Runtime ancestry checks and explicit PR-base comparisons are
unchanged. Local Git fixtures exercise original, squashed, missing-object,
drifted-ref, missing-ref, and wildcard-ref cases without remote writes.

## Publication sequence

1. Close the performance and sanitizer investigations and validate the patch.
2. Push the candidate and require fresh checks for its exact SHA.
3. Merge PR #125 only through repository protection, without admin bypass.
4. Deliberately approve the atomic Ready transition after release gates close.
5. Validate the exact merged main candidate with the manual Release workflow.
   Its publication job is structurally skipped for manual dispatch.
6. Tag and actual publication require a separate release instruction.
