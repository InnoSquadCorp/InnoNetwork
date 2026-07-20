#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$repo_root/Scripts/run_same_runner_benchmarks.sh"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-same-runner-benchmark-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

bash "$runner" --help | grep -Fq -- '--base-revision'
bash "$runner" --help | grep -Fq -- '--regression-reason'
bash "$runner" --validate-only \
  > "$work_dir/validate.stdout"
grep -Fq 'same-runner-benchmarks: OK' "$work_dir/validate.stdout"
bash "$runner" --regression-reason 'expected movement' --validate-only \
  > "$work_dir/reason.stdout"
grep -Fq 'same-runner-benchmarks: OK' "$work_dir/reason.stdout"

set +e
bash "$runner" --unknown \
  > "$work_dir/unknown.stdout" \
  2> "$work_dir/unknown.stderr"
status=$?
set -e
if [[ "$status" -ne 64 ]]; then
  echo "Expected an unknown argument to exit 64; got $status." >&2
  exit 1
fi
grep -Fq 'unknown argument: --unknown' "$work_dir/unknown.stderr"

set +e
bash "$runner" --output-dir \
  > "$work_dir/missing-value.stdout" \
  2> "$work_dir/missing-value.stderr"
status=$?
set -e
if [[ "$status" -ne 64 ]]; then
  echo "Expected a missing option value to exit 64; got $status." >&2
  exit 1
fi
grep -Fq -- '--output-dir requires a value' "$work_dir/missing-value.stderr"

set +e
bash "$runner" --max-regression-percent nope --validate-only \
  > "$work_dir/invalid-percent.stdout" \
  2> "$work_dir/invalid-percent.stderr"
status=$?
set -e
if [[ "$status" -ne 64 ]]; then
  echo "Expected an invalid regression percentage to exit 64; got $status." >&2
  exit 1
fi
grep -Fq 'max regression percent must be a non-negative number' \
  "$work_dir/invalid-percent.stderr"

set +e
bash "$runner" --base-revision not-a-sha --validate-only \
  > "$work_dir/invalid.stdout" \
  2> "$work_dir/invalid.stderr"
status=$?
set -e
if [[ "$status" -ne 1 ]]; then
  echo "Expected an invalid SHA to exit 1; got $status." >&2
  exit 1
fi
grep -Fq 'base revision must be a lowercase 40-character SHA' \
  "$work_dir/invalid.stderr"

set +e
bash "$runner" \
  --base-revision 0000000000000000000000000000000000000000 \
  --validate-only \
  > "$work_dir/missing.stdout" \
  2> "$work_dir/missing.stderr"
status=$?
set -e
if [[ "$status" -ne 1 ]]; then
  echo "Expected an unavailable SHA to exit 1; got $status." >&2
  exit 1
fi
grep -Fq 'base revision is unavailable' "$work_dir/missing.stderr"

echo "Same-runner benchmark contract tests passed."
