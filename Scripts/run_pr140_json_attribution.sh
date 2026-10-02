#!/usr/bin/env bash
# One fixed attribution experiment, not a replacement for the archived JSON gate.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base=e74f322dc46b660e02c22fb601d8e5e79b0c02a8
candidate=955841b398b96b1bf012c9c06c815e10d345109d
orchestration="$(git -C "$repo_root" rev-parse HEAD)"
if [[ -n "${GITHUB_SHA:-}" ]]; then
  test "$orchestration" = "$GITHUB_SHA"
fi
test "$(git -C "$repo_root" rev-parse "$base^{commit}")" = "$base"
test "$(git -C "$repo_root" rev-parse "$candidate^{commit}")" = "$candidate"
git -C "$repo_root" merge-base --is-ancestor "$base" "$candidate"

# This candidate changes dependencies, not the measured source or methodology.
# Refuse to silently substitute a later implementation or benchmark harness.
for path in Sources Benchmarks Scripts/run_same_runner_benchmarks.sh \
  Scripts/benchmark_protocol.py Scripts/compare_benchmark_runs.py \
  Scripts/run_with_guarded_benchmarks.py Scripts/guarded_benchmarks.py; do
  test "$(git -C "$repo_root" rev-parse "$base:$path")" = \
    "$(git -C "$repo_root" rev-parse "$candidate:$path")"
done

output_dir="$repo_root/.build/pr140-json-attribution"
mkdir -p "$output_dir"
printf '%s\n' \
  'Report-only PR140 JSON attribution; this is not a required CI gate.' \
  "Orchestration commit: $orchestration" \
  "Measured base: $base" "Measured candidate: $candidate" \
  'Exactly one existing-script comparison: three AB/BA/AB pairs, threshold 20%.' \
  'The archived b358692e1e583b5cef1c97bb65208729b313f574 gate is unchanged.' \
  'Original failure: https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36992525790/job/110791851913' \
  'A diagnostic pass does not erase the original -21.98% JSON guard failure.' \
  > "$output_dir/diagnostic-scope.txt"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$output_dir/diagnostic-scope.txt" >> "$GITHUB_STEP_SUMMARY"
fi

worktree_parent="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/innonetwork-pr140-json.XXXXXX")"
candidate_root="$worktree_parent/candidate"
cleanup() {
  git -C "$repo_root" worktree remove --force "$candidate_root" >/dev/null 2>&1 || true
  rmdir "$worktree_parent" 2>/dev/null || true
}
trap cleanup EXIT
git -C "$repo_root" worktree add --detach "$candidate_root" "$candidate"

# Use the original candidate's unchanged collector, not the orchestration commit.
# Its validated comparison receipt distinguishes a regression from execution errors.
# Preserve its exit code; do not retry, override a verdict, or append trend data.
bash "$candidate_root/Scripts/run_same_runner_benchmarks.sh" \
  --scope json --base-revision "$base" --output-dir "$output_dir" \
  --max-regression-percent 20
