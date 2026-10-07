# Core 6.1.0 release preparation — 2026-10-06

Status: Core 6.1.0 published on 2026-10-07 UTC.
The earlier sections below preserve their original preparation and Ready
snapshots, including failed runs. The publication section records later evidence
without treating it as validation of future commits. Release assets have been
downloaded and checked as detailed below. At the time this publication record
was prepared, before the DocC correction was integrated, its actual Pages
deployment was still outstanding. This is a historical snapshot; see the
[publisher workflow](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/docs-publish.yml)
for subsequent results. Companion releases retain separate checks; no repository
setting is changed here.

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

These are test additions, not new runtime/public-API behavior. They cannot be
compiled or executed in this Linux VM. The first hosted execution and its
test-expectation correction are recorded below; the corrected head needs fresh CI.

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

### First hosted candidate and error-redaction correction

Head `00eb4cc2967eee3cc29cdcb4c1b4af9946bdfaef` was published in Draft PR #144.
Its [first CI run](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37423157260)
passed policy/dependency checks, swift-format, macro/example consumers, DocC,
docs contracts, CodeQL and guarded benchmarks before the release-candidate
serial test lane reported three new assertion failures.

The no-content decoder correctly rejected unexpected bytes. The new test had
incorrectly expected those bytes to remain on the surfaced error response,
despite `safeDefaults` redacting failure payloads. The first correction at
`fac102cc252f9547da56ff400a28e1414bd6b4f5` correctly required empty data but
incorrectly added a `.headersOnly` expectation. Its
[Xcode 26 shard run](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37435082739/job/112174987993)
passed byte-redaction assertions and failed that new kind assertion in nine
cases. `Response.redactingData()` preserves its input kind: buffered responses
remain `.body`. The test now explicitly requires empty data and `.body`.

Runtime and security policy are unchanged. The first execution passed the new
encoded 401-refresh replay test. Preserve both failed runs as diagnostic evidence
and validate the corrected head independently; neither is a passing full candidate.

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

## 4. Successful preparation and Ready decision — 2026-10-06

- PR #144's final head `c02d0a7334cba2881e87b5c7e63374af9495a470`
  passed [32 CI jobs](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37437641109),
  including all fifteen new encoded regression cases on Xcode 27. It was normally
  squashed to `5a73a9a90436b31dfd2cb5a95909fcb613c66478`; its
  [main CI](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37456694023)
  succeeded with 22 successful jobs and six policy-selected skips.
- PR #145 added the official remote execution of the unchanged fifteen-gate
  full preflight, candidate/public-tag consumer verification, and coherent 6.1
  Draft/Ready/published documentation checks. It changed no runtime source,
  dependency manifest/lockfile, public symbol inventory or repository protection.
- The first #145 head `8297c35d20ed635c9b87e9b95f469424fb5d2c9f`
  exposed a Python-version-specific error-message assertion in an invalid-date
  fixture. Invalid dates were correctly rejected. The final head
  `628e4a956db70da4ec1c3a2e34e0bedcb2494083` normalizes the diagnostic while
  preserving strict calendar validation and the original exception; its local
  Python fixtures passed 133 tests, including 28 lifecycle cases.
- Its [exact-head CI](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37465674436)
  passed all 32 jobs on attempt 2. Attempt 1's append-log-compaction paired median
  exceeded the unchanged 20% guard at 21.06%, with 36.0% pair spread. Runtime,
  benchmark and dependency trees were identical to the PR base. A single same-SHA,
  same-threshold remeasurement passed at -1.38% (head relative to base); the
  original logs remain diagnostic evidence, not a passing result. All other
  thirty jobs passed on the original attempt. The
  [metadata check](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37466003839)
  subsequently verified the successful current head/base evidence.
- Normal PR #145 integration produced main
  `9e0a722a57ce3e74c623b8a6923869fb72a0d98c`, whose tree
  `e2d96b036f656b0dea9db7a9ded9aa068f5c992e` equals the tested PR head.
- The [official non-publishing Release run](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37493194400)
  succeeded on that main revision: seven validation jobs succeeded; public-tag
  verification and publication were structurally skipped. The full-preflight
  receipt records all fifteen gates, strict Periphery 3.8.0, coverage, guarded
  benchmarks, SBOMs, DocC and five-platform builds. The explicit streaming soak
  ran for 30 seconds, separately from shorter ordinary test cases.
- The [retained full-preflight artifact](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37493194400/artifacts/11432405476)
  records the exact commit/tree and successful post-execution main check. Its
  consumer receipt resolves the canonical GitHub repository to the same revision
  with default and core-only traits and runs both in release mode. It explicitly
  records `mode: candidate-revision`, `version: null` and
  `public_tag_verified: false`; it does not claim a resolvable 6.1.0 tag.
