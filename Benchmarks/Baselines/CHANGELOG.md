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
- PR: pending
- Runner: `macos-15` GitHub-hosted runner
- Benchmarks changed: none yet
- Reason: baseline governance now requires an explicit rationale entry before
  changing guarded baseline numbers.
- Validation: scheduled benchmark workflow writes JSONL trend records to the
  `benchmark-trends` branch and PR runs render a Markdown benchmark summary.
