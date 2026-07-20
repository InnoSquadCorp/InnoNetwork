# Benchmark Baseline Rationale

Record the reason every time `default.json` changes.

## Template

- Date:
- PR:
- Runner:
- Benchmarks changed:
- Reason:
- Validation:

## 5.0.0 (warmup methodology refresh)

- Date: 2026-07-19
- PR: N/A (5.0 direct-main preparation)
- Runner: `macos-15`, Xcode 26.0.1. The baseline source is GitHub Actions run
  [29670600110](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/29670600110)
  (workflow_dispatch on `main`).
- Benchmarks changed: all 23 (regenerated), including the first entry for
  `client/streaming-collect-1mib`, which previously reported "no baseline
  entry".
- Reason: the harness gained an untimed 5% warmup pass
  (`build: warm up benchmarks and report sample spread`), which removes the
  cold-start bias from every sample and shifts most medians upward; the old
  single-cold-run numbers are no longer comparable. The chunked transport
  bridge also made `streaming-collect-1mib` a meaningful guard candidate.
- Validation: the source run's guarded static-baseline step passed against
  the previous baseline (only regressions fail; warmup shifts are positive),
  and `Scripts/check_guarded_benchmark_contract.sh` passes against the
  regenerated file.

### Same-runner enforcement

- Date: 2026-07-20
- Source revision: `a4aaaba8b41553033f5d1f23fa94af85b52b4c3a`
- Reason: absolute operations-per-second values from the source run varied by
  more than 10% across otherwise equivalent `macos-15` hosted runners. The
  scheduled gate now builds this reviewed source revision and the candidate on
  the same machine, interleaves three samples per revision, and compares their
  medians at a 20% threshold. Both implementations use the candidate's
  benchmark harness so methodology-only changes cannot appear as runtime
  changes. Short guarded async paths also use longer quick-mode observations.
  The JSON baseline remains the declaration/provenance reference; it is no
  longer used as a cross-machine pass/fail threshold.
- Validation: `run_same_runner_benchmarks.sh` is the local and hosted proof;
  its three-by-three comparison must complete with zero guard failures.

## 5.0.0

- Date: 2026-07-14
- PR: N/A (5.0 direct-main preparation)
- Runner: `macos-15`, Xcode 26.0.1. The baseline source is GitHub Actions run
  [29355256676](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/29355256676),
  with the same systematic release-mode shift confirmed by preceding runs
  [29353749598](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/29353749598),
  and [29354354216](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/29354354216).
- Benchmarks changed: all 22 rows were recalibrated from the final complete
  artifact in the three-run sequence:
  - `encoding/query-encoder-small`: 38,180.75 -> 176,631.63 ops/s
  - `encoding/query-encoder-large`: 3,988.43 -> 15,162.68 ops/s
  - `events/task-event-fanout-single`: 18,124.23 -> 48,156.99 ops/s
  - `events/task-event-fanout-many`: 4,629.21 -> 6,650.18 ops/s
  - `events/task-event-slow-isolation`: 17,344.77 -> 31,163.55 ops/s
  - `persistence/append-log-write`: 64.39 -> 384.75 ops/s
  - `persistence/append-log-replay`: 7,318.21 -> 15,494.20 ops/s
  - `persistence/append-log-compaction`: 22.96 -> 127.96 ops/s
  - `persistence/download-persistence-restore`: 46.72 -> 379.63 ops/s
  - `websocket/websocket-reconnect-decision`: 331,238.03 -> 495,882.62 ops/s
  - `websocket/websocket-close-disposition-classify`: 3,980,702.89 ->
    75,500,667.58 ops/s
  - `websocket/websocket-ping-context-create`: 2,727,916.90 -> 16,080,057.59 ops/s
  - `websocket/websocket-send-queue-reserve`: 1,293,280.79 -> 2,885,940.42 ops/s
  - `websocket/websocket-lifecycle-transition-table`: 881,628.35 ->
    5,780,562.67 ops/s
  - `client/request-pipeline`: 5,225.05 -> 8,057.98 ops/s
  - `client/request-coalescing-shared-get`: 3,891.68 -> 8,843.66 ops/s
  - `client/concurrent-50-requests`: 12,668.39 -> 22,344.43 ops/s
  - `client/decoding-interceptor-chain-1`: 5,796.92 -> 9,211.92 ops/s
  - `client/decoding-interceptor-chain-3`: 5,800.00 -> 9,323.36 ops/s
  - `client/decoding-interceptor-chain-8`: 5,800.00 -> 8,929.95 ops/s
  - `cache/response-cache-lookup`: 466,773.14 -> 3,051,670.50 ops/s
  - `cache/response-cache-revalidation`: 1,285,328.11 -> 4,559,491.35 ops/s
- Reason: the May baseline was captured with a debug `swift run`, while CI and
  release validation now use `swift run -c release`. Every row moved upward by
  more than 10% in all three successful hosted artifacts, so this is a
  systematic measurement-mode recalibration rather than a claimed runtime
  optimization. Failed attempts remain retry noise and are not calibration
  inputs.
- Validation: all three hosted runs completed with zero final guard failures.
  The schema-v2 baseline is the exact normalized `version`, `generatedAt`, and
  `results` projection of run 29355256676, preserving its result order,
  run-wide provenance, and monotonically nondecreasing high-water memory data.

- Date: 2026-07-14
- PR: N/A (5.0 direct-main preparation)
- Runner: identifier-only baseline migration; measurements unchanged
- Benchmarks changed: renamed `websocket/websocket-ping-context-alloc` to
  `websocket/websocket-ping-context-create`.
- Reason: the benchmark measures construction throughput plus a clock read; it
  does not count heap allocations. The new identifier makes the measured
  contract explicit without changing the captured baseline value.
- Validation: `swift run -c release InnoNetworkBenchmarks --quick
  --enforce-baseline` with the guarded identifier set.

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
