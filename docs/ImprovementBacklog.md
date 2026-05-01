# Improvement Backlog

Last reviewed: 2026-05-01  
Baseline: `main` at `310fa2b`

This document records the review findings from the 2026-05-01 code review and
the status of the follow-up PR that addressed them. It separates completed
correctness/governance work from items that should stay as future design work.

## Completed in the Follow-up PR

### Macro / Codegen

- [x] `APIDefinitionMacro` generated witness access now follows the attached
  declaration: `public`/`open` stays public, `package` stays package, and
  default/internal declarations omit an explicit access modifier.
- [x] Macro expansion tests cover default/internal, package, and public
  endpoint declarations.
- [x] Generated-client boundary guidance was rechecked in `API_STABILITY.md`;
  stable generated clients should prefer the `APIDefinition` wrapper path, and
  low-level execution remains `@_spi(GeneratedClientSupport)`.

### WebSocket Lifecycle / State Machine

- [x] Stale `didOpen` callbacks during manual disconnect no longer cancel the
  close-handshake timeout or bypass terminal cleanup.
- [x] Regression coverage now exercises did-open-after-disconnect, terminal
  cleanup, reconnect-disabled/manual-disconnect behavior, event hub finish, and
  registry removal.
- [x] Deterministic lifecycle invariant tests cover terminal cleanup,
  manual-disconnect-wins, and stale-callback behavior through fixed transition
  sequences.
- [x] WebSocket lifecycle now has a package-internal reducer/FSM with
  generation, reconnect attempt, manual-disconnect, close-code, disposition,
  and error payloads.
- [x] `WebSocketTask.updateState(_:)` now enforces public legal transitions;
  test-only direct state setup uses `restoreStateForTesting(_:)`.
- [x] Manual disconnect, reconnect timer, stale callback, and terminal cleanup
  paths now execute ordered reducer effects. Terminal cleanup uses one
  generation-checked finalizer path after runtime cleanup and event delivery.
- [x] URLSession task identifiers now carry the connection generation used by
  delegate callbacks, so stale open/close/error callbacks cannot mutate a newer
  connection generation or consume reconnect-attempt budget.

### Swift Concurrency / Task Ownership

- [x] Long-lived task owner/cancel rules are documented in
  [TaskOwnership.md](TaskOwnership.md).
- [x] WebSocket lifecycle docs now call out terminal cleanup ownership and the
  stale-callback rule.
- [x] `Task.detached` policy is documented: use only when caller cancellation
  must not cancel shared work, such as auth refresh single-flight.

### Benchmark / Performance Governance

- [x] Benchmark runner now covers request pipeline, request coalescing,
  response cache lookup/revalidation, event hub delivery, download persistence
  restore, WebSocket send queue, and WebSocket lifecycle transition lookup.
- [x] `Benchmarks/Baselines/default.json` includes the new guarded benchmark
  entries.
- [x] PR CI uses the expanded guard set at 20%; scheduled/manual benchmark
  workflow uses the same set at 10%.
- [x] Benchmark README, CI DoC, release policy, and release notes document the
  guarded set and threshold rationale.

### Docs / Adoption

- [x] URLSession, Alamofire, and Moya migration guidance was added in
  [MigrationGuides.md](MigrationGuides.md).
- [x] Practical example links now point to auth refresh, pagination/CRUD,
  response cache, background download, WebSocket chat, and observability.
- [x] Install/adoption docs call out the Swift 6.2+ and iOS 18+/current Apple
  OS trade-off near the quick-start path.
- [x] Macro docs include access-control behavior and common failure cases.

### Cache / Offline Strategy

- [x] `ResponseCachePolicy` docs now distinguish executor-level response reuse
  from app-owned persistent offline storage.
- [x] Persistent response cache is explicitly left out of this PR and recorded
  as an optional companion product candidate.
- [x] Future disk cache policy requirements are listed: cache key, freshness,
  eviction, privacy, data protection, backup, and deletion behavior.

### Release / Governance

- [x] Release docs require API stability ledger and public symbol allowlist to
  be reviewed together when public/SPI declarations change.
- [x] DocC/sample smoke, docs-contract sync, and benchmark threshold policy are
  part of release/CI documentation.

## Remaining Follow-up Work

### P2: Benchmark Trend Automation

The guarded benchmark set is expanded, but historical trend storage and PR
comment automation remain future governance work.

Done when:

- scheduled benchmark output is stored across runs
- PRs can show a concise benchmark diff comment
- baseline updates include a human-readable rationale

### P3: Persistent Response Cache Product RFC

Persistent response cache remains a candidate companion product, not a core
API in this PR.

Done when:

- cache-key normalization, freshness precedence, eviction, privacy, data
  protection, backup exclusion, and account deletion semantics are fixed
- the package boundary is decided between first-party companion product and
  app-owned implementation guidance

### P3: Additional Adoption Cookbooks

Migration and example links now exist, but deeper cookbook pages can still be
added for WebSocket protocol policy, background transition behavior,
observability exporter adapters, and OpenAPI Generator packaging.
