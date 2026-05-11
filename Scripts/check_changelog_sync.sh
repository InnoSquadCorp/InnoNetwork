#!/usr/bin/env bash
#
# Cross-checks symbols claimed in CHANGELOG.md's [Unreleased] section
# against the current source tree, so a typo or a removed-after-the-fact
# entry cannot ship as a release note for a symbol that never landed.
#
# The check is intentionally conservative:
#   * Only the first leading code-spanned token on each `- ` bullet under
#     [Unreleased] is considered (e.g., the back-ticked identifier at the
#     start of the line). Prose-style bullets without a leading symbol
#     are skipped.
#   * Identifiers that look like file paths (contain `/`), section labels
#     (e.g., `### Added`), markdown punctuation, or common English words
#     are skipped — we only assert on tokens that read like Swift symbols
#     (`[A-Z][A-Za-z0-9_]*`).
#
# Exits non-zero with the offending identifiers if any are missing.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="${ROOT}/CHANGELOG.md"
SOURCES="${ROOT}/Sources"
TESTS="${ROOT}/Tests"

if [[ ! -f "${CHANGELOG}" ]]; then
    echo "❌ CHANGELOG.md not found at ${CHANGELOG}" >&2
    exit 1
fi

if [[ ! -d "${SOURCES}" ]]; then
    echo "❌ Sources/ directory not found at ${SOURCES}" >&2
    exit 1
fi

UNRELEASED="$(awk '
    /^## \[Unreleased\]/ { flag = 1; next }
    /^## \[/             { flag = 0 }
    # ### Removed bullets describe *deleted* symbols by definition —
    # they intentionally no longer appear in source. Skip until the
    # next ### subsection (or the next ## release header) to avoid
    # false positives.
    flag && /^### Removed/ { skip = 1; next }
    flag && /^### /         { skip = 0 }
    flag && !skip           { print }
' "${CHANGELOG}")"

if [[ -z "${UNRELEASED}" ]]; then
    echo "ℹ️  CHANGELOG.md has no [Unreleased] section content."
    exit 0
fi

# Extract leading back-ticked identifiers from `- ` bullets.
CANDIDATES="$(printf '%s\n' "${UNRELEASED}" \
    | grep -Eo '^- `[A-Z][A-Za-z0-9_]+`' \
    | sed -E 's/^- `([A-Z][A-Za-z0-9_]+)`/\1/' \
    | sort -u)"

if [[ -z "${CANDIDATES}" ]]; then
    echo "ℹ️  CHANGELOG [Unreleased] has no leading symbol bullets to verify."
    exit 0
fi

MISSING=()
while IFS= read -r symbol; do
    [[ -z "${symbol}" ]] && continue
    if grep -RIlq --include='*.swift' "\\b${symbol}\\b" "${SOURCES}" "${TESTS}" 2>/dev/null; then
        continue
    fi
    MISSING+=("${symbol}")
done <<< "${CANDIDATES}"

if (( ${#MISSING[@]} == 0 )); then
    echo "✅ CHANGELOG [Unreleased] symbols all resolve in source."
    exit 0
fi

echo "❌ CHANGELOG [Unreleased] mentions symbols not found in Sources/ or Tests/:" >&2
for symbol in "${MISSING[@]}"; do
    echo "   - ${symbol}" >&2
done
echo >&2
echo "   Either drop the bullet from CHANGELOG.md or add the symbol to source." >&2
exit 1
