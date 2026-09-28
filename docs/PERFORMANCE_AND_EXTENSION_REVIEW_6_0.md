# 6.0 performance follow-up and extension review

Date: 2026-09-28. Baseline: `b358692e1e583b5cef1c97bb65208729b313f574`
on `codex/6.0-release-hardening`. Existing untracked `Derived/` and
`InnoNetwork.xcodeproj/` are excluded and preserved.

Authority: implement performance analysis/optimization and a dedicated JSON
benchmark contract. Other findings are review-only; schema extensions below
are recommendations, not approved implementation or release scope.

## Inventory, exit criteria and evidence boundaries

Nine products: core, AWS auth, download, upload, WebSocket, persistent cache,
OpenAPI adapter, trust and test support. Also macro, standalone generator,
public contracts, examples/consumers and CI/release tooling. HLS is external.

The review covers normal/failure/cancellation/concurrency/retry/restoration,
resource limits, observability and security where applicable. Exit means each
row below has evidence or a specific limitation, suspected issues have actual
implementation probes and controls, and authorized changes have regression and
performance checks. It does not mean every path has a new exhaustive proof.

Evidence directory: `/tmp/innonetwork6-performance-review.tQeXCh`.
It contains release binaries, Time Profiler traces and exported sample tables,
paired results, diagnostic probes and command logs. Temporary artifacts are
local evidence, not published release artifacts.

| Area | Evidence and closure |
| --- | --- |
| Core/cache/coalescing | Fresh source inspection, before/after release profiles and paired measurements; fresh core tests including URL admission controls. Cache freshness, invalidation generations, identity partitions and final transport admission are retained. |
| JSON/parser/codec/schema | Fresh inspection of all four implementation files, public-codec differential probes with controls, existing tests and five new release benchmark workloads. Compatibility and peak-resource observations below remain separate from confirmed defects. |
| Auth/AWS/signing | Fresh inspection of identity/origin/refresh boundaries and final signature/file-body handling; fresh core/AWS tests. No dedicated IdP or AWS account acceptance in this review. |
| Download/upload/restoration | Fresh cancellation/tombstone and upload restoration/actor-reentrancy inspection; fresh download/upload tests. Prior fresh-process recovery evidence reused; no new physical background-session acceptance. |
| WebSocket/streaming | Fresh messaging generation/slot-release/shutdown inspection and WebSocket tests. Prior 30-second component soak reused; no new overnight or app-RSS soak. |
| Persistent cache | Fresh anchored file IO/bounded reads inspection and storage recovery tests. Real-device protected-data lifecycle remains unverified. |
| OpenAPI adapter/generator/macro | Fresh anyOf generation/rejection inspection, deterministic output, Swift 6 typecheck and generated runtime fixtures (four anyOf and ten credential requests); root tests include 54 macro tests. Prior standalone generator 39-test evidence reused where unchanged. |
| Trust/test support/observability | Fresh trust-before-pin and telemetry boundary inspection plus root tests. Exporter delivery is synthetic; no dedicated external exporter service acceptance. |
| Public API/examples/consumers/platforms | Only package-internal runtime implementation changes; prior 11 examples, nine DocC products, seven full app builds and five-platform evidence refer to `e53ec95`, not the modified candidate. Current host regression evidence is fresh; other final-candidate platform/app gates must be refreshed before publication. |
| CI/release | Fresh benchmark parser/provenance/guard/negative-fixture checks. Runtime and JSON source baselines are separate. Final remote CI, companion release sequence and publication remain unexecuted. |

## Performance investigation

The previously reported -16.31% coalescing and -12.80% cache movement compared
against `a4aaaba`, spanning broad 6.0 hardening. It cannot be attributed to the
new JSON codec alone. The cache workload measures policy preparation and Vary
selection, not a network 304 exchange.

Before-profile findings (100,000 coalesced logical requests): URL construction
and admission are material CPU paths. `NetworkURLAdmission.validate` accounted
for 19.29% inclusive sample weight and host structure checks 10.91%.
The diagnostic waiter-count path accounted for only 0.02%; it is not a supported
explanation for the earlier throughput decline. Inclusive weights overlap and
must not be added together.

Changes retain validation frequency and every security boundary: replace
per-call scheme/delimiter sets with direct comparisons, use one host scalar
scan with the existing Unicode whitespace rejection, and skip structural path
decoding only when there are neither dots nor percent escapes. Positive and
negative controls include internationalized hosts, IPv6 zone identifiers,
encoded delimiters, Unicode whitespace and recursively encoded traversal.

