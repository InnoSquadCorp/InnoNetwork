# Encoded-request review remediation — 2026-09-30

Status: all nine original confirmed review findings, plus one DocC integration
omission found during final validation, have scoped local fixes and regression
tests. Final validation is recorded below; this is not a publication approval.

## Scope and immutable inputs

The maintainer authorized fixing the confirmed findings and creating local
commits. No push, remote CI dispatch, merge, tag, release, automation, or app
source migration is part of this work.

The reviewed core input was `9d8053d5f921ebf5c38cc2f816efe90c7db4a450` plus
the approved encoded-request/macro-first working tree (tracked diff SHA-256
`7dae0a2b6fb86aabb072351133a8f0b2f452f2b9b87a95b0179f1483150e85d7`).
It was checkpointed as `ab757e1` before the fixes. The companion input was
`e6dc0ff414b15e044e667d192c3e30cc88d346b0` plus its approved working tree
(tracked diff SHA-256
`c0b987089b9e01bb3f0167c1ed8fcf41086a25218a590a6576dc8842a5a1c41c`),
checkpointed as `093dc45` in InnoNetwork-Protobuf. Existing adapter commits
were not rewritten.

The Swift source revisions used by final validation are core
`5b6ee48e31a0b7a2931646b79699b32d073d2ad5` and adapter
`cee712dd345afee3f4642279df57ad426bfc909b`. Core follow-up
`cf8b43b17c6dd6a132636614a706166e68c117fe` changes
only the DocC product ledger and its shell fixture; its affected checks are
rerun separately. No runtime/Swift test/package/benchmark source changed after
the complete suite and measurements. Subsequent evidence-only documentation
commits do not change their source, tests, package graphs, or validation tools.

## Finding-to-commit closure

| Finding | Fix and regression/control | Core commit |
| --- | --- | --- |
| F1, P1: conditional members silently omitted by macro inference | Reject direct conditional members before JSON or encoded endpoint inference. External protobuf compiler fixtures cover platform/custom conditions and accept a conditional around the entire endpoint. | `9c5ec29` |
| F3, P2 / F4, P3: escaped identifiers and generated-helper collision | Lookup uses semantic names, emission preserves source spelling, and generated path reads are qualified with `self`. Both macro families compile escaped body/path/typealias names and the helper-name collision. | `08ea3f4` |
| F2, P2: incompatible response caps share a physical transport | Effective buffered-response limits participate in coalescing identity. Strict/loose leaders both preserve independent outcomes; equal limits still share one physical request. | `dc75398` |
| F5, P2: non-S3 signing collapses distinct paths | Canonicalization normalizes literal encoded path segments, retaining trailing and encoded slash distinctions. Normal, dot-segment, repeated-slash, published signature-vector and S3 controls remain. | `2eace8e` |
| F6, P2: corrupt persisted cache costs cause negative accounting or traps | Validate nonnegative costs and checked sums before admission; recompute admitted body/header costs. Negative/overflow fixtures cold-reset only cache-owned data; incorrect nonnegative hints are corrected and survive reopening. | `9dfae77` |
| F7, P2: invalid/exhausted download sequence traps | Reject invalid numeric suffixes before applying events, preserve the valid prefix, and durably checkpoint/rebase exhausted sequences before a complete mutation batch. Normal replay, batch exhaustion, reopen, and injected checkpoint-sync failure are controls. | `73b105b` |
| F8, P2: new error contract omitted from examples/enum ledger | Update the real error-handling example, enum allowlist, canonical Unreleased notes and migration guidance together. Validate the actual examples, not an edited diagnostic copy. | `1828205` |
| F9, P2: prose-only changelog fails silently | Treat no leading-symbol match as an empty extraction, without ignoring missing symbols or I/O errors. Seven fixtures run in the existing local and CI gates. | `5b6ee48` |
| F10, P2, found during final validation: DocC product ledger omits the new compiler-host library | Add `InnoNetworkMacroSupport` in manifest order. Bind the positive fixture to the actual package manifest; reject a missing host archive or host ledger entry. The real ten-archive output passes without weakening the checker. | `cf8b43b` |

Adapter regression commits are `6919cdc` (conditional declarations and controls)
and `cee712d` (escaped identifiers, options and helper collision). No separate
protobuf transport/retry engine was introduced.

The original F1 fix narrowed accepted syntax by rejecting `#if` inside an
endpoint's direct member list. The subsequent 6.1 compatibility correction
supersedes that choice for the already-Stable JSON macro: preserve 6.0 generated
semantics and warn on conditional payloads. New encoded companions retain strict
rejection. Neither path implements arbitrary conditional macro inference. See
[migration notes](Migration-EncodedRequests.md) and the compatibility follow-up
in [the hardening record](PRE_RELEASE_HARDENING_2026_09_30.md).

