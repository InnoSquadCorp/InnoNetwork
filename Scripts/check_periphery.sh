#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

periphery_bin="${PERIPHERY_BIN:-periphery}"
required_version="3.8.0"
if ! command -v "$periphery_bin" >/dev/null 2>&1; then
  echo "local-periphery: required Periphery $required_version is unavailable: $periphery_bin" >&2
  exit 69
fi
actual_version="$("$periphery_bin" version)"
if [[ "$actual_version" != "$required_version" ]]; then
  echo "local-periphery: expected $required_version, found $actual_version" >&2
  exit 69
fi

# Match CI's strict configuration, baseline and native SwiftPM index layout.
# Always rebuild the index; a stale or differently compiled store is not evidence.
echo "local-periphery: Periphery $actual_version, strict repository config, native rebuild"
"$periphery_bin" scan --config .periphery.yml -- --build-system native
