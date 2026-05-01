# Release Policy

## Versioning

- Public releases follow semantic versioning since `3.0.0`.
- Stable API must not break in patch or minor releases.
- Breaking changes require a major version bump and migration guidance.

## Release Process

1. Update `CHANGELOG.md`
2. Confirm `docs/releases/<version>.md`
3. Push an annotated tag such as `4.0.0`
4. Let the `Release` workflow run:
   - `swift test --no-parallel --enable-code-coverage`
   - docs contract sync
   - doc smoke build/run
   - consumer smoke build
   - benchmark quick run with the guarded request pipeline, event hub,
     response cache, download restore, and WebSocket lifecycle/send set
   - DocC build smoke
   - GitHub Release creation with benchmark artifact upload
5. Re-check `API_STABILITY.md` and `Scripts/api_public_symbols.allowlist`
   together whenever a release branch changes public or SPI declarations.
6. Re-run DocC/sample smoke after documentation-only release edits so
   examples, symbol links, and docs-contract wording stay in sync.

## Benchmarks

- PR CI blocks guarded benchmark regressions over 20%.
- Scheduled/manual benchmark runs use the same guard list with a 10%
  threshold. Use that stricter signal for release readiness and investigate
  before tagging if it fails.
- Baseline diffs outside the guard list are recorded for trend review and are
  not release blockers by themselves.

## Support Posture

- Release quality is expected for Stable API.
- Response time remains best-effort under the lightweight maintainer model.
