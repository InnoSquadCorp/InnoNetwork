# Release Policy

## Versioning

- Public releases follow semantic versioning since `3.0.0`.
- Stable API source-breaking or documented behavior-breaking changes require a
  major version bump and migration guidance.
- Provisionally Stable API shape or behavior changes may ship in a minor
  release only when the release notes include an explicit migration note.
- Patch releases must stay source-compatible for Stable and Provisionally
  Stable API and are limited to bug fixes, documentation, and additive
  non-breaking clarifications.

## Release Process

1. Update `CHANGELOG.md`
2. Confirm `docs/releases/<version>.md`. While the release is being prepared,
   its first byte must begin the exact marker
   `<!-- release-status: draft -->`; leading blank lines are not allowed.
   Change it to the exact top-of-file
   `<!-- release-status: ready -->` marker only after the release contents and
   required validation are deliberately approved. Unknown, missing, misplaced,
   or draft markers block release publication. For the `5.0.0` compatibility
   reset, the marker must change in the same commit as README, API stability,
   CHANGELOG, security-support, symbol-baseline, migration-guide, status-line,
   and release-date claims. `Scripts/validate_docs_release_state.sh` rejects a
   marker-only transition or a mixed draft/ready Git tree.
3. Before tagging, run the `Release` workflow manually from `main`. A manual
   dispatch executes the full validation and five-platform matrix, produces
   candidate artifacts, and structurally skips the signing/publication job.
   `Scripts/validate_release_candidate.sh` fetches canonical `origin/main` and
   rejects a stale, detached, or side-branch candidate.
4. Push an unprefixed annotated SemVer tag such as `5.0.0` only from a commit
   whose matching release notes are marked `ready`. The tagged commit
   must exactly match the freshly fetched `origin/main` HEAD and already
   contain `docs/releases/<version>.md`; the workflow rejects lightweight
   tags, older or off-main commits, stale main refs, missing release notes,
   and non-ready release notes before build.
5. Let the tag-triggered `Release` workflow run:
   - root tests in serial coverage mode and bounded target-sharded mode
   - root macro tests, negative compile fixtures, and fail-closed runtime/macro
     LCOV generation
   - default trait graph and clean core-only build checks
   - docs contract sync
   - doc smoke build/run
   - every independently discovered consumer example build
   - release-mode benchmark quick run with enforced baselines for the guarded
     request pipeline, event hub, response cache, download restore, and
     WebSocket lifecycle/send set
   - DocC build smoke
   - resolved CycloneDX SBOM generation for the default-trait root graph and
     the core-only (`traits: []`) profile
   - Package.swift-aligned macOS, iOS, tvOS, watchOS, and visionOS build tuples
   - sigstore signing and GitHub Release creation with the benchmark,
     `sbom.cdx.json`, and `sbom-core-only.cdx.json` artifact sets
6. Re-check `API_STABILITY.md` and `Scripts/symbols/*.allowlist`
   together whenever a release branch changes public or SPI declarations.
7. Re-run DocC/sample smoke after documentation-only release edits so
   examples, symbol links, and docs-contract wording stay in sync.
8. Run `bash Scripts/run_local_release_preflight.sh --full` before changing the
   release status to ready. It reproduces the pre-tag validation, coverage,
   benchmark, SBOM, DocC, and five-platform build gates locally; tag identity,
   signing, and publication remain GitHub-only responsibilities.
9. Before tagging, export the active repository ruleset and run
   `python3 Scripts/check_required_status_checks.py --ruleset-json <path>`.
   It must match `.github/required-status-checks.json`. Narrow or remove the
   temporary organization-administrator direct-push bypass used during the
   unreleased 5.0 staging cycle; the tag must not be the first point at which
   merge protection drift is discovered.

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
