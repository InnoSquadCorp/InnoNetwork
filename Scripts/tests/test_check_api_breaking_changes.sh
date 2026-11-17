#!/usr/bin/env bash
# Fixture tests for the documentation half of Scripts/check_api_breaking_changes.sh.
# The comparison half needs a full package build and runs in CI itself.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/Scripts/check_api_breaking_changes.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/ledger"
cat >"$scratch/guide.md" <<'MD'
# Migrating

`NetworkError` gains `policyRejected`. `OperationNetworkClient` is removed.
`WebSocketReconnectPack` gains a parameter.
MD

run_ledger_check() {
  INNO_API_NEXT=9.9.9 \
    INNO_API_LEDGER_DIR="$scratch/ledger" \
    INNO_API_MIGRATION_GUIDE="$scratch/guide.md" \
    bash "$script" --ledger-only
}

expect_pass() {
  local label="$1"
  if ! output="$(run_ledger_check 2>&1)"; then
    echo "FAIL: expected pass for $label" >&2
    echo "$output" >&2
    exit 1
  fi
}

expect_fail() {
  local label="$1" needle="$2"
  if output="$(run_ledger_check 2>&1)"; then
    echo "FAIL: expected failure for $label" >&2
    exit 1
  fi
  if [[ "$output" != *"$needle"* ]]; then
    echo "FAIL: $label did not report '$needle'" >&2
    echo "$output" >&2
    exit 1
  fi
}

: >"$scratch/ledger/9.9.9-package.allowlist"

cat >"$scratch/ledger/9.9.9-public.allowlist" <<'TXT'
# Comments and blank lines are ignored.

API breakage: enumelement NetworkError.policyRejected has been added as a new enum case
API breakage: struct OperationNetworkClient has been removed
API breakage: constructor WebSocketReconnectPack.init(delay:jitterRatio:maxDelay:maxAttempts:maxTotalDuration:) has been removed
TXT
expect_pass "a fully documented public ledger"

cat >"$scratch/ledger/9.9.9-public.allowlist" <<'TXT'
API breakage: enumelement NetworkError.authentication has been added as a new enum case
TXT
expect_fail "an undocumented public entry" "authentication"

cat >"$scratch/ledger/9.9.9-public.allowlist" <<'TXT'
NetworkError.policyRejected was added
TXT
expect_fail "a malformed entry" "exact 'API breakage: ...' diagnostics"

rm "$scratch/ledger/9.9.9-package.allowlist"
cat >"$scratch/ledger/9.9.9-public.allowlist" <<'TXT'
API breakage: struct OperationNetworkClient has been removed
TXT
expect_fail "a missing package ledger" "missing"

echo "check_api_breaking_changes fixtures: OK"
