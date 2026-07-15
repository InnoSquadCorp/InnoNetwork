#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-$repo_root/.build/macro-trait-graphs}"
mkdir -p "$output_dir"

manifest_json="$output_dir/package-dump.json"
default_dependencies="$output_dir/default-trait-dependencies.txt"

# `swift package show-traits` is unavailable in the SwiftPM bundled with
# Xcode 26.0.1 even though that toolchain supports package traits. The manifest
# dump is the stable machine-readable source for the declaration/default check.
xcrun swift package --package-path "$repo_root" dump-package > "$manifest_json"
python3 "$repo_root/Scripts/check_macro_trait_manifest.py" "$manifest_json"

xcrun swift package --package-path "$repo_root" \
  show-dependencies --format flatlist \
  | tee "$default_dependencies"
if ! grep -Fxq "swift-syntax" "$default_dependencies"; then
  echo "The default Macros trait graph must include swift-syntax." >&2
  exit 1
fi

echo "Macro trait manifest and default dependency graph are valid."
