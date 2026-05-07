#!/usr/bin/env bash
# Enforces the "Stable Examples" contract documented in API_STABILITY.md.
#
# Each stable example directory must exist, contain at least one Swift
# source file, and ship a README.md. The exact wording of the example is
# not contractual — only the layout is — so this gate fires only on
# missing/empty directories or removed READMEs.
#
# Wire this into the docs-contract CI job alongside
# `check_docs_contract_sync.sh`.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

stable_examples=(
    "Examples/BasicRequest"
    "Examples/Auth"
    "Examples/ErrorHandling"
)

failures=()

for example in "${stable_examples[@]}"; do
    full_path="$repo_root/$example"
    if [[ ! -d "$full_path" ]]; then
        failures+=("Stable example directory missing: $example")
        continue
    fi

    if ! find "$full_path" -name '*.swift' -type f -print -quit | grep -q .; then
        failures+=("Stable example contains no Swift sources: $example")
    fi

    if [[ ! -f "$full_path/README.md" ]]; then
        failures+=("Stable example missing README.md: $example")
    fi
done

if (( ${#failures[@]} > 0 )); then
    printf '::error::Stable example contract violation\n'
    for line in "${failures[@]}"; do
        printf '  - %s\n' "$line"
    done
    exit 1
fi

echo "✅ Stable examples contract satisfied."
