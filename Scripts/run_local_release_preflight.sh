#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export LC_ALL=C

mode="fast"
list_only=0

usage() {
  cat <<'USAGE'
Usage: bash Scripts/run_local_release_preflight.sh [--fast|--full] [--list]

Run the release checks that can be reproduced before a tag exists.

  --fast  Run deterministic contracts, consumer builds, tools, and bounded tests.
          This is the default.
  --full  Also generate coverage and SBOMs, enforce the 10% benchmark guards,
          build all-product DocC, and build all five supported Apple platforms.
  --list  Print the selected gate names without running them.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast)
      mode="fast"
      ;;
    --full)
      mode="full"
      ;;
    --list)
      list_only=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

fast_gates=(
  "release-script-fixtures"
  "dependency-lock"
  "static-contracts"
  "documentation-smoke"
  "consumer-examples"
  "openapi-generator"
  "bounded-tests"
)

full_only_gates=(
  "runtime-coverage"
  "macro-coverage"
  "guarded-benchmarks"
  "sbom-artifacts"
  "all-product-docc"
  "apple-platform-builds"
)

gates=("${fast_gates[@]}")
if [[ "$mode" == "full" ]]; then
  gates+=("${full_only_gates[@]}")
fi

if (( list_only == 1 )); then
  printf '%s\n' "${gates[@]}"
  exit 0
fi

required_commands=(git python3 xcrun)
if [[ "$mode" == "full" ]]; then
  required_commands+=(jq xcodebuild)
fi

for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "local-release-preflight: required command is unavailable: $command_name" >&2
    exit 69
  fi
done

if [[ "$mode" == "full" ]]; then
  for sdk in macosx iphonesimulator appletvos watchos xros; do
    if ! xcrun --sdk "$sdk" --show-sdk-path >/dev/null 2>&1; then
      echo "local-release-preflight: required Apple SDK is unavailable: $sdk" >&2
      exit 69
    fi
  done
fi

artifacts_dir="$repo_root/.build/local-release-preflight"
mkdir -p "$artifacts_dir"

run_release_script_fixtures() {
  bash Scripts/tests/test_validate_docs_release_state.sh
  bash Scripts/tests/test_validate_release_ref.sh
  bash Scripts/tests/test_generate_sbom.sh
  bash Scripts/tests/test_generate_dependency_snapshot.sh
}

run_dependency_lock() {
  git ls-files --error-unmatch Package.resolved >/dev/null
  xcrun swift package resolve
  git diff --exit-code -- Package.resolved
}

run_static_contracts() {
  bash Scripts/format.sh --lint
  bash Scripts/check_macro_trait_graphs.sh
  bash Scripts/check_core_trait_build.sh
  bash Scripts/check_docs_contract_sync.sh
  bash Scripts/check_stable_examples.sh
  python3 Scripts/check_example_platform_floors.py
  bash Scripts/check_migration_examples.sh
  bash Scripts/check_changelog_sync.sh
  bash Scripts/check_provisional_enum_cases.sh
  bash Scripts/check_macro_compile_failures.sh
  bash Scripts/check_unchecked_sendable.sh
  bash Scripts/check_shared_coders_mutation.sh
  bash Scripts/check_production_force_unwraps.sh
  bash Scripts/check_no_print_in_production.sh
}

run_documentation_smoke() {
  xcrun swift build --target InnoNetworkDocSmoke
  xcrun swift run InnoNetworkDocSmoke
}

