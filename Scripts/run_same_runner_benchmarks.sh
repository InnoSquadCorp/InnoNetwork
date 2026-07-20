#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
output_dir="$repo_root/.build/benchmarks"
base_revision=""
uses_reviewed_base_revision=0
max_regression_percent="20"
regression_reason="${INNO_BENCHMARK_REGRESSION_REASON:-}"
validate_only=0

usage() {
  cat <<'USAGE'
Usage: bash Scripts/run_same_runner_benchmarks.sh [options]

Build and interleave three release-mode benchmark samples for a base revision
and the current working tree, then enforce the guarded median comparison.

  --base-revision SHA       Override the reviewed source revision (for example,
                            with a possibly divergent pull-request base SHA).
  --output-dir PATH         Artifact directory (default: .build/benchmarks).
  --max-regression-percent  Guard threshold (default: 20).
  --regression-reason TEXT  Record an intentional movement in the comparison.
  --validate-only           Validate revision provenance without building.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-revision)
      if [[ $# -lt 2 ]]; then
        echo "same-runner-benchmarks: --base-revision requires a value" >&2
        exit 64
      fi
      base_revision="$2"
      shift
      ;;
    --output-dir)
      if [[ $# -lt 2 ]]; then
        echo "same-runner-benchmarks: --output-dir requires a value" >&2
        exit 64
      fi
      output_dir="$2"
      shift
      ;;
    --max-regression-percent)
      if [[ $# -lt 2 ]]; then
        echo "same-runner-benchmarks: --max-regression-percent requires a value" >&2
        exit 64
      fi
      max_regression_percent="$2"
      shift
      ;;
    --regression-reason)
      if [[ $# -lt 2 ]]; then
        echo "same-runner-benchmarks: --regression-reason requires a value" >&2
        exit 64
      fi
      regression_reason="$2"
      shift
      ;;
    --validate-only)
      validate_only=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "same-runner-benchmarks: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

if [[ -z "$base_revision" ]]; then
  uses_reviewed_base_revision=1
  source_revision_path="$repo_root/Benchmarks/Baselines/source-revision.txt"
  if [[ ! -f "$source_revision_path" ]]; then
    echo "same-runner-benchmarks: baseline source revision is missing" >&2
    exit 1
  fi
  base_revision="$(<"$source_revision_path")"
fi

if [[ ! "$base_revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "same-runner-benchmarks: base revision must be a lowercase 40-character SHA" >&2
  exit 1
fi

if [[ ! "$max_regression_percent" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "same-runner-benchmarks: max regression percent must be a non-negative number" >&2
  exit 64
fi

if ! git -C "$repo_root" cat-file -e "${base_revision}^{commit}" 2>/dev/null; then
  echo "same-runner-benchmarks: base revision is unavailable: $base_revision" >&2
  exit 1
fi

head_revision="$(git -C "$repo_root" rev-parse HEAD)"
if ((uses_reviewed_base_revision == 1)) \
  && ! git -C "$repo_root" merge-base --is-ancestor "$base_revision" "$head_revision"; then
  echo "same-runner-benchmarks: reviewed base revision is not an ancestor of HEAD" >&2
  exit 1
fi

if ((validate_only == 1)); then
  echo "same-runner-benchmarks: OK (base $base_revision, head $head_revision)"
  exit 0
fi

for command in git python3 xcrun; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "same-runner-benchmarks: required command is unavailable: $command" >&2
    exit 69
  fi
done

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
cache_path="$repo_root/.build/swiftpm-cache"
mkdir -p "$cache_path"

worktree_parent="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-benchmark-base.XXXXXX")"
base_worktree="$worktree_parent/base"
missing_baseline="$worktree_parent/missing-baseline.json"
cleanup() {
  git -C "$repo_root" worktree remove --force "$base_worktree" >/dev/null 2>&1 || true
  rm -rf "$worktree_parent"
}
trap cleanup EXIT

git -C "$repo_root" worktree add --detach "$base_worktree" "$base_revision"

# Measure both implementations with the candidate's benchmark methodology.
# This prevents an iteration-count or warmup change in the harness itself from
# appearing as a runtime regression, while production sources still come from
# their respective revisions.
cp \
  "$repo_root/Benchmarks/InnoNetworkBenchmarks/main.swift" \
  "$base_worktree/Benchmarks/InnoNetworkBenchmarks/main.swift"

build_root="${RUNNER_TEMP:-$repo_root/.build/same-runner-benchmark-builds}"
mkdir -p "$build_root"
base_scratch="$build_root/base-${base_revision:0:12}"
head_scratch="$build_root/head-${head_revision:0:12}"

swift_build() {
  local package_path="$1"
  local scratch_path="$2"
  (
    cd "$package_path"
    xcrun swift build -c release \
      --disable-default-traits \
      --product InnoNetworkBenchmarks \
      --scratch-path "$scratch_path" \
      --cache-path "$cache_path"
  )
}

swift_bin_path() {
  local package_path="$1"
  local scratch_path="$2"
  (
    cd "$package_path"
    xcrun swift build -c release \
      --disable-default-traits \
      --scratch-path "$scratch_path" \
      --cache-path "$cache_path" \
      --show-bin-path
  )
}

swift_build "$base_worktree" "$base_scratch"
swift_build "$repo_root" "$head_scratch"

base_bin="$(swift_bin_path "$base_worktree" "$base_scratch")/InnoNetworkBenchmarks"
head_bin="$(swift_bin_path "$repo_root" "$head_scratch")/InnoNetworkBenchmarks"
test -x "$base_bin"
test -x "$head_bin"

run_sample() {
  local executable="$1"
  local output="$2"
  "$executable" \
    --quick \
    --json-path "$output" \
    --baseline "$missing_baseline" \
    > "${output%.json}.log"
}

# Balance execution order and thermal drift across revisions.
run_sample "$base_bin" "$output_dir/base-1.json"
run_sample "$head_bin" "$output_dir/head-1.json"
run_sample "$head_bin" "$output_dir/head-2.json"
run_sample "$base_bin" "$output_dir/base-2.json"
run_sample "$base_bin" "$output_dir/base-3.json"
run_sample "$head_bin" "$output_dir/head-3.json"

comparison_arguments=(
  python3 Scripts/compare_benchmark_runs.py
  --base "$output_dir/base-1.json"
  --base "$output_dir/base-2.json"
  --base "$output_dir/base-3.json"
  --head "$output_dir/head-1.json"
  --head "$output_dir/head-2.json"
  --head "$output_dir/head-3.json"
  --output "$output_dir/results.json"
  --max-regression-percent "$max_regression_percent"
)
if [[ -n "$regression_reason" ]]; then
  comparison_arguments+=(--regression-reason "$regression_reason")
fi
python3 Scripts/run_with_guarded_benchmarks.py -- "${comparison_arguments[@]}"

python3 Scripts/render_benchmark_comment.py \
  "$output_dir/results.json" \
  "$output_dir/summary.md"
cat "$output_dir/summary.md"
