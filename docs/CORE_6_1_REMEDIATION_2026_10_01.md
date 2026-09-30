# Core 6.1 remediation execution

Status: local implementation and final local validation complete; PR delivery
pending. Not Ready or published; exact final remote CI is a separate gate.

The maintainer approved the ten-step remediation plan on 2026-10-01 and
requested that changes extend PR #132. Merge, tags and publication are not
part of this authorization.

## Inputs and preservation

- PR #132 was OPEN/Draft at `79e1900ed283c129ab9523c7661c2f1a8e9cdc3c`.
- Base main was `9d8053d5f921ebf5c38cc2f816efe90c7db4a450`.
- Original checkout: `InnoNetwork-encoded-request`. Its 18 tracked dirty paths
  and two untracked groups were copied into an isolated worktree; all twenty
  preserved file hashes matched. Original files are not edited or staged.
- Existing corrections were selectively integrated from Sources/Tests through
  `7dccf4c`, including the final direct custom decoder compatibility correction.
  The historical review-document commit was not copied wholesale.
- Local toolchain is Xcode 27 / Swift 6.4. Prior diagnostic, remote, device and
  companion successes are not final-candidate evidence.

## Steps

1. Integration: focused tests passed (86 runtime + 4 macro test functions;
   parameterized cases are reported separately by Swift Testing).
2. Bounded scheduling primitives: passed 11 test functions, including extreme
   finite Double/Duration, relative-boundary and cancellation controls. Actual
   ContinuousClock and SuspendingClock 24h slices cancel without fatal timer
   conversion; the 24h value is a slice, not a total wait cap.
3. Core deadline/queue/rate paths: passed 57 test functions. Large budgets
   remain pending after a timer slice; queued cancellation releases scope state,
   server cooldown survives dispatch rechecks, and ordinary deadline/queue/rate
   controls pass. The initial new test had a catch-type compile error; its log
   is retained separately from the successful corrected fixture.
4. WebSocket/monitor/restored download paths: passed 86 test functions (55
   socket, 3 core monitor/defaults, 28 download). Large heartbeat/pong/reconnect
   and restored deadlines remain pending across slices and drain on cancellation.
   Non-finite restored deadlines use observable existing terminal-failure cleanup;
   destination files are not deleted and no persistence schema changes were made.
5. Retry jitter/delay arithmetic: focused retry tests passed (20 functions).
   Finite extreme jitter samples do not create an infinite random range; normal
   jitter/base-cap controls retain their behavior. Non-finite configured values
   fail before dispatch and invalid custom computed delays fail before retry.
   Huge finite backoff remains pending across slices and cancels with no waiter.
   A new fixture's initial timeout constructor compile error was corrected; the
   failed compilation log is retained alongside the passing run.
6. Circuit backoff arithmetic: 252 circuit/resilience/retry functions passed.
   The implementation now caps before Duration addition, avoids narrow integer
   millisecond conversion, and preserves nanosecond precision. Ordinary and
   1e16-second failed-probe controls preserve the doubled open interval; Duration
   values beyond Int64 seconds do not require narrow components when opened.
7. Macro helper coverage and unused binding: direct companion analysis fixtures
   and all 70 macro test functions passed. Tests cover body/query, escaped route
   access, policies, access levels, all supported methods, empty endpoints,
   conditional/conflicting declarations and companion diagnostic rewriting.
   The unused expansion parameter binding was removed without changing its
   external signature. Initial fixture assumptions about a helper name and
   relative-path rejection were corrected against the existing shared contract;
   no path semantics were changed to satisfy the tests.
8. Documentation and local Periphery gate: strict Periphery 3.8.0 native scan,
   format (551 Swift files), 1,764 runtime declarations / 12 compiler-host
   declarations, and the historical 6.0 Ready-state contract passed. The latter
   is not a new publication/Ready approval. Current guidance distinguishes the
   published 6.0 release from the unpublished 6.1 candidate. Local fast/full
   lists are 8/15; four wrapper fixtures prove missing tool/version/strict
   failure handling, and ten publication-doc fixtures include LC_ALL=C Unicode.
   Fixture realpath/locale assumptions and a legacy date/text contract mismatch
   were corrected without weakening the Ready validator; failed logs remain.
