# Release Policy

## Versioning

- Public releases follow semantic versioning from `3.0.0`.
- Stable API must not break in patch or minor releases.
- Breaking changes require a major version bump and migration guidance.

## Release Process

1. Update `CHANGELOG.md`
2. Confirm `swift test`
3. Confirm docs contract sync
4. Confirm doc smoke build/run
5. Confirm benchmark quick run
6. Confirm DocC build
7. Create annotated git tag
8. Publish GitHub Release notes

## Benchmarks

- Benchmark results are informational by default.
- Baseline diffs are recorded, not used as release blockers yet.

## Support Posture

- Release quality is expected for Stable API.
- Response time remains best-effort under the lightweight maintainer model.
