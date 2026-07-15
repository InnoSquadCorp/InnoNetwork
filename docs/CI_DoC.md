# CI DoC (Definition of Completion)

This document defines the minimum completion criteria (DoC) for pull requests in InnoNetwork.

## Scope

- Applies to all PRs targeting `main`.
- Applies to direct pushes to `main`.
- Mirrors local validation commands used in development.

## Required CI Checks

The `CI` workflow must pass all of the following:

1. `xcrun swift package resolve`
2. `xcrun swift build`
3. `xcrun swift test --no-parallel --enable-code-coverage`
4. A separate blocking `bash Scripts/run_bounded_parallel_tests.sh` job builds
   the suite once, then loads its test bundle in four concurrent, target-filtered
   Swift Testing processes without coverage instrumentation. Every process uses
   `--no-parallel`, so the Swift 6.2 testing runtime cannot exceed the intended
   four-process bound. Direct bundle loading avoids SwiftPM's shared `.build`
   lock; the script also proves that every discovered test belongs to exactly
   one shard.
5. `rg -n "@unchecked Sendable"` across production targets, including
   `Sources/InnoNetworkMacros`, returns no matches.
6. `bash Scripts/check_shared_coders_mutation.sh` confirms the shared default
   JSON coders are never mutated after construction.
7. `bash Scripts/check_production_force_unwraps.sh` returns no matches in
   production source targets. Tests and smoke fixtures are excluded.
8. `bash Scripts/check_no_print_in_production.sh` returns no matches in
   production source targets. Tests and smoke fixtures are excluded.
9. Runtime and macro coverage reports are generated from explicit, disjoint
   source roots under `.build/coverage/` and `.build/coverage-macros/`, then uploaded as
   separate workflow artifacts. Missing profiling data, test executables,
   source files, or LCOV records fail the job; artifact upload also uses
   `if-no-files-found: error`. Codecov receives only those explicit reports
   with `disable_search: true`, using separate `core` and `macros` flags.
   Dedicated upload jobs authenticate with short-lived GitHub OIDC credentials
   instead of a repository secret, so dependency builds and tests never receive
   `id-token: write`. They download a fixed Codecov CLI release and verify its
   SHA-256 before handing it to the pinned action, avoiding an unreviewed
   `latest` binary at upload time. Pull requests retain artifact-only fallback
   when CLI installation or an upload fails, while canonical `main` pushes
   require both uploads.
10. `apple-platform-build-smoke` runs `xcodebuild ... build` for macOS, iOS,
   tvOS, watchOS, and visionOS destinations. Simulator destinations are
   build-only; SwiftPM test+coverage remains the runtime test gate. macOS and
   iOS are required. tvOS, watchOS, and visionOS build whenever the pinned
   hosted runner exposes a compatible SDK and destination; a missing optional
   platform component emits an explicit notice, while a source or build
   failure on an available destination still fails the job.
11. Consumer smoke verifies `Macros` is a default trait, the default target
   graph includes `swift-syntax`, and the `--disable-default-traits` target
   graph excludes it. It builds the root `InnoNetwork` target with default
   traits disabled, then builds separate core-only (`traits: []`), aggregate,
   download-only, websocket-only, test-support, generated-client, and macro
   usage packages. SwiftPM can still resolve or fetch manifest-level
   dependencies during a core-only build; the invariant is that macro products
   are absent from the target graph and compilation. Traits are unified per
   package, so another dependency enabling default traits re-enables `Macros`.
12. `bash Scripts/check_provisional_enum_cases.sh` confirms guarded public enum
    cases still match their migration-review allowlist.
13. Macro tests run from source with
    `--disable-experimental-prebuilts --filter InnoNetworkMacroTests`, and
    `Scripts/check_macro_compile_failures.sh` verifies that invalid definitions
    fail with the intended diagnostic rather than compiling silently.
14. The CI benchmark smoke job runs
    `swift run -c release InnoNetworkBenchmarks --quick`
    and uploads the JSON summary to prove the benchmark CLI still builds and
    emits parseable results. Regression enforcement lives in the dedicated
    `Benchmarks` workflow: pull requests use the guarded benchmark set with
    `--enforce-baseline --max-regression-percent 20`, while scheduled/manual
    runs use the same guarded benchmarks with a stricter 10% threshold. Use
    `--guard-threshold group/name=percent` for benchmark-specific exceptions
    and `--regression-reason` when a PR intentionally updates or accepts a
    baseline movement; both values appear in the JSON artifact and PR comment.