9. Final frozen-source integration gates: complete. The first run at
   `bbb53f0` stalled in the existing companion retry-executor test because the
   seconds helper unnecessarily required elapsed wall time for ordinary waits.
   Its bounded-shard logs and sampled stack were preserved; only the owned
   stalled test process was stopped, not another build or a cleanup target.
   A bounded one-shot reproducer failed before the correction and passed after
   restoring the planned short-delay fast path. All 186 related test functions
   passed; long-delay slice/cancellation controls still pass. The corrected
   source was refrozen before the final full run. No benchmark ran in the
   incomplete first preflight.
10. Exact candidate evidence and remaining acceptance boundaries: recorded
    below. An evidence-only commit and one authorized push deliver the local
    work on PR #132; neither operation constitutes Ready approval or merge.

## Final frozen input and evidence

- Code/validation-input commit: `09bffad08848f7097f1682745978f6c8a327f088`.
- Source manifest: `.build/core-61-remediation/final-inputs.sha256`, SHA256
  `4ed1d6bae50b22245b0fd66652bdc3c54101c9036be6103f6882337cfee6f7dd`.
  Sources, tests, consumers, benchmark harness, scripts, manifests/lock and
  analysis/format configuration are included; generated artifacts and the
  evidence-only ledger outside Sources are excluded. Sources DocC is included.
- Core lock SHA256:
  `e5ec42801e7aacdad87bfcf414275a054412c4442f92d646d49f9b88d78a8fd3`.
- Fresh checks use Xcode 27 / Swift 6.4, macOS 27.0.1 on 2026-10-01 local time.
  Source equality was verified after preflight, TSAN and isolated integration.
  Earlier source-pair, consumer, remote or physical-device successes are not
  counted as final-candidate passes.

| Final local check | Result / exact scope |
|---|---|
| Canonical `run_local_release_preflight.sh --full` | Exit 0, all 15 gates; native strict Periphery 3.8.0 |
| Bounded shards and serial coverage | 2039 registered functions across eight bundles, 2035 ordinary passes, four explicitly opt-in live skips; argument cases are not added to function counts |
| Runtime/macro line coverage | 89.18% / 92.82%; direct `EncodedEndpointExpansion` helper 125/125 executable lines |
| Actual full TSAN | Exit 0, same 2039 inventory and four live skips; instrumented binary linking and executing TSAN frames verified. Separate eight-function clock control is not added to the full count |
| Guarded performance | 14 runtime + 5 JSON guards, zero failures, three interleaved pairs per lane, unchanged 20% limit and historical `a4aaaba` / `b358692` sources. Worst guarded deltas -3.7464% / -8.9561% |
| Contracts, examples and CLI | 1764 runtime / 12 compiler-host declarations; 11 consumer packages; 49 OpenAPI CLI functions; release/script/macro/trait fixtures and documentation smoke |
| Packaging/platforms | Two SBOMs, ten public-product DocC archives; macOS/iOS builds and ten public library targets each for tvOS/watchOS/visionOS |
| Stream pair | Source `971750d664643fb888937242aa130537daf8bb0f`: 645 registered with six environment skips in the default suite; required local quality lane executes eight AVPlayer/audio checks and one LL-HLS preload check; Apple validator/hlsreport pass for three playlists |
| Stream consumers | Aggregate/individual products each run in Debug/Release; macros, unchanged imports and Core cancellation pass |
| Protobuf pair | Source `4411f763ccfb0af79e6ff3f828399133fef5f0c6`: 43 runtime + 2 macro functions; Debug/Release public nested macro/operation/JSON coexistence and macro-disabled consumer pass |
| Actual loopback HTTP | Fresh cold/warm reports each 8/8. Typed JSON/Protobuf, eight authenticated results/one refresh, 503 bounded retry, byte limit, entry-signaled cancellation, persistent cache reopen and bounded telemetry. Warm cache reports zero network requests |
| Actual loopback WebSocket | Echo/pong and missing-pong typed disposition/terminal-failure/shutdown controls pass; owned fixture servers stopped |

Companion manifests use isolated local Core overrides. This proves this source
pair, not resolution/adoption of an unpublished 6.1 tag. Original companion
checkouts, locks and generated user artifacts are not edited.

## Approved-plan reconciliation

