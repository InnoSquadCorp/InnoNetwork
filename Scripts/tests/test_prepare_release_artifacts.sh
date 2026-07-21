#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
preparer="$repo_root/Scripts/prepare_release_artifacts.sh"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/prepare-release-artifacts-test.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

valid_root="$work_dir/valid"
mkdir -p "$valid_root/benchmarks"
printf '{"benchmarks": []}\n' > "$valid_root/benchmarks/results.json"
printf '{"bomFormat": "CycloneDX"}\n' > "$valid_root/sbom.cdx.json"
printf '{"bomFormat": "CycloneDX"}\n' > "$valid_root/sbom-core-only.cdx.json"

bash "$preparer" "$valid_root"
cmp --silent \
  "$valid_root/benchmarks/results.json" \
  "$valid_root/benchmarks.json"

missing_root="$work_dir/missing-benchmark"
mkdir -p "$missing_root/benchmarks"
printf '{"bomFormat": "CycloneDX"}\n' > "$missing_root/sbom.cdx.json"
printf '{"bomFormat": "CycloneDX"}\n' > "$missing_root/sbom-core-only.cdx.json"

if bash "$preparer" "$missing_root" >"$work_dir/missing.stdout" 2>"$work_dir/missing.stderr"; then
  echo "prepare-release-artifacts test: missing benchmark unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'benchmarks/results.json' "$work_dir/missing.stderr"

invalid_root="$work_dir/invalid-json"
mkdir -p "$invalid_root/benchmarks"
printf 'not-json\n' > "$invalid_root/benchmarks/results.json"
printf '{"bomFormat": "CycloneDX"}\n' > "$invalid_root/sbom.cdx.json"
printf '{"bomFormat": "CycloneDX"}\n' > "$invalid_root/sbom-core-only.cdx.json"

if bash "$preparer" "$invalid_root" >"$work_dir/invalid.stdout" 2>"$work_dir/invalid.stderr"; then
  echo "prepare-release-artifacts test: invalid JSON unexpectedly passed" >&2
  exit 1
fi
test ! -e "$invalid_root/benchmarks.json"

echo "Prepare release artifacts fixture tests passed."
