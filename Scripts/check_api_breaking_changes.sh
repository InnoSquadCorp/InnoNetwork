#!/usr/bin/env bash
# Guards the public API against breaking changes that are not part of the
# next release's breakage ledger.
#
# The comparison runs `swift package diagnose-api-breaking-changes` against the
# last published release tag. A breaking change is accepted only when its
# exact diagnostic (the text after the "💔 " marker) is listed in one of the
# ledger files:
#
#   Scripts/api-breaks/<next>-public.allowlist
#       Consumer-visible changes. Every declaration named here must also be
#       named in docs/Migration-<next>.md, so a break cannot ship without a
#       migration note.
#   Scripts/api-breaks/<next>-package.allowlist
#       `package`-scoped declarations. They appear in the comparison but
#       consumers cannot use them, so they need no migration note.
#
# Lines starting with `#` and blank lines are ignored in both files.
#
# Usage:
#   bash Scripts/check_api_breaking_changes.sh
#       Check that the public ledger is documented, then run the comparison.
#   bash Scripts/check_api_breaking_changes.sh --ledger-only
#       Only check that the public ledger is documented (no build).
#
# Environment:
#   INNO_API_BASELINE        Release tag to compare against (default below).
#   INNO_API_NEXT            Version whose ledger and migration guide apply.
#   INNO_API_LEDGER_DIR      Directory holding the ledger files.
#   INNO_API_MIGRATION_GUIDE Migration guide that must name public entries.
#
# When a release is published, move the defaults forward: the new tag becomes
# the baseline and the next version starts with empty ledgers.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline="${INNO_API_BASELINE:-6.1.1}"
next_version="${INNO_API_NEXT:-7.0.0}"
ledger_dir="${INNO_API_LEDGER_DIR:-$repo_root/Scripts/api-breaks}"
public_ledger="$ledger_dir/$next_version-public.allowlist"
package_ledger="$ledger_dir/$next_version-package.allowlist"
migration_guide="${INNO_API_MIGRATION_GUIDE:-$repo_root/docs/Migration-$next_version.md}"

ledger_only=0
case "${1:-}" in
  "") ;;
  --ledger-only) ledger_only=1 ;;
  *)
    echo "Usage: $0 [--ledger-only]" >&2
    exit 64
    ;;
esac

for file in "$public_ledger" "$package_ledger" "$migration_guide"; do
  if [[ ! -f "$file" ]]; then
    echo "::error::api-breakage: missing $file" >&2
    exit 1
  fi
done

python3 - "$public_ledger" "$migration_guide" <<'PY'
import re
import sys
from pathlib import Path

ledger_path, guide_path = (Path(arg) for arg in sys.argv[1:3])
guide = guide_path.read_text()
guide_words = set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", guide))

# "API breakage: <kind> <Declaration> has ..." — the declaration is the
# dotted name before any parameter list or space.
entry_pattern = re.compile(r"^API breakage: [A-Za-z]+ ([A-Za-z_][A-Za-z0-9_.]*)")

missing = []
malformed = []
for number, raw in enumerate(ledger_path.read_text().splitlines(), start=1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    match = entry_pattern.match(line)
    if not match:
        malformed.append(f"{ledger_path.name}:{number}: {line}")
        continue
    components = [part for part in match.group(1).split(".") if part and part != "init"]
    absent = [part for part in components if part not in guide_words]
    if absent:
        missing.append(f"{ledger_path.name}:{number}: {', '.join(absent)}  ({line})")

if malformed:
    print("::error::api-breakage: ledger entries must be exact 'API breakage: ...' diagnostics", file=sys.stderr)
    for item in malformed:
        print(f"  - {item}", file=sys.stderr)
if missing:
    print(f"::error::api-breakage: public ledger entries not named in {guide_path.name}", file=sys.stderr)
    for item in missing:
        print(f"  - {item}", file=sys.stderr)
if malformed or missing:
    sys.exit(1)
print(f"api-breakage-ledger: OK (every public entry is named in {guide_path.name})")
PY

if [[ $ledger_only -eq 1 ]]; then
  exit 0
fi

if ! git -C "$repo_root" rev-parse --verify --quiet "refs/tags/$baseline^{commit}" >/dev/null; then
  echo "::error::api-breakage: baseline tag $baseline is not available; fetch tags (git fetch --tags) first" >&2
  exit 1
fi

combined_ledger="$(mktemp)"
report="$(mktemp)"
trap 'rm -f "$combined_ledger" "$report"' EXIT
grep -hv -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$public_ledger" "$package_ledger" >"$combined_ledger" || true

set +e
xcrun swift package --package-path "$repo_root" diagnose-api-breaking-changes "$baseline" \
  --breakage-allowlist-path "$combined_ledger" >"$report" 2>&1
status=$?
set -e

# Only the comparison summary matters; the baseline build's own warnings are noise.
grep -E "breaking change|API breakage" "$report" || true
if [[ $status -ne 0 ]]; then
  echo "::error::api-breakage: breaking changes against $baseline are missing from the $next_version ledger (exit $status)" >&2
  echo "Add each exact 'API breakage: ...' line above to $public_ledger (and name it in the migration guide)" >&2
  echo "or, for package-scoped declarations, to $package_ledger." >&2
  tail -n 40 "$report" >&2
  exit 1
fi
echo "api-breakage: OK (every breaking change against $baseline is in the $next_version ledger)"
