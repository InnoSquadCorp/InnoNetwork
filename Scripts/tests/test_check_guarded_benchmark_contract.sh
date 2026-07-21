#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/Scripts/check_guarded_benchmark_contract.sh"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-guarded-benchmark-contract-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

fixture_files=(
  "Benchmarks/Baselines/default.json"
  "Benchmarks/Baselines/source-revision.txt"
  "Benchmarks/guarded-benchmarks.txt"
  "Scripts/guarded_benchmarks.py"
  "Scripts/run_same_runner_benchmarks.sh"
  ".github/workflows/benchmarks.yml"
  ".github/workflows/release.yml"
  "Scripts/run_local_release_preflight.sh"
  "docs/CI_DoC.md"
  "Benchmarks/README.md"
  "CHANGELOG.md"
  "docs/RELEASE_POLICY.md"
  "docs/releases/5.0.0.md"
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
invocation = "bash Scripts/run_same_runner_benchmarks.sh"
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
grep -Fq '.github/workflows/release.yml must invoke the same-runner benchmark entry point' \
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

wrong_threshold_root="$work_dir/wrong-threshold"
make_fixture "$wrong_threshold_root"
python3 - "$wrong_threshold_root/Scripts/run_local_release_preflight.sh" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
source = source.replace("--max-regression-percent 20", "--max-regression-percent 10")
path.write_text(source, encoding="utf-8")
PY
if run_checker "$wrong_threshold_root" \
  > "$work_dir/wrong-threshold.stdout" \
  2> "$work_dir/wrong-threshold.stderr"; then
  echo "Expected a stale guarded benchmark threshold to fail." >&2
  exit 1
fi
grep -Fq 'must keep the guarded benchmark threshold at 20%' \
  "$work_dir/wrong-threshold.stderr"

stale_docs_root="$work_dir/stale-docs"
make_fixture "$stale_docs_root"
python3 - "$stale_docs_root/docs/RELEASE_POLICY.md" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
source = source.replace("same guard list and 20% threshold", "same guard list and 10% threshold")
path.write_text(source, encoding="utf-8")
PY
if run_checker "$stale_docs_root" \
  > "$work_dir/stale-docs.stdout" \
  2> "$work_dir/stale-docs.stderr"; then
  echo "Expected stale guarded benchmark documentation to fail." >&2
  exit 1
fi
grep -Fq 'must document the guarded benchmark threshold as 20%' \
  "$work_dir/stale-docs.stderr"

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

invalid_source_revision_root="$work_dir/invalid-source-revision"
make_fixture "$invalid_source_revision_root"
printf '%s\n' 'not-a-commit' \
  > "$invalid_source_revision_root/Benchmarks/Baselines/source-revision.txt"
if run_checker "$invalid_source_revision_root" \
  > "$work_dir/invalid-source-revision.stdout" \
  2> "$work_dir/invalid-source-revision.stderr"; then
  echo "Expected an invalid baseline source revision to fail." >&2
  exit 1
fi
grep -Fq 'baseline source revision must be one lowercase 40-character SHA' \
  "$work_dir/invalid-source-revision.stderr"

echo "Guarded benchmark contract tests passed."