The read-only audit found nine completed implementation/validation steps and
one partial delivery step: this final ledger/commit/push. No additional
production-code discrepancy or unrequested feature was identified within the
approved criteria. This ledger completes the documented local part of step 10;
remote synchronization and post-push cleanup are checked during delivery.

| Temporary audit ID / approved step | Code or contract evidence | Final validation |
|---|---|---|
| TEMP-FR-001 / integration | `df6e00a`: bounds, codec/direct decoder/stream cancellation, refresh cancellation and preserved minor input | Focused controls and full suites |
| TEMP-FR-002 / scheduling helpers | `b4d09e8`, `09bffad`: relative budget, native clock slices, ordinary one-shot compatibility | Helper/native timer controls, bounded failed-before/passed-after regression, full TSAN |
| TEMP-FR-003 / five Core paths | `290afc9`: deadline, admission, token, sliding/fixed windows | No early expiry/dispatch, cancellation cleanup and regression suites |
| TEMP-FR-004 / five remaining paths | `7017999`: heartbeat/pong/reconnect, monitor, restored retry | Large-input/sentinel controls, restoration tests and actual sockets |
| TEMP-FR-005 / retry arithmetic | `edbb8df`: finite/saturating jitter and delay validation | Direct helper/executor, base-cap/ratio/invalid/cancellation controls |
| TEMP-FR-006 / circuit arithmetic | `423108e`: cap before Duration addition, no narrow millisecond conversion | Actual registry reset/probe and precision/saturation controls |
| TEMP-FR-007 / macro-first helper | `327f108`: external expansion label unchanged; unused binding removed | 70 Core macro functions, direct helper coverage, paired Debug/Release consumers |
| TEMP-FR-008 / quality/docs | `bbb53f0`: strict local Periphery, offline Published/Draft guidance | 8/15 lists, wrapper/publication fixtures, API/docs/legacy Ready validator |
| TEMP-FR-009 / final integration | Frozen source manifest above | All local checks in the final table, no old evidence substituted |
| TEMP-FR-010 / evidence and delivery | This evidence-only ledger and local reconciliation artifact | Source equality, preserved failures/inputs, explicit boundaries; one authorized PR push follows |

## Retained failures and raw artifacts

Raw root: `.build/core-61-remediation/`; canonical generated root:
`.build/local-release-preflight/` in the isolated implementation checkout.

- Successful runs: `final-full.log`, `final-tsan.log`,
  `final-tsan-linked-runtime.txt`, `final-tsan-loaded-runtime.log`,
  `final-integration-exits.txt`, `stream-*.log`, `protobuf-*.log`,
  `http-{cold,warm}-report.json`, `socket-{pong,drop}.log`.
- The TSAN download progress sample contains executing sanitizer memory-access
  frames. Its expensive 1000-entry persistence fixture completed successfully;
  sampling was read-only and no active build was stopped for cleanup.
- Incomplete first run: `final-full-first-stopped.log`,
  `final-first-bounded-stall/`, `bounded-stall-sample.txt`,
  `final-inputs-first.sha256`, `short-sleep-reproducer-before.log`,
  `short-sleep-regression-after.log`. It is not a passing preflight or benchmark.
- Initial typed-catch/constructor/helper-name/path/locale fixture assumptions
  and documentation-contract failures remain beside corrected passing logs.
- Benchmarks retain all six raw reports per lane and paired median/spread data;
  coverage retains lcov/summary, SBOM and DocC artifacts remain local.

## Remaining acceptance boundaries

- Latest physical iPhone inventory: disconnected, DDI services unavailable.
  No new cold/warm device execution is claimed; historical locked-device
  install/launch results are not current passes. Private device identifiers
  remain outside Git. No device unlock/install was attempted in this execution.
- Dedicated IdP/AWS/exporter/FairPlay services are unavailable by user-confirmed
  scope. Local fixture/unit results are not live vendor-service or FairPlay
  acceptance, nor background/locked-device OS relaunch acceptance.
- Exact final remote CI and Xcode 26 / Swift 6.2 remain separate from these
  Xcode 27 local results. PR #132 stays Draft; no Ready transition, merge,
  tag/publication, consumer-source migration or automation is performed.
- A completed scoped remediation and green local checks are not proof that
  no other defects exist in the repository.
