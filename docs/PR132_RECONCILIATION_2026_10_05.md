# PR #132 reconciliation — 2026-10-05

## Scope and architecture

Rebase the complete 23-commit `7957642bca41773bae12a5e201ed063d3e4ca08c`
encoded-request candidate onto main `8aec5ffd01e6ac4835a6a6324a39dad7c3896406`.
The main upload terminal/retry fix (#141), JSON schema preparation (#142),
dependency integration (#140), and CI isolation/recovery fixes (#133, #138,
#139, #143) remain intact. No merge, tag, release, or companion repository write.

The public buffered `EncodedRequest`/`EncodedAPIDefinition` boundary is an
intentional feature: codec ownership stays with companions, and execution reuses
Core cancellation, retries, response caps and operations without forcing Codable
or the `GeneratedClientSupport` SPI on companion consumers. The separate
`InnoNetworkMacroSupport` product exposes compiler-host expansion support only.
Existing companions using SPI do not make this new public boundary redundant.

Keep all final candidate corrections, including response-limit coalescing keys,
codec cancellation normalization, stable JSON conditional-member behavior,
bounded timing, persistent numeric recovery, and escaped macro identifiers.

## Integration repairs

- Preserve main's prose-safe changelog parser and both independent fixture suites.
- Cover compiler-host MacroSupport in the macro coverage lane, excluding it from
  runtime coverage. Synchronize the exact-command fixtures and the read-only
  release-validation workflow; no thresholds, test lanes or failure gates removed.
- Include MacroSupport on the DocC landing page and add an offline negative
  control that rejects a missing public-product link before Apple DocC execution.
- Align current API documentation with main's SwiftSyntax 604.0.x requirement.
- Reject named encoded definitions that declare unsupported request security
  before factory or client execution, with client/operation regression coverage.

## Fresh VM validation

- 209 automation policy/contract tests pass, including unchanged security gates.
- 94 Python script tests pass.
- Consumer CI contract fixtures: 12 tests, 44 assertions, zero failures.
- actionlint 1.7.12: all 15 workflows pass.
- Public-operations dependency/permissions/pinning checks, release-workflow
  contract, changelog positive/negative fixtures, runtime Sendable/print/shared
  coder/force-unwrap policies pass.
- Local Periphery wrapper fixtures (4), post-publication docs fixtures (10),
  release-state fixtures, and local preflight contract fixtures pass.

This Linux VM has no Swift/Xcode compiler or Apple SDK. Full docs contract
validation and DocC fixtures stop at `xcrun`; compiler-host symbol extraction,
Swift runtime/macro tests, TSAN, performance and Apple SDK builds have not been
validated here. These need the exact pushed head's GitHub CI. Historical local
Xcode reports elsewhere in this PR are not new evidence for this reconciled tree.

## Companion compatibility and release boundary

Core retains current main's SwiftSyntax 604.0.x dependency and resolved lock.
Protobuf candidate `4411f763ccfb0af79e6ff3f828399133fef5f0c6` requires
603.0.x. Its local Core override does not remove that incompatible SwiftSyntax
constraint. Its earlier paired results cannot establish compatibility with this
rebased head. A separately authorized companion change must align SwiftSyntax,
compile its macro tests and Debug/Release consumers against this exact Core head,
and retain macro-disabled/JSON coexistence coverage. No such companion edit or
public 6.1 release is performed by this PR reconciliation.

## First exact-head CI — 2026-10-06

[Run 37387153383](https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/37387153383)
validated pushed head `e7fe3030febbf627868965a3342b7583229b5066`.
Xcode 26/27 build/test/coverage, target shards, actual TSAN, Periphery, compiler-host
macro tests and rejection controls, all five Apple platforms, consumer examples,
OpenAPI, docs/API contracts, DocC site, both benchmark gates, full read-only release
validation, dependency review and CodeQL passed. The new credential rejection test
passed for both direct and operation routes.

The only direct job failure was four swift-format diagnostics in the newly added
test's multiline expected-code assertion. The follow-up extracts that expected
value into a short local binding; it changes no runtime code or CI gate. The final
head must independently pass CI; this first run is retained as historical evidence,
not substituted for final-head validation. No public release was made.
