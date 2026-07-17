#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/Scripts/check_guarded_benchmark_contract.sh"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-guarded-benchmark-contract-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

fixture_files=(
  "Benchmarks/Baselines/default.json"
  "Benchmarks/guarded-benchmarks.txt"
  "Scripts/guarded_benchmarks.py"
  ".github/workflows/benchmarks.yml"
  ".github/workflows/release.yml"
  "Scripts/run_local_release_preflight.sh"
  "docs/CI_DoC.md"
)

make_fixture() {
  local fixture_root="$1"
  local relative_path
  for relative_path in "${fixture_files[@]}"; do
    mkdir -p "$fixture_root/$(dirname "$relative_path")"
    cp "$repo_root/$relative_path" "$fixture_root/$relative_path"
  done
}

run_checker() {
  local fixture_root="$1"
  INNO_GUARDED_BENCHMARK_CONTRACT_ROOT="$fixture_root" bash "$checker"
}

success_root="$work_dir/success"
make_fixture "$success_root"
run_checker "$success_root" >/dev/null

missing_declaration_root="$work_dir/missing-declaration"
make_fixture "$missing_declaration_root"
python3 - "$missing_declaration_root/.github/workflows/release.yml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
invocation = "python3 Scripts/run_with_guarded_benchmarks.py --"
for index, line in enumerate(lines):
    if invocation in line:
        del lines[index]
        break
else:
    raise SystemExit(f"fixture runner invocation not found: {invocation}")
path.write_text("".join(lines), encoding="utf-8")
PY
if run_checker "$missing_declaration_root" \
  > "$work_dir/missing-declaration.stdout" \
  2> "$work_dir/missing-declaration.stderr"; then
  echo "Expected a missing workflow declaration to fail." >&2
  exit 1
fi
grep -Fq '.github/workflows/release.yml must invoke the guarded benchmark runner' \
  "$work_dir/missing-declaration.stderr"

direct_declaration_root="$work_dir/direct-declaration"
make_fixture "$direct_declaration_root"
printf '\n# --guard-benchmark events/task-event-fanout-single\n' \
  >> "$direct_declaration_root/.github/workflows/release.yml"
if run_checker "$direct_declaration_root" \
  > "$work_dir/direct-declaration.stdout" \
  2> "$work_dir/direct-declaration.stderr"; then
  echo "Expected a direct guarded benchmark declaration to fail." >&2
  exit 1
fi
grep -Fq 'bypasses the guarded benchmark runner' \
  "$work_dir/direct-declaration.stderr"

missing_baseline_root="$work_dir/missing-baseline"
make_fixture "$missing_baseline_root"
python3 - "$missing_baseline_root/Benchmarks/Baselines/default.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["results"] = [
    result
    for result in payload["results"]
    if (result["group"], result["name"])
    != ("events", "task-event-fanout-single")
]
path.write_text(json.dumps(payload), encoding="utf-8")
PY
if run_checker "$missing_baseline_root" \
  > "$work_dir/missing-baseline.stdout" \
  2> "$work_dir/missing-baseline.stderr"; then
  echo "Expected a missing baseline entry to fail." >&2
  exit 1
fi
grep -Fq 'guard identifier(s) missing from the default baseline' \
  "$work_dir/missing-baseline.stderr"

duplicate_root="$work_dir/duplicate"
make_fixture "$duplicate_root"
printf '%s\n' 'events/task-event-fanout-single' \
  >> "$duplicate_root/Benchmarks/guarded-benchmarks.txt"
if run_checker "$duplicate_root" \
  > "$work_dir/duplicate.stdout" \
  2> "$work_dir/duplicate.stderr"; then
  echo "Expected a duplicate guard identifier to fail." >&2
  exit 1
fi
grep -Fq 'duplicate guard identifier(s)' "$work_dir/duplicate.stderr"

echo "Guarded benchmark contract tests passed."
