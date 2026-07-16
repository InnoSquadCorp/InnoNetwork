# CI DoC (Definition of Completion)

This document defines the minimum completion criteria (DoC) for pull requests in InnoNetwork.

## Scope

- Applies to all PRs targeting `main`.
- Applies to direct pushes to `main`.
- Mirrors local validation commands used in development.

## Required CI Checks

The `CI` workflow must pass all of the following:

1. The root `Package.resolved` must remain tracked
   (`git ls-files --error-unmatch Package.resolved`), then
   `xcrun swift package resolve` must leave it unchanged. This is both the
   reproducible CI lock and GitHub's Swift dependency-graph input.
2. The pull-request-only `Dependency Review` job is blocking at `low` severity
   across runtime, development, and unknown scopes. It receives only
   `contents: read`; a graph failure is a failed check, not a skipped review.
3. `xcrun swift build`
4. `xcrun swift test --no-parallel --enable-code-coverage`
5. A separate blocking `bash Scripts/run_bounded_parallel_tests.sh` job builds
   the suite once, then loads its test bundle in four concurrent, target-filtered
   Swift Testing processes without coverage instrumentation. Every process uses
   `--no-parallel`, so the Swift 6.2 testing runtime cannot exceed the intended
   four-process bound. Direct bundle loading avoids SwiftPM's shared `.build`
   lock; the script also proves that every discovered test belongs to exactly
   one shard.
6. `rg -n "@unchecked Sendable"` across production targets, including
   `Sources/InnoNetworkMacros`, returns no matches.
7. `bash Scripts/check_shared_coders_mutation.sh` confirms the shared default
   JSON coders are never mutated after construction.
8. `bash Scripts/check_production_force_unwraps.sh` returns no matches in
   production source targets. Tests and smoke fixtures are excluded.
9. `bash Scripts/check_no_print_in_production.sh` returns no matches in
   production source targets. Tests and smoke fixtures are excluded.
10. Runtime and macro coverage reports are generated from explicit, disjoint
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
11. `apple-platform-build-smoke` runs `xcodebuild ... build` for macOS and iOS.
   For tvOS, watchOS, and visionOS it uses the installed device SDK plus the
   package's minimum target triple to cross-compile every public library
   product. This avoids depending on hosted-runner simulator runtimes that can
   be pruned independently of their SDKs. All five platforms are unconditional
   hard gates: a missing SDK, undiscoverable public product, or compile failure
   fails CI. SwiftPM test+coverage remains the runtime test gate.
12. `python3 Scripts/check_example_platform_floors.py` discovers every
    independent `Examples/*/Package.swift`, requires the root package's exact
    deployment floors, and requires both CI and release workflows to build
    every discovered example. A new correctly versioned example therefore
    cannot silently miss either gate.
13. Consumer smoke verifies `Macros` is a default trait, the default package
   graph includes `swift-syntax`, and the `InnoNetworkMacros` target
   dependency is conditioned on that trait. It then performs a clean
   `--disable-default-traits` root build and rejects compiled macro products
   before building separate core-only (`traits: []`), aggregate, wrapper,
   download-only, websocket-only, test-support, generated-client, event-policy
   observer, and macro usage packages, including
   `Examples/WrapperSmoke` and `Examples/EventPolicyObserver`.
   SwiftPM 6.2 can still resolve, fetch, or list manifest-level dependencies
   during a core-only build; the invariant is that macro products are absent
   from compilation. Traits are unified per package, so another dependency
   enabling default traits re-enables `Macros`.
14. `bash Scripts/check_provisional_enum_cases.sh` confirms guarded public enum
    cases still match their migration-review allowlist.
15. Macro tests run from source with
    `--disable-experimental-prebuilts --filter InnoNetworkMacroTests`, and
    `Scripts/check_macro_compile_failures.sh` verifies that invalid definitions
    fail with the intended diagnostic rather than compiling silently.
16. The CI benchmark smoke job runs
    `swift run -c release InnoNetworkBenchmarks --quick`
    and uploads the JSON summary to prove the benchmark CLI still builds and
    emits parseable results. Regression enforcement lives in the dedicated
    `Benchmarks` workflow: pull requests use the guarded benchmark set with
    `--enforce-baseline --max-regression-percent 20`, while scheduled/manual
    runs use the same guarded benchmarks with a stricter 10% threshold. Use
    `--guard-threshold group/name=percent` for benchmark-specific exceptions
    and `--regression-reason` when a PR intentionally updates or accepts a
    baseline movement; both values appear in the JSON artifact and PR comment.

The release workflow repeats the root lock, platform-floor, all-example,
platform-build, and full-test gates. It also builds and tests
`Tools/openapi-to-innonetwork`, matching the CI consumer-smoke contract before
release artifacts are generated.

## Pass/Fail Policy

- A PR is considered complete only when all CI checks are green.
- If any check fails, the PR is not merge-ready.
- Concurrency regressions and `@unchecked Sendable` additions in production sources are blocking failures.
- Force unwrap additions in production sources are blocking failures; fixture
  force unwraps belong in tests or smoke-only targets.
- Adding `print()` to production sources is a blocking failure. The rule is
  enforced by `bash Scripts/check_no_print_in_production.sh`, matching required
  check 9 above.

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
git ls-files --error-unmatch Package.resolved >/dev/null
xcrun swift package resolve
git diff --exit-code -- Package.resolved
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
python3 Scripts/check_example_platform_floors.py

# Verify default and core-only macro trait profiles.
bash Scripts/check_macro_trait_graphs.sh
bash Scripts/check_core_trait_build.sh
xcrun swift build --package-path Examples/CoreSmoke
xcrun swift build --package-path Examples/MacroUsage
xcrun swift build --package-path Examples/WrapperSmoke
xcrun swift build --package-path Examples/EventPolicyObserver
xcrun swift build --package-path Tools/openapi-to-innonetwork
xcrun swift test --package-path Tools/openapi-to-innonetwork

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
