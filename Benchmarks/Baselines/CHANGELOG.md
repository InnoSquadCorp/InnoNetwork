# Benchmark Baseline Rationale

Record the reason every time `default.json` changes.

## Template

- Date:
- PR:
- Runner:
- Benchmarks changed:
- Reason:
- Validation:

## 5.0.0

- Date: 2026-07-14
- PR: N/A (5.0 direct-main preparation)
- Runner: `macos-15`, Xcode 26.0.1, GitHub Actions runs
  [29353749598](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/29353749598),
  [29354354216](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/29354354216),
  and
  [29355256676](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/29355256676)
- Benchmarks changed: all 22 rows were recalibrated to the slowest successful
  artifact sample across the three sequential runs:
  - `encoding/query-encoder-small`: 38,180.75 -> 143,301.97 ops/s
  - `encoding/query-encoder-large`: 3,988.43 -> 14,942.53 ops/s
  - `events/task-event-fanout-single`: 18,124.23 -> 33,987.64 ops/s
  - `events/task-event-fanout-many`: 4,629.21 -> 6,153.46 ops/s
  - `events/task-event-slow-isolation`: 17,344.77 -> 31,163.55 ops/s
  - `persistence/append-log-write`: 64.39 -> 353.30 ops/s
  - `persistence/append-log-replay`: 7,318.21 -> 14,892.56 ops/s
  - `persistence/append-log-compaction`: 22.96 -> 126.32 ops/s
  - `persistence/download-persistence-restore`: 46.72 -> 375.38 ops/s
  - `websocket/websocket-reconnect-decision`: 331,238.03 -> 495,882.62 ops/s
  - `websocket/websocket-close-disposition-classify`: 3,980,702.89 ->
    75,500,667.58 ops/s
  - `websocket/websocket-ping-context-create`: 2,727,916.90 -> 16,080,057.59 ops/s
  - `websocket/websocket-send-queue-reserve`: 1,293,280.79 -> 2,885,940.42 ops/s
  - `websocket/websocket-lifecycle-transition-table`: 881,628.35 ->
    5,780,562.67 ops/s
  - `client/request-pipeline`: 5,225.05 -> 8,057.98 ops/s
  - `client/request-coalescing-shared-get`: 3,891.68 -> 6,939.63 ops/s
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
- Validation: all three hosted runs completed with zero final guard failures;
  the schema-v2 baseline stores each per-row minimum successful sample as one
  whole result, including its matching elapsed and resident-memory fields,
  rather than combining throughput with metadata from another run.

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