Cache profiling found material value-copy/return-enum and clock costs. A trial
forced-inline wrapper measured -0.92% and was discarded. Removing the forwarding
overload also produced about 5.85M ops/s, within the original 5.86M ops/s range;
that trial was discarded too. Cache production code is unchanged. A material
optimization of value-copy/storage layout needs a separately justified design;
the earlier 12.80% movement is not claimed as recovered by this work.

The first URL candidate measured +2.70% coalescing throughput, but the pair
spread was 8.5%. This is not evidence of a repeatable 2.70% user-visible gain.
Profiles and final paired results must be considered together, and threshold
PASS must not be described as full recovery of the old decline.

The after-profile's sampled CPU weight was 15.262 seconds versus 21.860 before
for the same 100,000 logical requests. URL admission's inclusive weight fell
from 19.29% to 5.00%; the ordinary host scan no longer dominates. These are
instrumented sample weights, not an allocation count or a throughput promise.
The final host guard retains the old grapheme-aware bracket checks as well,
so bracket-plus-combining-mark spellings cannot widen IPv6 admission.

JSON adds five guarded workloads with exact-byte/branch/error assertions.
Its reviewed source baseline is `b358692`, independently remeasured on the
same runner. Existing runtime `a4aaaba` and absolute baseline values remain
unchanged. A developer-machine capture is not committed as an absolute CI
throughput target. See [benchmark governance](../Benchmarks/README.md).

Fresh JSON paired deltas against identical pre-optimization codec source:
parse -0.67%, decode -1.09%, encode +0.14%, all-branch validation -5.36%, work
exhaustion -2.09%; all five passed 20%. The all-branch pair spread was 14.7%,
larger than its delta. These are variability/baseline evidence, not JSON-code
optimization gains. The codec implementation itself was not changed.

## Additional observations, not silently fixed

No new confirmed production-contract defect is claimed by this review. Two
concrete behaviors merit follow-up; neither is evidence that the currently
declared generator subset accepts invalid schemas.

1. **Codable compatibility decision.** For `{}`, a custom model calling
   `container.superDecoder().singleValueContainer().decodeNil()` returns true
   with Foundation JSONDecoder but throws `invalidJSON` with PreservedJSONCoding.
   Missing-key behavior is not consistent between Foundation implementation and
   all Swift documentation. Decide whether to promise Foundation-compatible
   superclass decoding, then add missing/null/present and `forKey:` fixtures.
   This is a confirmed behavior difference, not yet a proven breach of a
   documented compatibility guarantee. Empty custom Encodable values fail with
   both codecs and were rejected as a defect candidate.
2. **Earlier encoding resource rejection.** With `maximumBytes: 8192`, encoding
   1,000 strings of 4,096 bytes processes all 1,000 before returning
   `resourceLimit`. A small array succeeds. Output admission is enforced, but
   the intermediate encoding tree retains multiple individually admitted raw
   buffers before final rendering. Add a separate retained-buffer accounting
   contract or earlier aggregate bound, including overwritten keys/container
   reuse and failed writes. Do not label maximumBytes a peak-RSS guarantee;
   arbitrary user Encodable work is not sandboxed. This is a resource-hardening
   opportunity, not a successful output-limit bypass.

## Recommended schema extension order

1. **Enum and bounds first.** Extend the generator IR and runtime validator
   together for enum, minimum/maximum/exclusive bounds, multipleOf and size
   limits. Compare JSON numeric values exactly without Double conversion or
   expanding enormous exponents. Enum equality is semantic, not raw-byte
   equality. Do not use Swift's canonical-equivalence string comparison for
   code-point equality; define string length by schema semantics, not Swift
   grapheme count.
   Add zero/one/multiple-match fixtures, unknown-field retention, encode/decode
   symmetry and hostile numeric/size limits before enabling generation.
2. **Pattern separately.** JSON Schema patterns use ECMA-262 expectations and
   are not implicitly anchored. Swift Regex or ICU cannot be substituted with
   an undocumented dialect change. Choose an explicitly tested supported
   subset/engine with bounded execution and reject unsupported constructs.
   A task timeout alone cannot bound a non-cooperative regex engine.
   Include Unicode, escaping and catastrophic-backtracking cases. `format`
   annotation versus assertion must be an explicit policy, not inferred.
