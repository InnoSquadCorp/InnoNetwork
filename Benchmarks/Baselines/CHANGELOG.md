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
- PR: pending
- Runner: `macos-15` GitHub-hosted runner
- Benchmarks changed: none yet
- Reason: baseline governance now requires an explicit rationale entry before
  changing guarded baseline numbers.
- Validation: scheduled benchmark workflow writes JSONL trend records to the
  `benchmark-trends` branch and PR runs render a Markdown benchmark summary.
