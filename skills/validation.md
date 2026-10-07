# InnoNetwork skill validation — 2026-10-07

## Baseline and fresh evidence

The public 6.1.0 tag and GitHub Release resolve to
`79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16`. The source skill is an addition
on that baseline, not part of the already-published tag. No runtime source or
library dependency declarations changed.

The declared support range is stable **6.1.x** (`>=6.1.0, <6.2.0`); this evidence
validates **6.1.0** only. The range update preserves the exact fixture, lock and
validation helper. Other patches such as 6.1.1 require their own consumer checks;
the planned release is not recorded as published or tested here.

| Check | Result |
| --- | --- |
| Independent exact-release consumer | 13 Swift Testing tests, 1 suite, zero failures; strict concurrency complete and warnings as errors |
| Dependency provenance | All six remote lock entries, active graph/workspace state, actual checkout SHAs and clean worktrees verified; no local overrides |
| Pin-drift negative control | Disposable support record with a corrupted Crypto revision was rejected before any build command |
| Library regression | `swift test --parallel --scratch-path <external>` exited 0; eight runner summaries report 2,050 tests / 229 suites; four live smoke tests skipped with `INNO_LIVE` unset |
| Docs/API contract | `bash Scripts/check_docs_contract_sync.sh` passed; runtime API budget 1,764 / 1,764 |
| Skill structure | skill-creator `quick_validate.py` passed |

Toolchain and fixture SHA-256 values are recorded in
[consumer-evidence.json](validation/consumer-evidence.json). The root suite and
docs checker were run on the unchanged runtime source at the release baseline.
The consumer helper was rerun after its final implementation and JSON-header
assertion changes. An initial AI-generated test incorrectly expected bare
`application/json`; the released encoder emits `application/json; charset=UTF-8`.
That exact contract is now explicit in the reference and fixture. The first AI
failure and the fresh reevaluation are recorded by the central plugin repository.

The 13 consumer tests cover macro JSON GET/POST, non-Codable encoded output,
per-invocation encoding and retry byte reuse, auth before encoding, sanitized
encoder failure, nil versus zero-length body, request budgets, response cap
intersection, no-content status/body checks, JSON and encoded operation handles,
immediate deadline, codec cancellation and shutdown. Parameterized cases include
passing controls; no InnoNetwork `@testable` or SPI access is used.

## Harness correction and limits

The first helper attempt rejected a valid graph because SwiftPM omits
SwiftSyntax from `show-dependencies` when a compiler prebuilt is selected.
The corrected helper requires a matching workspace prebuilt record and verifies
all six underlying source checkouts. This was a harness defect, not a library
regression. SwiftPM owns prebuilt acquisition; the helper does not independently
attest the compiler binary's contents.

These are macOS mock-transport tests with default traits on Xcode 27 / Swift 6.4.
They do not qualify real network/TLS/auth services, devices, background transfers,
optional product lifecycles, traits disabled, companion releases, or combined
InnoDI/InnoNetwork applications. Minimum supported toolchains/platforms were not
rerun. Library CI on a future PR head remains separate from these local results.

Codex/Claude plugin installation and AI selection/generation results belong to
the central plugin repository. This file makes no host-behavior or public-plugin
release claim. Historical release-readiness wording elsewhere in the tagged
library is not used as publication evidence.