3. **Local recursive references.** First compile references into an immutable
   graph/plan with stable schema identities. Bound document depth and shared
   work, track schema-node visits, and distinguish productive recursion from
   zero-progress cycles. Test self/mutual recursion, recursive anyOf and
   generated Swift value-layout constraints. Keep remote refs disabled until
   deterministic resolution, URI policy, size/time bounds and SSRF controls
   have their own contract.
4. **OpenAPI 3.1 as a separate dialect milestone.** Explicitly handle
   jsonSchemaDialect/$schema, JSON Schema 2020-12 boolean schemas, type/null
   semantics and reference siblings before advanced vocabularies such as
   dynamic references and unevaluated properties. Consider a separate optional
   schema product to keep the core dependency/size cost opt-in. Publish a
   keyword support matrix and run the official JSON Schema Test Suite plus
   generator/runtime fixtures; keep Preview until the promised dialect is
   covered. Do not call a few accepted 3.1 documents “full 3.1 support.”
   A whole-OpenAPI claim also needs a separate inventory of operation/parameter
   serialization, media types and webhook/callback surfaces, not just Schema
   Object keywords; explicitly decline unsupported generator roles.

Standards: [JSON Schema validation](https://json-schema.org/draft/2020-12/json-schema-validation),
[JSON Schema core](https://json-schema.org/draft/2020-12/json-schema-core),
[OpenAPI 3.1 schema dialect contract](https://spec.openapis.org/oas/v3.1.1.html#specifying-schema-dialects).
Compatibility reference: [Foundation JSONDecoder implementation](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/JSON/JSONDecoder.swift).

These are successive scope decisions, not a reason to keep adding unbounded
features to the existing 6.0 release candidate. Finish the declared acceptance
gates separately from deciding which new dialect features to approve.

## Final local verification and handoff

Implementation commits: `0746b23` (URL admission and controls), `c41ad23`
(JSON performance lane, tooling, workflow evidence and documentation).
Validation ran on the identical executable source before these local commits;
the report commit changes documentation only. No push/merge/tag/release occurred.

- Final bounded suite: 1,896 discovered; 1,892 ordinary tests passed, four
  opt-in public live tests skipped. The live results cited in the preceding
  release record belong to `e53ec95`, not this final candidate.
- Generated output: deterministic two-run output, Swift 6 typecheck, negative
  generation and runtime fixtures passed, including four anyOf and ten
  credential requests. These use synthetic URLProtocol transport.
- Format: 501 Swift files passed. API inventory stayed 1,691 (Stable 307,
  Provisional 1,351, SPI 33). Docs/changelog/draft-state checks passed.
- Benchmark/release tooling positive and negative fixtures passed, including
  missing JSON source/guards/artifacts, automation that skips runtime guards,
  malformed options, and missing JSON report signatures/publication entries.
- Final runtime lane was rebuilt and repeated after restoring the original
  grapheme-aware bracket condition. All 23 workloads completed and all 14
  guards passed. JSON completed five workloads/five guards. Each lane used
  three interleaved pairs and 20%, without waiver or resetting the old baseline.

| Final paired metric | Change | Pair spread | Interpretation |
| --- | --- | --- | --- |
| Request coalescing vs `a4aaaba` | +1.31% | 13.8% | Within observed variability; no fixed throughput gain promised |
| Cache policy preparation vs `a4aaaba` | -13.19% | 0.5% | Persistent decline remains; below the existing 20% gate, not “optimized away” |
| JSON all-branch validation vs `b358692` | -5.36% | 14.7% | Unchanged codec, variability exceeds delta |

Final reports: `final-runtime/results.json` and
`final-guards/json/results.json` under the evidence directory. Final runtime
command log: `final-validation.log`; root suite: `final-tests.log`.
Source fingerprints (SHA-256):

- URL admission: `cf6877ab10a281622c02c06c76fec1c123145033ce62a8829ad117395e04276d`
- Benchmark harness: `2d35933c14a202644f184b45053c181039dc79fca6851eba24bc7b8c4741d2e2`

Still open: safe cache-copy/layout optimization, the two JSON follow-up decisions
above, final-candidate platform/app checks, hosted CI/benchmark variability,
public availability of the JSON baseline SHA, and physical-device/dedicated
service acceptance. Neither these local passes nor this review establish
absence of all defects or unconditional release readiness.
