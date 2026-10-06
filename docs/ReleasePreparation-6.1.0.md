# Core 6.1.0 release preparation — 2026-10-06

Status: Draft preparation, not Ready approval or publication evidence.
The selected next version is 6.1.0. Only the Core repository is changed; companion
packages, live repository settings and deployment remain outside this change.

## Starting point and evidence identity

- Main baseline: `d5eb5a46eef6738508516b0d84c7782309f23693`, integrating PR #132
  after #141 and #143. The full tree is
  `6b2cf95a1132c14ad3bc8d242f5dafca68896eac`.
- The final PR head `7b2dba7fc81dc3f27fa5ffdf17f68483d2695ec7` has that same
  tree. Its [32-job CI run](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37398146901)
  succeeded, including both Xcode lanes, TSAN, consumer checks, platforms,
  benchmarks, DocC and read-only release validation.
- At 05:55 UTC, the [baseline main run](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37415710093)
  had not completed. Neither that run nor the preceding PR validates the new
  preparation changes below. Fresh exact-head CI and final-main evidence are
  required after review/integration.
- The latest published Core release remains 6.0.0. The canonical 6.1.0 notes
  remain Draft; no tag, Release, merge, or repository setting was written here.

## 1. Operational contract reconciliation

The current native main ruleset uses `CI Required` and `Dependabot Merge Ready`,
both bound to GitHub Actions app 15368, with `strict=false`, required resolved
review threads and no bypass actors. The earlier release audit incorrectly
expected the legacy fifteen individual check names and strict protection.

The checker now validates both inventories and audits the complete current
manual-integration profile separately. A strict-profile audit is an explicit
additional auto-merge prerequisite, not a setting change or proof of runtime
token authority. Malformed/missing checks, app identity, protection scope,
review barriers and bypass visibility fail closed.

Native autonomous bot merging still requires strict up-to-date base protection.
`expectedHeadOid` cannot pin main after the final read, so repeated observations
must not replace that server-side guard. Current non-strict settings deliberately
leave bot arming in standby and revoke previously armed bot requests; uncertain
cancellation is an error. No enable flag or GitHub ruleset is changed.

Metadata-only CI had compared PR snapshots without reading the authoritative
main ref. A cached PR base could therefore hide main advancement. The proof now
checks main before and after validation, along with the existing exact head,
base, source-tree/ordered-parent, label, run-attempt and native-check evidence.
It also rejects same-SHA retargeting or a foreign base repository. This closes
observable stale-base reuse, not the final-read-to-merge race.

## 2. Encoded regression coverage

Eight new Swift Testing declarations expand to fifteen cases:

- Default no-content 204/205 success with empty data; unexpected data and default
  200 rejection; custom-status success, default replacement and empty-set refusal.
- A real `DefaultNetworkClient` pipeline with scripted 401 then 200 verifies one
  encoding, identical transmitted bodies, old/new bearer headers, one refresh,
  one final decode and one measurement per codec stage.

These are test additions, not new runtime/public-API behavior. They have not yet
been compiled or executed in this Linux VM.

## 3. VM validation and remaining gates

Completed on the preparation tree:

- Python automation and adversarial policy fixtures: 215 tests passed.
- Python script fixtures: 100 tests passed, including six native-ruleset audit
  tests with current/strict profiles and negative controls.
- A fresh read-only export of the live main ruleset passed the current-profile
  audit. This one export does not certify every inherited protection or the
  coordinator's runtime token.
- actionlint 1.7.12: all fifteen workflows passed using the existing archive
  verified against the repository's pinned SHA-256.
- Public operations, three consumer-lane contract, release-workflow contract,
  changelog, and post-publication documentation checks passed.
- Release-ref (22 cases), exact-main candidate (6 cases), historical 5.0/6.0
  state and local-preflight contract fixtures passed. These are offline fixture
  outcomes, not Apple runtime/preflight completion.
- `git diff --check` passed.

Blocked or not performed:

- Swift/Xcode/Apple SDKs and swift-format are absent. The new Swift cases,
  whole-package tests, TSAN, coverage, Apple platform builds, benchmark execution
  and DocC must run on the exact new candidate in the supported Apple lanes.
- The docs aggregate passed publication and historical 6.0 state checks, then
  stopped at `xcrun` while inspecting the package. It is not a full docs pass.
- Ruby consumer-contract fixture execution was blocked by unavailable
  `minitest/autorun`; the production contract checker itself passed.
- Final candidate CI, final-main validation, full release preflight, manual
  non-publishing Release validation, Ready approval and publication approval
  remain separate outstanding gates. No previous success substitutes for them.

## Companion and application boundaries

SwiftSyntax 604.0.x and Crypto 5.x migration is now explicit in the consumer
guide/release notes. Existing Protobuf and Stream macro-first candidate graphs
need their own alignment and exact-pair validation. Stream main's retained
Syntax603 lock is not a direct Syntax603 manifest requirement. These conditional
companion tasks do not establish a Core-only runtime defect or require changing
companion repositories in this preparation.

Device/background/locked-device and dedicated IdP, AWS, exporter or FairPlay
acceptance remains application-specific. Local mocks and green library CI must
not be described as live-service certification.
