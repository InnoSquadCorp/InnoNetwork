#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: generate_coverage_report.sh <build-root> <output-directory> <source-root> [<source-root> ...]

Generate summary.txt and coverage.lcov from a SwiftPM coverage build. The
command fails when profiling data, test executables, source files, or the LCOV
payload are missing so CI cannot silently publish an empty coverage artifact.
USAGE
}

if [[ $# -lt 3 ]]; then
  usage
  exit 64
fi

build_root=$1
output_directory=$2
shift 2

if [[ ! -d "$build_root" ]]; then
  echo "Coverage build root does not exist: $build_root" >&2
  exit 1
fi

profdata_files=()
while IFS= read -r -d '' candidate; do
  profdata_files+=("$candidate")
done < <(find "$build_root" -name default.profdata -type f -print0)

if [[ ${#profdata_files[@]} -ne 1 ]]; then
  echo "Expected exactly one default.profdata under $build_root; found ${#profdata_files[@]}." >&2
  exit 1
fi
profdata=${profdata_files[0]}

llvm_cov_objects=()
while IFS= read -r -d '' xctest_bundle; do
  binary="$xctest_bundle/Contents/MacOS/$(basename "$xctest_bundle" .xctest)"
  if [[ -x "$binary" ]]; then
    llvm_cov_objects+=(--object "$binary")
  fi
done < <(find "$build_root" -name '*.xctest' -type d -print0)

if [[ ${#llvm_cov_objects[@]} -eq 0 ]]; then
  echo "No executable .xctest bundles found under $build_root." >&2
  exit 1
fi

source_files=()
for source_root in "$@"; do
  if [[ ! -d "$source_root" ]]; then
    echo "Coverage source root does not exist: $source_root" >&2
    exit 1
  fi
  while IFS= read -r -d '' source_file; do
    source_files+=("$source_file")
  done < <(find "$source_root" -name '*.swift' -type f -print0)
done

if [[ ${#source_files[@]} -eq 0 ]]; then
  echo "No Swift source files found in the requested coverage roots." >&2
  exit 1
fi

mkdir -p "$output_directory"
repository_root=$(git rev-parse --show-toplevel)
raw_lcov=$(mktemp "${TMPDIR:-/tmp}/innonetwork-coverage.XXXXXX")
trap 'rm -f "$raw_lcov"' EXIT

xcrun llvm-cov report \
  --instr-profile="$profdata" \
  --use-color=false \
  "${llvm_cov_objects[@]}" \
  --sources "${source_files[@]}" | tee "$output_directory/summary.txt"

xcrun llvm-cov export \
  --instr-profile="$profdata" \
  --format=lcov \
  "${llvm_cov_objects[@]}" \
  --sources "${source_files[@]}" > "$raw_lcov"

# Swift embeds absolute compilation paths in coverage maps. Keep uploaded
# artifacts deterministic and let Codecov match flag paths without relying on
# heuristic path fixing.
awk -v prefix="SF:${repository_root}/" '
  index($0, prefix) == 1 { $0 = "SF:" substr($0, length(prefix) + 1) }
  { print }
' "$raw_lcov" > "$output_directory/coverage.lcov"

if [[ ! -s "$output_directory/summary.txt" ]]; then
  echo "Coverage summary is empty: $output_directory/summary.txt" >&2
  exit 1
fi

if [[ ! -s "$output_directory/coverage.lcov" ]] \
  || ! grep -q '^SF:' "$output_directory/coverage.lcov"; then
  echo "LCOV payload is empty or has no source records: $output_directory/coverage.lcov" >&2
  exit 1
fi

if grep -q '^SF:/' "$output_directory/coverage.lcov"; then
  echo "LCOV payload still contains absolute source paths: $output_directory/coverage.lcov" >&2
  exit 1
fi