## Pass/Fail Policy

- A PR is considered complete only when all CI checks are green.
- If any check fails, the PR is not merge-ready.
- Concurrency regressions and `@unchecked Sendable` additions in production sources are blocking failures.
- Force unwrap additions in production sources are blocking failures; fixture
  force unwraps belong in tests or smoke-only targets.
- Adding `print()` to production sources is a blocking failure. The rule is
  enforced by `bash Scripts/check_no_print_in_production.sh`, matching required
  check 8 above.

## Integration Tests Policy

- Network-dependent tests should remain opt-in via `INNO_LIVE=1`.
- Default CI runs deterministic unit tests only.
- `Nightly Live Smoke` runs core live tests, WebSocket, persistent cache,
  Download pause/resume, and OpenAPI as independent jobs so one slow endpoint
  cannot prevent the other surfaces from reporting. WebSocket and OpenAPI stay
  best-effort because their public fixtures are third-party services; the fixed
  Download fixture is a blocking regression signal for completion staging.

## Local Reproduction

Run the same commands locally:

```bash
sudo xcode-select -s /Applications/Xcode_26.0.1.app
xcrun swift package resolve
xcrun swift build
# Match both blocking test lanes.
bash Scripts/run_bounded_parallel_tests.sh
xcrun swift test --no-parallel --enable-code-coverage
rg -n "@unchecked Sendable" \
  Sources/InnoNetwork \
  Sources/InnoNetworkMacros \
  Sources/InnoNetworkDownload \
  Sources/InnoNetworkPersistentCache \
  Sources/InnoNetworkWebSocket
bash Scripts/check_production_force_unwraps.sh
bash Scripts/check_no_print_in_production.sh
bash Scripts/check_shared_coders_mutation.sh
bash Scripts/check_provisional_enum_cases.sh

# Verify default and core-only macro trait profiles.
xcrun swift package show-traits
xcrun swift package show-dependencies --format flatlist
xcrun swift package --disable-default-traits \
  show-dependencies --format flatlist
xcrun swift build --disable-default-traits --target InnoNetwork
xcrun swift build --package-path Examples/CoreSmoke
xcrun swift build --package-path Examples/MacroUsage

# Render the same explicit coverage artifacts CI uploads. These commands fail
# instead of silently accepting missing or empty coverage inputs.
# Match the runtime report's explicit exclusion of macro implementation files.
runtime_source_roots=()
while IFS= read -r source_root; do
  runtime_source_roots+=("$source_root")
done < <(
  find Sources -mindepth 1 -maxdepth 1 -type d \
    ! -name InnoNetworkMacros -print | sort
)
bash Scripts/generate_coverage_report.sh \
  .build .build/coverage "${runtime_source_roots[@]}"

xcrun swift test --disable-experimental-prebuilts \
  --filter InnoNetworkMacroTests --enable-code-coverage
bash Scripts/generate_coverage_report.sh \
  .build \
  .build/coverage-macros \
  Sources/InnoNetworkMacros
bash Scripts/check_macro_compile_failures.sh

# Optional: replay the benchmark smoke guard locally.
xcrun swift run -c release InnoNetworkBenchmarks --quick \
  --enforce-baseline \
  --guard-benchmark events/task-event-fanout-single \
  --guard-benchmark persistence/download-persistence-restore \
  --guard-benchmark persistence/append-log-compaction \
  --guard-benchmark websocket/websocket-close-disposition-classify \
  --guard-benchmark websocket/websocket-ping-context-create \
  --guard-benchmark websocket/websocket-send-queue-reserve \
  --guard-benchmark websocket/websocket-lifecycle-transition-table \
  --guard-benchmark client/request-pipeline \
  --guard-benchmark client/request-coalescing-shared-get \
  --guard-benchmark client/decoding-interceptor-chain-1 \
  --guard-benchmark client/decoding-interceptor-chain-3 \
  --guard-benchmark client/decoding-interceptor-chain-8 \
  --guard-benchmark cache/response-cache-lookup \
  --guard-benchmark cache/response-cache-revalidation \
  --max-regression-percent 20
```
