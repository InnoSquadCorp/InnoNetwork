#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_path="$repo_root/.build/core-only-trait-build"

rm -rf "$scratch_path"
xcrun swift build \
  --package-path "$repo_root" \
  --scratch-path "$scratch_path" \
  --disable-default-traits \
  --target InnoNetwork

# SwiftPM 6.2 still resolves and lists manifest-level swift-syntax sources when
# default traits are disabled. The opt-out invariant is that none of the macro
# target's compiled products reach the clean core-only build.
compiled_macro_artifact="$(
  find "$scratch_path" \
    \( \
      -name 'InnoNetworkMacros-tool' \
      -o -name 'InnoNetworkMacros.swiftmodule' \
      -o -path '*/InnoNetworkMacros-tool.build/*.o' \
    \) \
    -print -quit
)"
if [[ -n "$compiled_macro_artifact" ]]; then
  echo "The core-only build compiled a macro artifact: $compiled_macro_artifact" >&2
  exit 1
fi

echo "Core-only InnoNetwork build excludes compiled macro products."
