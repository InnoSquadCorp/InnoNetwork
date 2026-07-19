#!/usr/bin/env bash
# Unit tests for Scripts/_docs_contract_helpers.sh.
#
# Runs every assertion primitive against both engines (rg when installed,
# and the grep fallback via a PATH that hides rg) so the fallback branch
# CI never exercises stays correct.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helpers="$repo_root/Scripts/_docs_contract_helpers.sh"
failures=0

run_case() {
  local description="$1"
  local expected_status="$2"
  local hide_rg="$3"
  shift 3
  local fixture_dir
  fixture_dir="$(mktemp -d)"
  printf 'alpha line\nsecond line with token inside\n' > "$fixture_dir/doc.md"

  local status=0
  (
    if [ "$hide_rg" = "hide-rg" ]; then
      # Constrain PATH so has_rg() takes the grep fallback branch.
      bare_bin="$(mktemp -d)"
      for tool in bash grep mktemp printf rm dirname cd pwd command; do
        path="$(command -v "$tool" || true)"
        [ -n "$path" ] && ln -s "$path" "$bare_bin/$tool" 2> /dev/null || true
      done
      export PATH="$bare_bin"
    fi
    # shellcheck source=../_docs_contract_helpers.sh
    source "$helpers"
    "$@"
  ) > /dev/null 2>&1 || status=$?

  rm -rf "$fixture_dir"
  if [ "$status" -eq "$expected_status" ] || { [ "$expected_status" -ne 0 ] && [ "$status" -ne 0 ]; }; then
    echo "ok - $description"
  else
    echo "FAIL - $description (expected status $expected_status, got $status)" >&2
    failures=$((failures + 1))
  fi
}

fixture="$(mktemp -d)"
printf 'alpha line\nsecond line with token inside\nlegacy_marker here\n' > "$fixture/doc.md"

for engine in default hide-rg; do
  run_case "require_line matches an exact line ($engine)" 0 "$engine" \
    require_line "alpha line" "$fixture/doc.md"
  run_case "require_line rejects a partial line ($engine)" 1 "$engine" \
    require_line "alpha" "$fixture/doc.md"
  run_case "require_contains matches a substring ($engine)" 0 "$engine" \
    require_contains "token" "$fixture/doc.md"
  run_case "require_contains rejects a missing needle ($engine)" 1 "$engine" \
    require_contains "absent-needle" "$fixture/doc.md"
  run_case "require_not_contains passes on absence ($engine)" 0 "$engine" \
    require_not_contains "absent-needle" "$fixture/doc.md"
  run_case "require_not_contains fails on presence ($engine)" 1 "$engine" \
    require_not_contains "token" "$fixture/doc.md"
  run_case "forbidden_pattern passes when clean ($engine)" 0 "$engine" \
    forbidden_pattern "never_present_[0-9]+" "$fixture/doc.md"
  run_case "forbidden_pattern fails on a match ($engine)" 1 "$engine" \
    forbidden_pattern "legacy_marker" "$fixture/doc.md"
done

rm -rf "$fixture"

if [ "$failures" -gt 0 ]; then
  echo "docs-contract-helpers: $failures test(s) failed" >&2
  exit 1
fi
echo "docs-contract-helpers: OK"
