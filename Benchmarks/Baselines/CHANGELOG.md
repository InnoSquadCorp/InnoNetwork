# Benchmark Baseline Rationale

Record the reason every time `default.json` changes.

## Template

- Date:
- PR:
- Runner:
- Benchmarks changed:
- Reason:
- Validation:

## 4.0.0

- Date: 2026-05-02
- PR: #42
- Runner: local `--quick` companion numbers documented in `Benchmarks/README.md`
- Benchmarks changed: added `client/decoding-interceptor-chain-{1,3,8}`;
  promoted `persistence/append-log-compaction` to the guarded benchmark set
- Reason: the decoding-interceptor-chain hot path is documented and guarded, so
  the baseline file must carry matching rows instead of reporting missing
  baseline entries. Download persistence compaction already has a baseline row;
  guarding it keeps the snapshot/truncation path covered alongside restore.
- Validation: `swift run InnoNetworkBenchmarks --quick --enforce-baseline`
  should include the new rows without missing-baseline diagnostics.

- Date: 2026-05-02
- PR: #42
- Runner: `macos-15` GitHub-hosted runner
- Benchmarks changed: recalibrated guarded floors for
  `events/task-event-fanout-single`, `client/request-pipeline`,
  `client/request-coalescing-shared-get`,
  `client/decoding-interceptor-chain-{1,3,8}`, and
  `cache/response-cache-revalidation`.
- Reason: PR #42 GitHub-hosted artifacts showed these short async
  microbenchmarks varying past the 20% guard while the longer local/full
  samples and unrelated functional tests stayed stable. The baseline now uses
  conservative macOS 15 hosted-runner floor values instead of the fastest local
  sample so the guard continues to catch real regressions without failing on
  runner scheduling noise.
- Validation: `swift run InnoNetworkBenchmarks --quick --enforce-baseline`
  passes locally; PR #42 CI/Benchmarks reruns validate the hosted-runner gate.