- With the authorized release contents and actual full-preflight evidence, the
  five coordinated lifecycle documents now mark 6.1.0 Ready. README installation
  and the publication ledger still describe the publicly released 6.0.0.

The new Ready documentation commit still needs exact-head CI, review and normal
integration. The final Ready main must pass its own CI and official non-publishing
Release validation, and the intended date and current protection must be audited
again before creating the annotated tag. Tag identity, public-tag consumer
resolution, signatures, release assets and publication are separate evidence;
none is supplied by this Ready marker or by the earlier Draft-main run.

## 5. Final-main validation and publication — 2026-10-07

- The final Ready main was `79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16`.
  Its [CI run](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37520827852)
  succeeded with 22 successful jobs and six policy-selected skips.
- The final [non-publishing Release run](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37520863017)
  initially failed the full-preflight restore benchmark. The reported performance
  delta was -21.1758% against the unchanged 20% guard, with 25.24% pair spread.
  The [failed attempt artifact](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37520863017/artifacts/11445216308)
  remains diagnostic evidence, not a passing result.
- One complete-job retry used the same configured `xcode-27` runner profile,
  revision `79ff9f53`, code and threshold in the same workflow. Runner ID changed
  from `1000029002` to `1000029021`; this does not assert an identical machine
  or execution environment. Attempt 2 passed with a restore delta of -6.5376%. The
  [successful full-preflight artifact](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37520863017/artifacts/11449172229)
  is retained alongside the failed attempt. No threshold or benchmark change
  was used to turn the failure into a pass.
- Annotated tag `6.1.0`, object
  `b4589582d5e9e2de30ad07357b32e30834b13f93`, points to that final main commit.
  It was created on 2026-10-06 UTC and is not moved by this documentation update.
  The tagged release notes retain their original Ready status and intended date.
  The tag has no GPG signature; the existing policy requires an annotated tag
  at current main. The separate Sigstore signature/certificate assets cover
  the four JSON release artifacts, not the Git tag.
- [Release run 37543447300](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37543447300)
  succeeded with seven validation jobs and one publication job. Only the
  previously completed manual full-preflight job was skipped for the tag event.
- The [public-tag consumer artifact](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37543447300/artifacts/11451431444)
  was inspected directly: `mode: published-tag`, `version: 6.1.0`, revision
  `79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16`, default and core-only traits,
  release-mode execution, and `public_tag_verified: true`. This is actual tagged
  resolution evidence, distinct from the earlier candidate-revision receipt.
- [GitHub Release 6.1.0](https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.1.0),
  release ID `405238737`, has `published_at: 2026-10-07T00:15:19Z`,
  `draft: false` and `prerelease: false`. All twelve release assets were downloaded;
  each byte length and SHA-256 matches its GitHub Release API size/digest record.
- Both SBOMs use CycloneDX 1.5 and identify root version `6.1.0`, revision
  `79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16`, and their respective default and
  core-only profiles. The four primary JSON digests are:
  - `benchmarks.json`: `d02e265532a673baecde5561e3e35ef639bfbed458c5aad12a212df914e38ac1`
  - `benchmarks-json-codec.json`: `d7991fdbdbaab05555c1f18cc51683abbd3303704490fd9a26ef29fddc5bcb7d`
  - `sbom.cdx.json`: `0b3796f9f6328fff3c2aba76d039902d0f7ddf67520bc1c506f3688db619ee8d`
  - `sbom-core-only.cdx.json`: `ed2f89c0a0b7f636a7d97f0ec3c81a57cf71f684e9532d4ea7d08e2dd212c676`
- After decoding the base64-PEM certificates, OpenSSL verified all four detached
  signatures using the included public keys. The certificate SAN is
  `https://github.com/InnoSquadCorp/InnoNetwork/.github/workflows/release.yml@refs/tags/6.1.0`.
  This verifies the signature bytes against those certificates; full Sigstore
  trust-chain and Rekor verification was not performed and is not claimed.

Outstanding when this publication record was prepared, before DocC correction
integration (historical snapshot):

- [ ] Validate and normally integrate the publication-documentation and DocC
  publisher corrections, then confirm the actual Pages deployment and all ten
  product routes. The publisher must recognize the canonical CI workflow even
  with its dynamic run title, and permit only the authenticated main aggregate's
  exact PR-metadata step to skip. A local fixture pass is not a live deployment.
  See the [publisher workflow](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/docs-publish.yml)
  for later deployment and route-smoke results.
- [ ] Reconcile the GitHub Release body with actual publication metadata. The
  publication workflow copied the original tagged Ready notes; changing current
  repository documentation alone does not update that external Release body.
- [ ] For optional Protobuf/Stream adoption, align their manifests and complete
  their own published-tag and exact-pair checks. Core publication does not publish
  or certify those companion releases.
