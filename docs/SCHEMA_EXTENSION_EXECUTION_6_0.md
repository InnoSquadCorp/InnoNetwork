# Sequential schema extension execution

Baseline: `e2a5700`, 2026-09-28. The user approved the two codec follow-ups and
the extension order in `PERFORMANCE_AND_EXTENSION_REVIEW_6_0.md`. This record
supersedes that report's recommendation-only status, not its historic evidence.
Untracked `Derived/` and `InnoNetwork.xcodeproj/` are excluded and preserved.
Local implementation/commits only; publication is a separate gate.

## Design and acceptance

- Problem: intermediate encoding buffers are admitted individually, and absent
  superclass values differ from Foundation; schema branches currently reject
  useful constraints, patterns, recursion and 3.1 dialect constructs.
- Constraints: lossless bytes/numbers, payload-free failures, bounded work,
  deterministic offline generation, no new runtime dependency, Preview generator.
- Alternatives: use Foundation/ICU/general third-party schema engines, or extend
  the existing bounded codec/validator. Choose the latter to retain exact numeric
  semantics, explicit dialect boundaries and enforceable work budgets. Do not
  imply total RSS or arbitrary application Codable execution is sandboxed.
- Failure: unsupported schema syntax fails generation before output; resource
  exhaustion throws rather than becoming a nonmatching branch. Remote refs stay
  disabled. New APIs remain Provisionally Stable.
- Validation: focused negative and passing controls, Foundation differential
  tests, official schema fixtures for supported keywords, deterministic generated
  output/typecheck/runtime, API/docs gates, full host regression and JSON guards.

| Step | Scope | Completion evidence |
| --- | --- | --- |
| 0 | Aggregate retained encoding representation; absent/null/present superclass contracts | 14 focused tests passed; two original regressions failed before implementation (`/tmp/innonetwork-schema-codec-{red,final}.log`) |
| 1 | Enum, exact number bounds/multipleOf, string/item/property counts; generator/runtime together | 23 focused tests (including 22 parameter cases and 3,775 arithmetic comparisons), 41 generator tests, deterministic generated runtime/typecheck, API/docs gate passed. Logs: `/tmp/innonetwork-schema-{stage1-final,generator-stage1d,generated-stage1-final,api-stage1c}.log`. |
| 2 | Explicit bounded ECMA-compatible pattern subset, unsupported syntax rejection | 7 focused tests, including 19 pattern cases, 10 rejection cases, 40 ASCII differential comparisons and work exhaustion; 41 generator tests and generated runtime passed (`/tmp/innonetwork-schema-pattern*.log`). |
| 3 | Immutable local reference plan, productive recursion and cycle rejection | 10 focused tests, self/mutual/anyOf recursion, 20 concurrent validations, zero-progress rejection; 41 generator tests and recursive generated Swift runtime passed (`/tmp/innonetwork-schema-recursion*.log`). |
| 4 | Explicit 3.1 dialect, boolean schemas, type/null, ref siblings; support matrix | 355 examples in 18 pinned official fixture files passed, with local dialect/ref/budget controls. Generator: 45 tests passed. Deterministic generation, Swift 6 typecheck and the two-request 3.1 transport fixture passed. Final fast preflight passed all seven gates. |

The relevant inventory is core JSON, generator/parser/IR, generated consumers,
public API ledger, docs and CI gates. Other runtime products remain covered by
host regression, not newly re-audited here. Cross-feature checks cover ordinary
and failing matches, zero/one/multiple alternatives, unknown data preservation,
encode/decode symmetry, reuse/retry, concurrent independent calls, and resource
exhaustion. Synchronous codecs have no asynchronous cancellation surface.
Final-candidate Apple-platform/app builds, hosted CI, physical-device/dedicated
service checks remain separate release gates. Partial 3.1 support is never a
claim of the complete OpenAPI or JSON Schema specification.

## Integration findings resolved within this scope

- Deep ordinary typed-model normalization overflowed the Swift Testing worker
  stack, including in a serial run. The crash backtrace identified repeated
  `normalizedSchema` frames; it was not dismissed as a runner-only failure.
  Decoder/model-selection depth guards and a 16-level normalization bound now
  reject deep input, with both decoded and programmatically constructed tests
  plus shallow passing controls. This is a generator admission limit, not a
  reduction of the runtime document's separate depth contract.
- Lossless YAML initially rejected custom scalar tags but discarded collection
  and key tags. A reproducer failed in three roles; those roles now fail closed,
  with explicit standard map/sequence tags as passing controls. Evidence:
  `/tmp/innonetwork-schema-yaml-tags-{red,green}.log`.
- Two manifest formatting errors, guarded dictionary force unwraps, and a mutable
  capture in the newly written 3.1 URLProtocol fixture were corrected to satisfy
  the existing style and Swift 6 compilation gates. The fixture error is not a
  production transport regression.

Schema plans stay in core for this milestone, sharing the bounded codec and
avoiding duplicate validators or new runtime dependencies. A separate optional
schema product is not introduced here; moving these new Provisional APIs later
requires its own package/API compatibility decision. Full 3.1 support, remote
resolution, and advanced vocabularies remain explicitly out of scope.

## Final local regression evidence

Xcode 27.0 (27A266a), Apple Swift 6.4, arm64 macOS host. Final combined log:
`/tmp/innonetwork-schema-final-preflight-r3.log`.

- All seven fast preflight gates passed: release-script fixtures, dependency lock,
  static contracts, documentation smoke/fresh-process recovery, consumer examples,
  OpenAPI generator/typecheck/runtime and the bounded root suite.
- Root inventory: 1,916 tests discovered; 1,912 ordinary tests passed and four
  opt-in public live tests skipped. Official examples are parameterized cases
  inside that suite, not 355 additional independently discovered test functions.
- Generator: 45 tests across six suites; generated credential (10 requests),
  anyOf (four requests) and 3.1 (two requests) integration used synthetic
  URLProtocol transport, not external-service acceptance.
- Eleven consumer examples built; documentation smoke and three migration
  examples compiled. Format covered 517 Swift files.
- API inventory: 1,700 total; Stable 307, Provisional 1,360, SPI 33. Stable
  `@APIDefinition` is unchanged; new schema APIs remain Provisional.
- Fresh-process resumable recovery passed both resume-chunk and resume-finalize
  controls. `git diff --check` passes; pinned upstream test data is unchanged
  except trailing-whitespace normalization in one JSON fixture.

Final JSON performance guard results follow separately. The prior report's
whole-runtime performance numbers are reused historical evidence, not remeasured
cache/coalescing gains from this schema work.
