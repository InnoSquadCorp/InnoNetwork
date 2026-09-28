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
bash "$runner" --scope json --validate-only > "$work_dir/json.stdout"
grep -Fq 'scope json' "$work_dir/json.stdout"
if bash "$runner" --scope invalid --validate-only > "$work_dir/bad-scope.stdout" 2>&1; then
  echo "Expected an invalid scope to fail." >&2
  exit 1
fi
runtime_base="$(<"$repo_root/Benchmarks/Baselines/source-revision.txt")"
if bash "$runner" --scope json --base-revision "$runtime_base" --validate-only \
  > "$work_dir/pre-json.stdout" 2>&1; then
  echo "Expected the pre-JSON source baseline to fail for JSON." >&2
  exit 1
fi
grep -Fq 'must contain the preserved JSON codec' "$work_dir/pre-json.stdout"

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

# Squash-only history must retain the exact reviewed codec source, not reset
# its performance baseline to the squash result. Use only local Git fixtures.
fixture="$work_dir/archive-fixture"
archive_origin="$work_dir/archive-origin.git"
archive_ref=refs/heads/benchmark-baselines/json-6.0
mkdir -p "$fixture/Sources/InnoNetwork/JSON" "$fixture/Scripts" "$fixture/Benchmarks/Baselines"
git -C "$fixture" init -q --initial-branch original
git -C "$fixture" config user.name 'Benchmark Fixture'
git -C "$fixture" config user.email 'fixture@example.invalid'
printf '// preserved JSON fixture\n' > "$fixture/Sources/InnoNetwork/JSON/PreservedJSON.swift"
git -C "$fixture" add Sources/InnoNetwork/JSON/PreservedJSON.swift
git -C "$fixture" commit -qm 'Original codec source'
archived_sha="$(git -C "$fixture" rev-parse HEAD)"
git -C "$fixture" branch benchmark-baselines/json-6.0
git -C "$fixture" checkout -q --orphan main
git -C "$fixture" commit -qm 'Squashed candidate'
squashed_sha="$(git -C "$fixture" rev-parse HEAD)"
git clone -q --bare "$fixture" "$archive_origin"
git -C "$fixture" remote add origin "$archive_origin"
cp "$runner" "$fixture/Scripts/run_same_runner_benchmarks.sh"
printf '%s\n' "$archived_sha" > "$fixture/Benchmarks/Baselines/json-source-revision.txt"
printf '%s\n' "$archive_ref" > "$fixture/Benchmarks/Baselines/json-source-ref.txt"
bash "$fixture/Scripts/run_same_runner_benchmarks.sh" --scope json --validate-only \
  > "$work_dir/archive.stdout"
grep -Fq 'archive 1' "$work_dir/archive.stdout"

# A single-branch clean clone lacks the orphaned baseline object. The verified
# named ref is sufficient to fetch it without fetching arbitrary SHA inputs.
fresh="$work_dir/fresh-main"
git clone -q --single-branch --branch main "file://$archive_origin" "$fresh"
if git -C "$fresh" cat-file -e "$archived_sha^{commit}" 2>/dev/null; then
  echo 'Expected a fresh main-only clone to lack the archived source.' >&2
  exit 1
fi
mkdir -p "$fresh/Scripts" "$fresh/Benchmarks/Baselines"
cp "$runner" "$fresh/Scripts/run_same_runner_benchmarks.sh"
cp "$fixture/Benchmarks/Baselines/"*.txt "$fresh/Benchmarks/Baselines/"
bash "$fresh/Scripts/run_same_runner_benchmarks.sh" --scope json --validate-only \
  > "$work_dir/fresh.stdout"
grep -Fq 'archive 1' "$work_dir/fresh.stdout"
git -C "$fresh" cat-file -e "$archived_sha^{commit}"

git --git-dir="$archive_origin" update-ref "$archive_ref" "$squashed_sha"
if bash "$fixture/Scripts/run_same_runner_benchmarks.sh" --scope json --validate-only \
  > "$work_dir/drift.stdout" 2>&1; then
  echo 'Expected an archive ref moved away from the reviewed SHA to fail.' >&2
  exit 1
fi
grep -Fq 'does not match the reviewed SHA' "$work_dir/drift.stdout"
git --git-dir="$archive_origin" update-ref -d "$archive_ref"
if bash "$fixture/Scripts/run_same_runner_benchmarks.sh" --scope json --validate-only \
  > "$work_dir/missing-ref.stdout" 2>&1; then
  echo 'Expected a missing archive ref to fail even with a local object.' >&2
  exit 1
fi
grep -Fq 'archived source ref is unavailable' "$work_dir/missing-ref.stdout"
printf 'refs/heads/*\n' > "$fixture/Benchmarks/Baselines/json-source-ref.txt"
if bash "$fixture/Scripts/run_same_runner_benchmarks.sh" --scope json --validate-only \
  > "$work_dir/invalid-ref.stdout" 2>&1; then
  echo 'Expected a wildcard archive ref to fail.' >&2
  exit 1
fi
grep -Fq 'invalid archived source ref' "$work_dir/invalid-ref.stdout"

echo "Same-runner benchmark contract tests passed."
