# Current documentation review — 2026-10-10

## Baseline and scope

- Working-tree baseline: main `d5213fb` (post-release tooling fixes)
- Current stable [6.1.1](https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.1.1):
  tag object `07c576536201dddc833708780749893c1eba0afe`, commit
  `44e4ca28c50c03f817231a077c0f3bdfdbc859c8`, published 2026-10-07T21:55:40Z
- Root guides: English, Korean, Spanish, German, Simplified Chinese, Japanese,
  Russian. The English README also retains the longer reference. The six
  translations share nine sections and four identical Swift snippets each.
- Current guides, DocC entry points, developer guidance, release/security
  summaries, migration destinations and the static documentation landing page
  were reviewed against source and manifests. Dated release-preparation and
  validation documents are evidence, not fresh acceptance claims.
- Historical [Korean README](ko/README.md) is preserved with an explicit pointer
  to the current translation. Existing release snapshots remain distinguishable
  from publication; no historical run has been relabeled as a current test.

## Important corrections

- 6.1.1 publication replaces stale 5.x/6.0/6.1 candidate adoption guidance.
- HLS belongs to InnoNetwork-Stream; Protobuf to InnoNetwork-Protobuf. Their
  6.1.1 releases pin Core 6.1.1. Product identity is distinct from module names.
- Removed the root's long duplicate HLS feature catalogue in favor of the
  sibling's own current documentation and feature limits.
- Default streaming is lossless and backpressured, at most one decoded output
  ahead of the consumer, not unbounded output buffering.
- `NetworkError` and value-only `NetworkFailure` are separate error boundaries.
  Cancellation, terminal `shutdown()`, caller-owned injected sessions, explicit
  WebSocket retry and per-operation replay safety are documented.
- Macro opt-out does not imply zero package-resolution dependencies.
- The 6.0 release validator checks the current companion destination when 6.1.1
  publication is recorded, while preserving old-tag migration expectations.

## Checks performed

These are offline/source checks, not Apple-platform execution:

- `git diff --check`
- `bash Scripts/check_docs_contract_sync.sh --static-only`: passed, including
  current README checks, publication consistency, release-state contracts and
  API budgets (1,764 total; 367 Stable, 1,364 provisional, 33 SPI)
- `python3 Scripts/tests/test_current_readmes.py`: 6 regression tests passed
- `python3 -m unittest discover -s Scripts/automation-tests -p test_static_docs_contract.py`:
  4 tests passed, including proof static mode avoids compiler invocation
- `bash Scripts/tests/test_validate_6_release_state.sh`: passed, including
  committed historical fixtures and the 28-test 6.1 lifecycle suite
- `ruby Scripts/tests/test_check_post_release_docs.rb`: 16 fixtures passed
- `bash Scripts/tests/test_validate_docs_release_state.sh`: 11 cases passed
- `bash Scripts/tests/test_docs_contract_helpers.sh`: 16 helper cases passed
- Relative Markdown file targets in changed documentation and all new README
  guides checked. Release and companion identities were checked independently
  against published release metadata and local tagged manifests.

The README parity check verifies structure, required contract terms, language
navigation, matching translated Swift snippets and local link targets. It does
not prove semantic translation equivalence or that all code compiles.

## Not performed

Swift is unavailable in this Linux workspace. No Swift tests, compiler-backed
contract checks, consumer smoke builds, symbol graphs, rendered DocC, browser
rendering, device/background-transfer acceptance or native-speaker review were
performed. Static-site generated DocC destinations and arbitrary external links
were not exhaustively fetched. Run the full contributor checks on a supported
Apple toolchain and review translations before publication.

No runtime source, package manifest or lockfile changes are included. This
review does not publish a release or certify downstream applications.
