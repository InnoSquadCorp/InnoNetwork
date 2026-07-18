#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
symbols_dir="$repo_root/Scripts/symbols"
budget_file="$symbols_dir/budgets.tsv"

fail() {
  echo "public-api-budget: $*" >&2
  exit 1
}

[[ -f "$budget_file" ]] || fail "missing $budget_file"

total=0
for allowlist_path in "$symbols_dir"/*.allowlist; do
  allowlist=$(basename "$allowlist_path")
  budget=$(awk -F '\t' -v name="$allowlist" '$1 == name { print $2 }' "$budget_file")
  [[ -n "$budget" ]] || fail "missing budget for $allowlist"

  actual=$(awk 'NF && $1 !~ /^#/ { count += 1 } END { print count + 0 }' "$allowlist_path")
  if ((actual > budget)); then
    fail "$allowlist exports $actual declarations (budget: $budget)"
  fi
  total=$((total + actual))
done

total_budget=$(awk -F '\t' '$1 == "TOTAL" { print $2 }' "$budget_file")
[[ -n "$total_budget" ]] || fail "missing TOTAL budget"
if ((total > total_budget)); then
  fail "all products export $total declarations (budget: $total_budget)"
fi

echo "public-api-budget: OK ($total/$total_budget)"
python3 "$repo_root/Scripts/check_public_api_tiers.py" "$repo_root"