F5 was checked against the official botocore implementation, specifically
[`SigV4Auth._normalize_url_path`](https://github.com/boto/botocore/blob/21f2f87daead94d25b0cf562422e752e9c2accc2/botocore/auth.py)
and [`remove_dot_segments`](https://github.com/boto/botocore/blob/21f2f87daead94d25b0cf562422e752e9c2accc2/botocore/utils.py).
This is canonicalization/vector evidence, not a live AWS service test.

## Fresh validation

Toolchain: Xcode 27.0 / Swift 6.4 on the local Mac. Adapter consumers use
`INNONETWORK_LOCAL_PATH` pointing to the exact core checkout above.
Final logs and the exit-code ledger are retained under
`.build/review-fixes-20260930/` in the core checkout; `validate-final.sh` records
the sequential commands. Full preflight artifacts are under
`.build/local-release-preflight/`.

Focused gates passed before final validation: complete JSON macro tests,
protobuf compiler controls, coalescing/AWS regressions, cache recovery tests,
download persistence/fsync/commit tests, actual stable examples, enum/changelog
gates, formatting and docs/API inventory. The initial coalescing test incorrectly
expected the nested transport-limit error code on the outer generic error; its
failure log is retained as `coalescing.log`. The corrected test inspects the
underlying limit error and passed without another production change.

| Gate | Fresh evidence |
| --- | --- |
| Core ordinary/TSAN/parallel regressions | Each inventory contains 1,986 registered tests: 1,982 ordinary passes and four explicit opt-in live skips. Four bounded shards pass. Repeated runs are not added as unique coverage. |
| Protobuf ordinary/TSAN regressions | 43 runtime plus two macro expansion tests pass in each run. Actual compiler gate rejects 22 declarations with two passing controls. |
| Consumers and generation | All 11 core consumer packages build; macro/OpenAPI executables, real stable/migration examples, doc smoke and subprocess resumable recovery pass. OpenAPI CLI has 49 passing tests and generated-output compile/runtime checks. Adapter doc/mixed/compatibility/macro-off consumers pass. |
| Streaming resources | Two 30-second soaks pass: 7,249,038 span attempts exactly accounted and 7,172,515 ordered deliveries followed by completed cancellation. |
| Coverage | Runtime line coverage 88.99%; compiler-host macro line coverage 79.45%, reported separately. Artifacts: `coverage-core/` and `coverage-macros/` under the preflight directory. |
| Performance | All 14 runtime and five JSON guards pass at the unchanged 20% limit. Each lane uses three interleaved baseline/head pairs. Runtime baseline `a4aaaba8b41553033f5d1f23fa94af85b52b4c3a`; JSON baseline `b358692e1e583b5cef1c97bb65208729b313f574`. Worst guarded runtime paired delta: cache revalidation -6.7405% (14.851 pp spread); JSON: anyOf all matches -5.7490% (4.005 pp spread). No retries, exemptions or baseline changes in this run. |
| Static, documentation and release tools | Formatting of 540 Swift files, dependency lock, API budget/tier/enum/changelog, release and CI negative fixtures, trait/safety checks, SBOMs and both workflow syntax checks pass. Runtime API inventory remains 1,764 plus 12 separate compiler-host declarations. |
| DocC | Documentation build succeeds. The first archive contract fails as F10; after the ledger/fixture fix, the unchanged real output passes for all ten public products. Missing-host archive and ledger controls fail as expected. |
| Apple SDKs | Adapter macOS execution and iOS Simulator/tvOS/watchOS/visionOS applied-macro builds pass. Core macOS/iOS Simulator Xcode builds and all ten public library targets on tvOS/watchOS/visionOS pass. This is SDK compilation, not device execution. |

The original full-preflight command is preserved as **exit 1**, not relabeled
green: it completed through performance/SBOM/documentation generation and failed
the DocC archive ledger check. `validate-final-platforms.sh` resumes the corrected
archive/fixture gate and the previously unexecuted five-platform phase with
separate exit records. This targeted continuation avoids rerunning unchanged
runtime tests and performance solely because a product-list fixture changed.

The continuation completed with exit 0 on 2026-09-30 at 05:43:34 UTC. All
fourteen local-preflight gate areas now have successful evidence, combining the
initial run and the corrected DocC/platform continuation; there is no claim that
the original full command itself returned success. The initial failure and its
exact missing-product diagnostic remain in `final-core-full-preflight.log`.

## Evidence boundaries

The prior read-only audit's failing reproducers and passing controls remain in
the adapter's `.build/{macro-review,deep-review}-20260930/` directories. They
describe the pre-fix input; their successful suites are not reused as final
candidate results. Historical performance failures and raw samples remain
preserved even if a fresh guard passes. A new passing sample does not explain
the earlier WebSocket lifecycle timing anomaly.

The optional persistent-cache telemetry bound and explicit multiple-owner
directory contract were not confirmed defects and are not new features in this
patch. No risk-based audit or passing suite proves an absence of further bugs.

Still outside this local evidence: Xcode 26 (not installed), exact-SHA remote CI,
published core 6.1 dependency resolution, real devices/OS background restoration,
dedicated server/IdP/exporter/FairPlay integration and live AWS. No Capto or other
application source was migrated. Published core 6.0 and the adapter's Draft
publication boundary are not changed by these local candidate commits.

The original core checkout, its `Derived/` and `InnoNetwork.xcodeproj/`, and the
archived JSON benchmark ref at `b358692e1e583b5cef1c97bb65208729b313f574` are
preserved. No post-push cleanup is applicable because no push was performed.
