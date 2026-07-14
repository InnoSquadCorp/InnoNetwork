#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export LC_ALL=C

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-bounded-tests.XXXXXX")"
pids=()

cleanup() {
  local pid
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2> /dev/null || true
  done
  rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Swift Testing in the canonical Swift 6.2 toolchain runs tests concurrently
# inside one test process and does not honor SwiftPM's --num-workers limit.
# Build once, then use SwiftPM's bundled testing helper to load the test bundle
# in four independent processes. Calling `swift test` four times would not work:
# SwiftPM holds one lock for the shared .build directory and serializes them.
shard_names=(
  "core"
  "websocket"
  "download"
  "extensions"
)
shard_modules=(
  "InnoNetworkTests"
  "InnoNetworkWebSocketTests"
  "InnoNetworkDownloadTests"
  "InnoNetworkAuthAWSTests InnoNetworkPersistentCacheTests InnoNetworkLiveTests"
)

echo "Building the root test suite..."
xcrun swift build --build-tests

swift_path="$(xcrun --find swift)"
swift_usr_dir="$(dirname "$(dirname "$swift_path")")"
testing_helper="$swift_usr_dir/libexec/swift/pm/swiftpm-testing-helper"
bin_path="$(xcrun swift build --show-bin-path)"
test_binary="$bin_path/InnoNetworkPackageTests.xctest/Contents/MacOS/InnoNetworkPackageTests"
platform_path="$(xcrun --sdk macosx --show-sdk-platform-path)"

if [[ ! -x "$testing_helper" ]]; then
  echo "bounded-tests: SwiftPM testing helper is missing or not executable: $testing_helper" >&2
  exit 1
fi
if [[ ! -f "$test_binary" ]]; then
  echo "bounded-tests: root test bundle binary is missing: $test_binary" >&2
  exit 1
fi

framework_paths="$platform_path/Developer/Library/Frameworks:$platform_path/Developer/Library/PrivateFrameworks"
if [[ -n "${DYLD_FRAMEWORK_PATH:-}" ]]; then
  framework_paths="$DYLD_FRAMEWORK_PATH:$framework_paths"
fi
library_paths="$platform_path/Developer/usr/lib"
if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
  library_paths="$DYLD_LIBRARY_PATH:$library_paths"
fi

run_swift_testing() {
  env \
    DYLD_FRAMEWORK_PATH="$framework_paths" \
    DYLD_LIBRARY_PATH="$library_paths" \
    NO_COLOR=1 \
    "$testing_helper" \
    --test-bundle-path "$test_binary" \
    "$@" \
    "$test_binary" \
    --testing-library swift-testing
}

test_list="$work_dir/test-list.txt"
run_swift_testing --list-tests > "$test_list"

discovered_modules="$({
  awk -F. '/^[[:alnum:]_]+\./ { print $1 }' "$test_list"
} | sort -u)"
inventory_file="$work_dir/shard-modules.txt"
{
  for modules in "${shard_modules[@]}"; do
    IFS=' ' read -r -a module_names <<< "$modules"
    printf '%s\n' "${module_names[@]}"
  done
} > "$inventory_file"
duplicate_modules="$(sort "$inventory_file" | uniq -d)"
if [[ -n "$duplicate_modules" ]]; then
  echo "bounded-tests: test targets assigned to more than one shard:" >&2
  printf '%s\n' "$duplicate_modules" >&2
  exit 1
fi
expected_modules="$(sort -u "$inventory_file")"

if [[ -z "$discovered_modules" ]]; then
  echo "bounded-tests: Swift Testing returned no discoverable tests" >&2
  exit 1
fi

if [[ "$discovered_modules" != "$expected_modules" ]]; then
  echo "bounded-tests: shard inventory does not match discovered test targets" >&2
  echo "Expected:" >&2
  printf '%s\n' "$expected_modules" >&2
  echo "Discovered:" >&2
  printf '%s\n' "$discovered_modules" >&2
  exit 1
fi

logs=()
statuses=()
expected_counts=()
shard_filters=()
discovered_test_count="$(awk -F. '/^[[:alnum:]_]+\./ { count++ } END { print count + 0 }' "$test_list")"
echo "Discovered $discovered_test_count tests across ${#shard_names[@]} bounded shards."

for index in "${!shard_names[@]}"; do
  IFS=' ' read -r -a modules <<< "${shard_modules[index]}"
  expected_count=0
  filter_alternatives=""
  for module in "${modules[@]}"; do
    module_count="$(awk -F. -v module="$module" '$1 == module { count++ } END { print count + 0 }' "$test_list")"
    if (( module_count == 0 )); then
      echo "bounded-tests: module $module matched no discovered tests" >&2
      exit 1
    fi
    expected_count=$((expected_count + module_count))
    filter_alternatives="${filter_alternatives:+$filter_alternatives|}$module"
  done

  if (( ${#modules[@]} == 1 )); then
    shard_filters[index]="^${modules[0]}\\."
  else
    shard_filters[index]="^(${filter_alternatives})\\."
  fi
  expected_counts[index]="$expected_count"
  logs[index]="$work_dir/${shard_names[index]}.log"
  echo "Starting ${shard_names[index]} shard ($expected_count tests; ${shard_modules[index]})..."
  run_swift_testing \
    --no-parallel \
    --filter "${shard_filters[index]}" \
    > "${logs[index]}" 2>&1 &
  pids[index]=$!
done

failed=0
for index in "${!pids[@]}"; do
  if wait "${pids[index]}"; then
    statuses[index]=0
  else
    statuses[index]=$?
    failed=1
  fi
done
pids=()

verified_test_count=0
for index in "${!shard_names[@]}"; do
  echo "::group::${shard_names[index]} shard"
  cat "${logs[index]}"
  echo "::endgroup::"

  if (( statuses[index] != 0 )); then
    echo "bounded-tests: ${shard_names[index]} shard failed with exit ${statuses[index]}" >&2
    continue
  fi

  summary="$(grep -Eo 'Test run with [0-9]+ tests' "${logs[index]}" | tail -n 1 || true)"
  actual_count="$(awk '{ print $4 }' <<< "$summary")"
  if [[ ! "$actual_count" =~ ^[0-9]+$ ]] || [[ "$actual_count" != "${expected_counts[index]}" ]]; then
    echo "bounded-tests: ${shard_names[index]} shard ran ${actual_count:-an unknown number of} tests; expected ${expected_counts[index]}" >&2
    failed=1
    continue
  fi

  verified_test_count=$((verified_test_count + actual_count))
done

if (( failed != 0 )); then
  exit 1
fi

if (( verified_test_count != discovered_test_count )); then
  echo "bounded-tests: verified $verified_test_count tests; discovered $discovered_test_count" >&2
  exit 1
fi

echo "All $verified_test_count tests passed across ${#shard_names[@]} bounded shards."
