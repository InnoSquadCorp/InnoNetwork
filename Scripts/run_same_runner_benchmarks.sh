#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
output_dir="$repo_root/.build/benchmarks"
base_revision=""
uses_reviewed_base_revision=0
archived_source_ref=""
max_regression_percent="20"
regression_reason="${INNO_BENCHMARK_REGRESSION_REASON:-}"
validate_only=0
scope="runtime"

usage() {
  cat <<'USAGE'
Usage: bash Scripts/run_same_runner_benchmarks.sh [options]

Build and interleave three release-mode benchmark sample pairs for a base
revision and the current working tree, then enforce the paired-median guard.

  --base-revision SHA       Override the reviewed source revision (for example,
                            with a possibly divergent pull-request base SHA).
  --output-dir PATH         Artifact directory (default: .build/benchmarks).
  --max-regression-percent  Guard threshold (default: 20).
  --regression-reason TEXT  Record an intentional movement in the comparison.
  --validate-only           Validate revision provenance without building.
  --scope runtime|json      Default: runtime, followed by the dedicated JSON lane.
                            JSON always has its own reviewed source baseline.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      if [[ $# -lt 2 || ( "$2" != "runtime" && "$2" != "json" ) ]]; then
        echo "same-runner-benchmarks: --scope requires runtime or json" >&2
        exit 64
      fi
      scope="$2"
      shift
      ;;
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
  baseline_prefix=""
  if [[ "$scope" == "json" ]]; then baseline_prefix="json-"; fi
  source_revision_path="$repo_root/Benchmarks/Baselines/${baseline_prefix}source-revision.txt"
  if [[ ! -f "$source_revision_path" ]]; then
    echo "same-runner-benchmarks: baseline source revision is missing" >&2
    exit 1
  fi
  base_revision="$(<"$source_revision_path")"
  # A squash-only repository cannot retain an unreleased codec baseline as
  # an ancestor of main. Preserve that exact source on a named origin ref;
  # never silently rebaseline to the newly squashed implementation.
  if [[ "$scope" == "json" && -f "$repo_root/Benchmarks/Baselines/json-source-ref.txt" ]]; then
    archived_source_ref="$(<"$repo_root/Benchmarks/Baselines/json-source-ref.txt")"
    if [[ ! "$archived_source_ref" =~ ^refs/heads/benchmark-baselines/[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
      echo "same-runner-benchmarks: invalid archived source ref" >&2
      exit 1
    fi
  fi
fi

if [[ ! "$base_revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "same-runner-benchmarks: base revision must be a lowercase 40-character SHA" >&2
  exit 1
fi

if [[ ! "$max_regression_percent" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "same-runner-benchmarks: max regression percent must be a non-negative number" >&2
  exit 64
fi

head_revision="$(git -C "$repo_root" rev-parse HEAD)"
uses_verified_archive=0
if ((uses_reviewed_base_revision == 1)) && [[ -n "$archived_source_ref" ]] \
  && ! git -C "$repo_root" merge-base --is-ancestor "$base_revision" "$head_revision" 2>/dev/null; then
  published_ref="$(git -C "$repo_root" ls-remote --exit-code origin "$archived_source_ref")" || {
    echo "same-runner-benchmarks: archived source ref is unavailable on origin" >&2
    exit 1
  }
  if [[ "$published_ref" != "$base_revision"$'\t'"$archived_source_ref" ]]; then
    echo "same-runner-benchmarks: archived source ref does not match the reviewed SHA" >&2
    exit 1
  fi
  if ! git -C "$repo_root" cat-file -e "${base_revision}^{commit}" 2>/dev/null; then
    git -C "$repo_root" fetch --no-tags origin "$archived_source_ref"
    if [[ "$(git -C "$repo_root" rev-parse FETCH_HEAD)" != "$base_revision" ]]; then
      echo "same-runner-benchmarks: archived source ref changed during fetch" >&2
      exit 1
    fi
  fi
  uses_verified_archive=1
fi

if ! git -C "$repo_root" cat-file -e "${base_revision}^{commit}" 2>/dev/null; then
  echo "same-runner-benchmarks: base revision is unavailable: $base_revision" >&2
  exit 1
fi

if [[ "$scope" == "json" ]] && ! git -C "$repo_root" cat-file -e \
  "$base_revision:Sources/InnoNetwork/JSON/PreservedJSON.swift" 2>/dev/null; then
  echo "same-runner-benchmarks: JSON baseline must contain the preserved JSON codec" >&2
  exit 1
fi
if ((uses_reviewed_base_revision == 1 && uses_verified_archive == 0)) \
  && ! git -C "$repo_root" merge-base --is-ancestor "$base_revision" "$head_revision"; then
  echo "same-runner-benchmarks: reviewed base revision is not an ancestor of HEAD" >&2
  exit 1
fi

if ((validate_only == 1)); then
  echo "same-runner-benchmarks: OK (scope $scope, base $base_revision, head $head_revision, archive $uses_verified_archive)"
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
protocol_dir="$output_dir/protocol"
protocol="$repo_root/Scripts/benchmark_protocol.py"
mkdir -p "$protocol_dir"
invocation_id="${INNO_BENCHMARK_INVOCATION_ID:-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')}"
# These destinations belong to this collector. Old output must never receive a
# fresh receipt when a build, guard contract, parser or comparison fails.
rm -f "$output_dir/results.json" "$protocol_dir/comparison.json"

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
swift_flags=()
if [[ "$scope" == "json" ]]; then
  base_scratch+="-json"
  head_scratch+="-json"
  swift_flags=(-Xswiftc -DINNO_BENCHMARK_PRESERVED_JSON)
fi

swift_build() {
  local package_path="$1"
  local scratch_path="$2"
  local side="$3"
  python3 "$protocol" build --directory "$protocol_dir" --side "$side" \
    --cwd "$package_path" -- xcrun swift build -c release \
      --disable-default-traits \
      --product InnoNetworkBenchmarks \
      --scratch-path "$scratch_path" \
      --cache-path "$cache_path" \
      ${swift_flags[@]+"${swift_flags[@]}"}
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

swift_build "$base_worktree" "$base_scratch" base
swift_build "$repo_root" "$head_scratch" head

base_bin="$(swift_bin_path "$base_worktree" "$base_scratch")/InnoNetworkBenchmarks"
head_bin="$(swift_bin_path "$repo_root" "$head_scratch")/InnoNetworkBenchmarks"
test -x "$base_bin"
test -x "$head_bin"

# Record actual build argv, checked Git objects, measured harness, binary hashes
# and host identity outside every Swift timed measurement interval.
python3 "$protocol" manifest --directory "$protocol_dir" --lane "$scope" \
  --base-root "$base_worktree" --base-revision "$base_revision" --base-binary "$base_bin" \
  --head-root "$repo_root" --head-revision "$head_revision" --head-binary "$head_bin"

run_sample() {
  local side="$1"
  local output="$2"
  python3 "$protocol" sample --manifest "$protocol_dir/manifest.json" \
    --side "$side" --output "$output" --missing-baseline "$missing_baseline"
}

# Balance execution order and thermal drift across revisions. The comparison
# keeps these numbered base/head pairs together before taking its median.
run_sample base "$output_dir/base-1.json"
run_sample head "$output_dir/head-1.json"
run_sample head "$output_dir/head-2.json"
run_sample base "$output_dir/base-2.json"
run_sample base "$output_dir/base-3.json"
run_sample head "$output_dir/head-3.json"

comparison_arguments=(
  python3 Scripts/compare_benchmark_runs.py
  --base "$output_dir/base-1.json"
  --base "$output_dir/base-2.json"
  --base "$output_dir/base-3.json"
  --head "$output_dir/head-1.json"
  --head "$output_dir/head-2.json"
  --head "$output_dir/head-3.json"
  --output "$output_dir/results.json"
  --receipt "$protocol_dir/comparison.json"
  --invocation-id "$invocation_id"
  --source-head "$head_revision"
  --max-regression-percent "$max_regression_percent"
)
if [[ -n "$regression_reason" ]]; then
  comparison_arguments+=(--regression-reason "$regression_reason")
fi
# Only exit 1 WITH the comparator's fresh, bound receipt is a valid measured
# regression. The wrapper also uses 1 for invalid guard contracts; verification
# below rejects those before rendering or launching independent controls.
# Invalid data (2), failed builds, timeouts and cancellation stop immediately.
set +e
INNO_BENCHMARK_SCOPE="$scope" python3 Scripts/run_with_guarded_benchmarks.py -- "${comparison_arguments[@]}"
comparison_status=$?
set -e
if ((comparison_status > 1)); then
  exit "$comparison_status"
fi
python3 "$protocol" verify-comparison --directory "$output_dir" \
  --invocation-id "$invocation_id" --source-head "$head_revision" --exit-code "$comparison_status"


python3 Scripts/render_benchmark_comment.py \
  "$output_dir/results.json" \
  "$output_dir/summary.md"
cat "$output_dir/summary.md"

# Keep the historical runtime baseline unchanged. JSON did not exist there,
# so it needs an independent source baseline, not an unguarded head-only row.
if [[ "$scope" == "runtime" ]]; then
  json_arguments=(--scope json --output-dir "$output_dir/json"
    --max-regression-percent "$max_regression_percent")
  if [[ -n "$regression_reason" ]]; then
    json_arguments+=(--regression-reason "$regression_reason")
  fi
  # Remove only this collector-owned receipt: an old artifact cannot make a
  # failed JSON build look like a completed measured comparison.
  rm -f "$output_dir/json/protocol/comparison.json"
  set +e
  INNO_BENCHMARK_INVOCATION_ID="$invocation_id" bash "$repo_root/Scripts/run_same_runner_benchmarks.sh" "${json_arguments[@]}"
  json_status=$?
  set -e
  if ((json_status > 1)); then
    # Execution/data failure is not a reason to keep launching diagnostic work.
    exit "$json_status"
  fi
  if ! python3 "$protocol" verify-comparison --directory "$output_dir/json" \
    --invocation-id "$invocation_id" --source-head "$head_revision" --exit-code "$json_status"
  then
    if ((comparison_status != 0)); then exit "$comparison_status"; fi
    if ((json_status != 0)); then exit "$json_status"; fi
    exit 2
  fi

  # Exactly 24 event-only process observations, each <=45s, <=360s total.
  # These fixed A/A, B/B and both-direction A/B controls never replace the
  # primary comparisons, select another sample, or retry until a pass.
  set +e
  python3 "$protocol" diagnostics --manifest "$protocol_dir/manifest.json" \
    --directory "$protocol_dir/diagnostics" --missing-baseline "$missing_baseline"
  diagnostic_status=$?
  set -e
  python3 - "$protocol_dir/guard-status.json" "$comparison_status" "$json_status" "$diagnostic_status" <<'PY_STATUS'
import json
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "runtime_guard_exit": int(sys.argv[2]), "json_guard_exit": int(sys.argv[3]),
    "diagnostic_exit": int(sys.argv[4]),
    "diagnostics_replace_primary_verdict": False,
}, indent=2) + "\n")
PY_STATUS
  if ((comparison_status != 0)); then exit "$comparison_status"; fi
  if ((json_status != 0)); then exit "$json_status"; fi
  if ((diagnostic_status != 0)); then exit "$diagnostic_status"; fi
fi
exit "$comparison_status"
