#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_root="${1:-$repo_root/.build/release-artifacts}"
benchmark_source="$artifact_root/benchmarks/results.json"
benchmark_target="$artifact_root/benchmarks.json"

required_sources=(
  "$benchmark_source"
  "$artifact_root/sbom.cdx.json"
  "$artifact_root/sbom-core-only.cdx.json"
)

for artifact in "${required_sources[@]}"; do
  if [[ ! -s "$artifact" ]]; then
    echo "prepare-release-artifacts: required artifact is missing or empty: $artifact" >&2
    exit 1
  fi

  python3 - "$artifact" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    json.load(stream)
PY
done

cp "$benchmark_source" "$benchmark_target"
cmp --silent "$benchmark_source" "$benchmark_target"

printf 'prepare-release-artifacts: OK (%s)\n' "$artifact_root"
