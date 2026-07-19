#!/usr/bin/env bash
# Shared assertion primitives for the docs-contract gate.
#
# Sourced by Scripts/check_docs_contract_sync.sh and unit-tested by
# Scripts/tests/test_docs_contract_helpers.sh so the primitives every
# validator builds on have their semantics pinned (rg and grep fallback
# included). The sourcing script must define `fail <message>`; the default
# below exits non-zero for standalone use.

if ! declare -f fail > /dev/null; then
  fail() {
    echo "docs-contract-sync: $1" >&2
    exit 1
  }
fi

has_rg() {
  command -v rg > /dev/null 2>&1
}

require_line() {
  local needle="$1"
  local file="$2"
  if has_rg; then
    rg -Fqx -- "$needle" "$file" > /dev/null || fail "missing line '$needle' in $file"
  else
    grep -Fqx -- "$needle" "$file" > /dev/null || fail "missing line '$needle' in $file"
  fi
}

require_contains() {
  local needle="$1"
  local file="$2"
  if has_rg; then
    rg -Fq -- "$needle" "$file" || fail "missing '$needle' in $file"
  else
    grep -Fq -- "$needle" "$file" || fail "missing '$needle' in $file"
  fi
}

require_not_contains() {
  local needle="$1"
  local file="$2"
  if has_rg; then
    if rg -Fq -- "$needle" "$file"; then
      fail "unexpected '$needle' in $file"
    fi
  else
    if grep -Fq -- "$needle" "$file"; then
      fail "unexpected '$needle' in $file"
    fi
  fi
}

forbidden_pattern() {
  local pattern="$1"
  shift
  if has_rg; then
    if rg -n "$pattern" "$@" > /dev/null; then
      rg -n "$pattern" "$@" >&2
      fail "forbidden legacy documentation pattern matched: $pattern"
    fi
    return
  fi

  if grep -En "$pattern" "$@" > /dev/null; then
    grep -En "$pattern" "$@" >&2
    fail "forbidden legacy documentation pattern matched: $pattern"
  fi
}
