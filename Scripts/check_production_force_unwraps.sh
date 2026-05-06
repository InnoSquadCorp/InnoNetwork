#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

production_paths=(
  Sources/InnoNetwork
  Sources/InnoNetworkDownload
  Sources/InnoNetworkPersistentCache
  Sources/InnoNetworkWebSocket
)

pattern='[A-Za-z0-9_)\]}]!'
temp_matches="$(mktemp)"
trap 'rm -f "$temp_matches"' EXIT

if command -v rg > /dev/null 2>&1; then
  rg -n --glob '*.swift' "$pattern" "${production_paths[@]}" > "$temp_matches" || true
else
  find "${production_paths[@]}" -name '*.swift' -type f -print0 \
    | xargs -0 grep -E -n "$pattern" > "$temp_matches" || true
fi

if [[ -s "$temp_matches" ]]; then
  echo "Found force unwrap-like expressions in production sources:"
  cat "$temp_matches"
  exit 1
fi
