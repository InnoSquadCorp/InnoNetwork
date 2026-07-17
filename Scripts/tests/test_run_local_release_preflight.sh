#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$repo_root/Scripts/run_local_release_preflight.sh"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-local-release-preflight-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/expected-fast.txt" <<'EOF'
release-script-fixtures
dependency-lock
static-contracts
documentation-smoke
consumer-examples
openapi-generator
bounded-tests
EOF

cat > "$work_dir/expected-full.txt" <<'EOF'
release-script-fixtures
dependency-lock
static-contracts
documentation-smoke
consumer-examples
openapi-generator
bounded-tests
runtime-coverage
macro-coverage
guarded-benchmarks
sbom-artifacts
all-product-docc
apple-platform-builds
EOF

bash "$runner" --fast --list > "$work_dir/actual-fast.txt"
bash "$runner" --full --list > "$work_dir/actual-full.txt"
diff -u "$work_dir/expected-fast.txt" "$work_dir/actual-fast.txt"
diff -u "$work_dir/expected-full.txt" "$work_dir/actual-full.txt"

bash "$runner" --help | grep -Fq -- '--full'

set +e
bash "$runner" --unknown > "$work_dir/unknown.stdout" 2> "$work_dir/unknown.stderr"
status=$?
set -e

if [[ "$status" -ne 64 ]]; then
  echo "Expected an unknown argument to exit 64; got $status." >&2
  exit 1
fi
grep -Fq 'Unknown argument: --unknown' "$work_dir/unknown.stderr"

echo "Local release preflight contract tests passed."
