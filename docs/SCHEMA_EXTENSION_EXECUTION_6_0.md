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
| 4 | Explicit 3.1 dialect, boolean schemas, type/null, ref siblings; support matrix | Pending |

The relevant inventory is core JSON, generator/parser/IR, generated consumers,
public API ledger, docs and CI gates. Other runtime products remain covered by
host regression, not newly re-audited here. Cross-feature checks cover ordinary
and failing matches, zero/one/multiple alternatives, unknown data preservation,
encode/decode symmetry, reuse/retry, concurrent independent calls, and resource
exhaustion. Synchronous codecs have no asynchronous cancellation surface.
Final-candidate Apple-platform/app builds, hosted CI, physical-device/dedicated
service checks remain separate release gates. Partial 3.1 support is never a
claim of the complete OpenAPI or JSON Schema specification.
