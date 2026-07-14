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
4. A separate blocking `xcrun swift test --parallel` job exercises the full
   suite under SwiftPM parallel scheduling without coverage instrumentation.
5. `rg -n "@unchecked Sendable" Sources/InnoNetwork Sources/InnoNetworkDownload Sources/InnoNetworkPersistentCache Sources/InnoNetworkWebSocket` returns no matches
6. `bash Scripts/check_shared_coders_mutation.sh` confirms the shared default
   JSON coders are never mutated after construction.
7. `bash Scripts/check_production_force_unwraps.sh` returns no matches in
   production source targets. Tests and smoke fixtures are excluded.
8. `bash Scripts/check_no_print_in_production.sh` returns no matches in
   production source targets. Tests and smoke fixtures are excluded.
9. Coverage report is generated under `.build/coverage/` and uploaded as a
   workflow artifact. When the `CODECOV_TOKEN` secret is configured the
   `lcov` payload is also uploaded to Codecov; without the token the upload
   step is skipped (the artifact alone is enough for manual review).
10. `apple-platform-build-smoke` runs `xcodebuild ... build` for macOS, iOS,
   tvOS, watchOS, and visionOS destinations. Simulator destinations are
   build-only; SwiftPM test+coverage remains the runtime test gate. All five
   declared platforms are required on the pinned canonical Xcode runner; a
   missing SDK is a failure rather than a skipped green build.
11. Consumer smoke first asserts that the root package dependency graph does not
   contain `swift-syntax`, then builds separate core-only, aggregate,
   download-only, websocket-only, test-support, generated-client, and codegen
   usage packages. Macro tests run from `Packages/InnoNetworkCodegen` so the
   codegen dependency graph stays isolated from root package consumers.
12. `bash Scripts/check_provisional_enum_cases.sh` confirms guarded public enum
    cases still match their migration-review allowlist.
13. The codegen package runs its complete test target rather than a named-test
    filter, so newly added macro suites are included automatically.
14. The CI benchmark smoke job runs `swift run InnoNetworkBenchmarks --quick`
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
xcrun swift test --parallel
xcrun swift test --no-parallel --enable-code-coverage
rg -n "@unchecked Sendable" \
  Sources/InnoNetwork \
  Sources/InnoNetworkDownload \
  Sources/InnoNetworkPersistentCache \
  Sources/InnoNetworkWebSocket
bash Scripts/check_production_force_unwraps.sh
bash Scripts/check_no_print_in_production.sh
bash Scripts/check_shared_coders_mutation.sh
bash Scripts/check_provisional_enum_cases.sh

# Optional: render the same coverage artifacts CI uploads.
profdata="$(find .build -name 'default.profdata' -type f | head -n 1)"
llvm_cov_objects=()
while IFS= read -r -d '' xctest_bundle; do
  binary="$xctest_bundle/Contents/MacOS/$(basename "$xctest_bundle" .xctest)"
  if [[ -x "$binary" ]]; then
    llvm_cov_objects+=(--object "$binary")
  fi
done < <(find .build -name '*.xctest' -type d -print0)
if [[ -z "$profdata" || ${#llvm_cov_objects[@]} -eq 0 ]]; then
  echo "Coverage artifacts not found; skipping report."
  exit 0
fi
mkdir -p .build/coverage
xcrun llvm-cov report \
  --instr-profile="$profdata" \
  --use-color=false \
  --ignore-filename-regex='(^|/)(\.build|Tests|SmokeTests|Examples|Benchmarks)/' \
  "${llvm_cov_objects[@]}" | tee .build/coverage/summary.txt
xcrun llvm-cov export \
  --instr-profile="$profdata" \
  --format=lcov \
  --ignore-filename-regex='(^|/)(\.build|Tests|SmokeTests|Examples|Benchmarks)/' \
  "${llvm_cov_objects[@]}" > .build/coverage/coverage.lcov

# Optional: replay the benchmark smoke guard locally.
xcrun swift run InnoNetworkBenchmarks --quick \
  --enforce-baseline \
  --guard-benchmark events/task-event-fanout-single \
  --guard-benchmark persistence/download-persistence-restore \
  --guard-benchmark persistence/append-log-compaction \
  --guard-benchmark websocket/websocket-close-disposition-classify \
  --guard-benchmark websocket/websocket-ping-context-alloc \
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
