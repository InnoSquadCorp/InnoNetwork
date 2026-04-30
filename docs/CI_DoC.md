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
4. `rg -n "@unchecked Sendable" Sources/InnoNetwork Sources/InnoNetworkDownload Sources/InnoNetworkWebSocket` returns no matches
5. Coverage report is generated under `.build/coverage/` and uploaded as a
   workflow artifact. When the `CODECOV_TOKEN` secret is configured the
   `lcov` payload is also uploaded to Codecov; without the token the upload
   step is skipped (the artifact alone is enough for manual review).
6. `apple-platform-build-smoke` runs `xcodebuild ... build` for macOS, iOS,
   tvOS, watchOS, and visionOS destinations. Simulator destinations are
   build-only; SwiftPM test+coverage remains the runtime test gate.
7. Consumer smoke builds the core consumer package, wrapper smoke, generated
   client recipe, and optional `Examples/MacroUsage` package so
   `InnoNetworkCodegen` stays covered without changing the core-only smoke.
8. The benchmark smoke guard runs `swift run InnoNetworkBenchmarks --quick`
   with `--enforce-baseline --max-regression-percent 20`. A regression
   beyond 20% on the guarded benchmarks fails the PR workflow. The
   scheduled/manual benchmark workflow uses the same guarded benchmarks with
   a stricter 10% threshold.

## Pass/Fail Policy

- A PR is considered complete only when all CI checks are green.
- If any check fails, the PR is not merge-ready.
- Concurrency regressions and `@unchecked Sendable` additions in production sources are blocking failures.

## Integration Tests Policy

- Network-dependent tests should remain opt-in via `INNONETWORK_RUN_INTEGRATION_TESTS=1`.
- Default CI runs deterministic unit tests only.

## Local Reproduction

Run the same commands locally:

```bash
sudo xcode-select -s /Applications/Xcode_26.0.1.app
xcrun swift package resolve
xcrun swift build
# Match CI: keep the coverage run non-parallel because instrumentation plus
# runner-level parallelism can starve wall-clock polling tests on macOS.
xcrun swift test --no-parallel --enable-code-coverage
rg -n "@unchecked Sendable" \
  Sources/InnoNetwork \
  Sources/InnoNetworkDownload \
  Sources/InnoNetworkWebSocket

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
  --guard-benchmark websocket/websocket-close-disposition-classify \
  --guard-benchmark websocket/websocket-ping-context-alloc \
  --max-regression-percent 20
```