run_consumer_examples() {
  local manifests=()
  local manifest
  local package_path
  while IFS= read -r manifest; do
    manifests+=("$manifest")
  done < <(find Examples -mindepth 2 -maxdepth 2 -name Package.swift -print | sort)

  if [[ ${#manifests[@]} -eq 0 ]]; then
    echo "local-release-preflight: no independent consumer examples were discovered" >&2
    exit 1
  fi

  for manifest in "${manifests[@]}"; do
    package_path="$(dirname "$manifest")"
    echo "Building consumer example: $package_path"
    xcrun swift build --package-path "$package_path"
  done
}

run_openapi_generator() {
  xcrun swift build --package-path Tools/openapi-to-innonetwork
  xcrun swift test --package-path Tools/openapi-to-innonetwork
}

run_bounded_tests() {
  bash Scripts/run_bounded_parallel_tests.sh
}

run_runtime_coverage() {
  local runtime_source_roots=()
  local source_root

  xcrun swift test --no-parallel --enable-code-coverage
  while IFS= read -r source_root; do
    runtime_source_roots+=("$source_root")
  done < <(
    find Sources -mindepth 1 -maxdepth 1 -type d \
      ! -name InnoNetworkMacros -print | sort
  )
  bash Scripts/generate_coverage_report.sh \
    .build \
    "$artifacts_dir/coverage-core" \
    "${runtime_source_roots[@]}"
}

run_macro_coverage() {
  xcrun swift test \
    --disable-experimental-prebuilts \
    --filter InnoNetworkMacroTests \
    --enable-code-coverage
  bash Scripts/generate_coverage_report.sh \
    .build \
    "$artifacts_dir/coverage-macros" \
    Sources/InnoNetworkMacros
}

run_guarded_benchmarks() {
  xcrun swift run -c release InnoNetworkBenchmarks \
    --quick \
    --json-path "$artifacts_dir/benchmarks.json" \
    --enforce-baseline \
    --max-regression-percent 10 \
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
    --guard-benchmark cache/response-cache-revalidation
}

run_sbom_artifacts() {
  SBOM_VERSION="$(git rev-parse --short HEAD)" \
    SBOM_TRAIT_PROFILE=default \
    bash Scripts/generate-sbom.sh "$artifacts_dir/sbom.cdx.json"
  SBOM_VERSION="$(git rev-parse --short HEAD)" \
    SBOM_TRAIT_PROFILE=core-only \
    bash Scripts/generate-sbom.sh "$artifacts_dir/sbom-core-only.cdx.json"
}

run_all_product_docc() {
  local public_products=(
    "InnoNetwork"
    "InnoNetworkAuthAWS"
    "InnoNetworkDownload"
    "InnoNetworkOpenAPI"
    "InnoNetworkPersistentCache"
    "InnoNetworkTestSupport"
    "InnoNetworkTrust"
    "InnoNetworkWebSocket"
  )
  local product
  local archive

  xcodebuild docbuild \
    -scheme InnoNetwork-Package \
    -destination 'generic/platform=macOS' \
    -skipMacroValidation \
    -derivedDataPath "$artifacts_dir/DocC"

  for product in "${public_products[@]}"; do
    archive="$artifacts_dir/DocC/Build/Products/Debug/$product.doccarchive"
    if [[ ! -d "$archive" ]]; then
      echo "local-release-preflight: expected DocC archive is missing: $archive" >&2
      exit 1
    fi
  done
  echo "Generated ${#public_products[@]} public product DocC archives."
}

run_apple_platform_builds() {
  xcodebuild \
    -scheme InnoNetwork-Package \
    -destination 'platform=macOS' \
    -skipMacroValidation \
    -derivedDataPath "$artifacts_dir/macos" \
    CODE_SIGNING_ALLOWED=NO \
    build
  xcodebuild \
    -scheme InnoNetwork-Package \
    -destination 'generic/platform=iOS Simulator' \
    -skipMacroValidation \
    -derivedDataPath "$artifacts_dir/ios" \
    CODE_SIGNING_ALLOWED=NO \
    build
  bash Scripts/build_apple_platform_targets.sh \
    tvOS appletvos arm64-apple-tvos16.0 "$artifacts_dir/tvos"
  bash Scripts/build_apple_platform_targets.sh \
    watchOS watchos arm64_32-apple-watchos9.0 "$artifacts_dir/watchos"
  bash Scripts/build_apple_platform_targets.sh \
    visionOS xros arm64-apple-xros1.0 "$artifacts_dir/visionos"
}

run_gate() {
  local gate="$1"
  echo "::group::Local release preflight: $gate"
  case "$gate" in
    release-script-fixtures) run_release_script_fixtures ;;
    dependency-lock) run_dependency_lock ;;
    static-contracts) run_static_contracts ;;
    documentation-smoke) run_documentation_smoke ;;
    consumer-examples) run_consumer_examples ;;
    openapi-generator) run_openapi_generator ;;
    bounded-tests) run_bounded_tests ;;
    runtime-coverage) run_runtime_coverage ;;
    macro-coverage) run_macro_coverage ;;
    guarded-benchmarks) run_guarded_benchmarks ;;
    sbom-artifacts) run_sbom_artifacts ;;
    all-product-docc) run_all_product_docc ;;
    apple-platform-builds) run_apple_platform_builds ;;
    *)
      echo "local-release-preflight: unknown gate: $gate" >&2
      exit 70
      ;;
  esac
  echo "::endgroup::"
}

for gate in "${gates[@]}"; do
  run_gate "$gate"
done

echo "Local release preflight ($mode) passed ${#gates[@]} gates."
echo "Artifacts: $artifacts_dir"
