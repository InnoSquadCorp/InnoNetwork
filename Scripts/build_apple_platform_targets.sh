#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "Usage: $0 <runtime> <sdk> <target-triple> [scratch-path]" >&2
  exit 64
fi

runtime="$1"
sdk="$2"
target_triple="$3"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_path="${4:-$repo_root/.build}"

case "$runtime:$sdk:$target_triple" in
  "tvOS:appletvos:arm64-apple-tvos16.0" | \
    "watchOS:watchos:arm64_32-apple-watchos9.0" | \
    "visionOS:xros:arm64-apple-xros1.0")
    ;;
  *)
    echo "Unsupported Apple platform build tuple: $runtime / $sdk / $target_triple" >&2
    exit 64
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to discover public library product targets." >&2
  exit 69
fi

sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

# A hosted runner can retain an Xcode device SDK after pruning the matching
# simulator runtime. SwiftPM cross-compilation validates the package's native
# platform branches without downloading a multi-gigabyte runtime that a
# build-only library gate never executes.
public_library_targets=()
while IFS= read -r target; do
  public_library_targets+=("$target")
done < <(
  xcrun swift package --package-path "$repo_root" dump-package |
    jq -r '.products[] | select(.type.library != null) | .targets[]' |
    sort -u
)

if [[ ${#public_library_targets[@]} -eq 0 ]]; then
  echo "No public library product targets were discovered." >&2
  exit 1
fi

for target in "${public_library_targets[@]}"; do
  xcrun swift build \
    --package-path "$repo_root" \
    --scratch-path "$scratch_path" \
    --triple "$target_triple" \
    --sdk "$sdk_path" \
    --target "$target"
done

echo "Built ${#public_library_targets[@]} public library targets for $runtime ($target_triple)."
