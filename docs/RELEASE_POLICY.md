# Release Policy

## Versioning

- Public releases follow semantic versioning from `3.1.0`.
- Stable API must not break in patch or minor releases.
- Breaking changes require a major version bump and migration guidance.

## Release Process

1. Update `CHANGELOG.md`
2. Confirm `docs/releases/<version>.md`
3. Push an annotated tag such as `3.1.0`
4. Let the `Release` workflow run:
   - `swift test`
   - docs contract sync
   - doc smoke build/run
   - consumer smoke build
   - benchmark quick run
   - DocC build smoke
   - GitHub Release creation with benchmark artifact upload

## Benchmarks

- Benchmark results are informational by default.
- Baseline diffs are recorded, not used as release blockers yet.

## Support Posture

- Release quality is expected for Stable API.
- Response time remains best-effort under the lightweight maintainer model.
