#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_state=""
git_ref=""
print_state=0

fail() {
  printf 'docs-release-state: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: validate_docs_release_state.sh [--expect draft|ready] [--ref <commit-ish>] [--print-state]

Validates that the 5.0 release-note marker and the repository's public release
claims describe one coherent state. With --ref, files are read from that Git
tree instead of the working tree.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --expect)
      (( $# >= 2 )) || fail "--expect requires draft or ready."
      expected_state="$2"
      shift 2
      ;;
    --ref)
      (( $# >= 2 )) || fail "--ref requires a commit-ish."
      git_ref="$2"
      shift 2
      ;;
    --print-state)
      print_state=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument '$1'."
      ;;
  esac
done

case "$expected_state" in
  ""|draft|ready)
    ;;
  *)
    fail "--expect must be draft or ready, got '$expected_state'."
    ;;
esac

required_paths=(
  API_STABILITY.md
  README.md
  CHANGELOG.md
  SECURITY.md
  Scripts/symbols/README.md
  docs/Migration-5.0.0.md
  docs/releases/5.0.0.md
)

validation_root="$repo_root"
temporary_root=""

cleanup() {
  if [[ -n "$temporary_root" ]]; then
    rm -rf "$temporary_root"
  fi
}
trap cleanup EXIT

if [[ -n "$git_ref" ]]; then
  resolved_ref="$(git -C "$repo_root" rev-parse --verify "${git_ref}^{commit}" 2>/dev/null || true)"
  [[ -n "$resolved_ref" ]] || fail "ref '$git_ref' does not resolve to a commit."

  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-release-state.XXXXXX")"
  validation_root="$temporary_root"
  for path in "${required_paths[@]}"; do
    object_type="$(git -C "$repo_root" cat-file -t "${resolved_ref}:${path}" 2>/dev/null || true)"
    [[ "$object_type" == "blob" ]] \
      || fail "'$path' must be a file in ref '$git_ref' (found '${object_type:-nothing}')."
    mkdir -p "$(dirname "$validation_root/$path")"
    git -C "$repo_root" cat-file blob "${resolved_ref}:${path}" > "$validation_root/$path"
  done
else
  for path in "${required_paths[@]}"; do
    [[ -f "$validation_root/$path" ]] || fail "required release-state document is missing: $path"
  done
fi

api_stability="$validation_root/API_STABILITY.md"
readme="$validation_root/README.md"
changelog="$validation_root/CHANGELOG.md"
security_policy="$validation_root/SECURITY.md"
symbols_readme="$validation_root/Scripts/symbols/README.md"
migration="$validation_root/docs/Migration-5.0.0.md"
release_notes="$validation_root/docs/releases/5.0.0.md"

require_line() {
  local needle="$1"
  local file="$2"
  LC_ALL=C grep -Fqx "$needle" "$file" \
    || fail "missing exact line '$needle' in ${file#"$validation_root/"}."
}

require_contains() {
  local needle="$1"
  local file="$2"
  LC_ALL=C grep -Fq "$needle" "$file" \
    || fail "missing '$needle' in ${file#"$validation_root/"}."
}

require_not_contains() {
  local needle="$1"
  local file="$2"
  if LC_ALL=C grep -Fq "$needle" "$file"; then
    fail "unexpected '$needle' in ${file#"$validation_root/"}."
  fi
}

status_marker_count="$(LC_ALL=C awk '
  /<!--[[:space:]]*release-status[[:space:]]*:/ { count += 1 }
  END { print count + 0 }
' "$release_notes")"
[[ "$status_marker_count" == "1" ]] \
  || fail "docs/releases/5.0.0.md must contain exactly one release-status marker (found $status_marker_count)."

first_line="$(LC_ALL=C sed -n '1p' "$release_notes")"
case "$first_line" in
  '<!-- release-status: draft -->')
    release_state="draft"
    ;;
  '<!-- release-status: ready -->')
    release_state="ready"
    ;;
  *)
    fail "docs/releases/5.0.0.md must begin with the exact draft or ready release-status marker."
    ;;
esac

if [[ -n "$expected_state" && "$release_state" != "$expected_state" ]]; then
  fail "expected '$expected_state' release state, found '$release_state'."
fi

require_line "# InnoNetwork 5.0.0 Release Notes" "$release_notes"
require_line "# Migration Guide: 5.0.0" "$migration"

case "$release_state" in
  draft)
    require_line "Status: Draft (unreleased)" "$release_notes"
    require_line "Release date: TBD" "$release_notes"
    require_contains 'This draft is not a' "$release_notes"
    require_contains 'must not be used to create a `5.0.0` tag.' "$release_notes"

    require_line "# API Stability (5.0 Draft)" "$api_stability"
    require_contains 'No `5.0.0` tag exists yet: `4.0.0` remains the' "$api_stability"
    require_contains '.upToNextMajor(from: "4.0.0")' "$api_stability"

    require_contains '`4.0.0` is the latest tagged stable release' "$readme"
    require_contains 'no `5.0.0` tag exists yet' "$readme"
    require_contains 'Draft 5.0 Release Notes: [docs/releases/5.0.0.md](docs/releases/5.0.0.md)' "$readme"

    require_line "## [Unreleased]" "$changelog"
    require_contains 'These changes have not been tagged' "$changelog"
    require_not_contains '## [5.0.0] -' "$changelog"

    require_contains '`4.x` is the actively supported tagged public release line.' "$security_policy"
    require_contains 'unreleased 5.0 preview on `main`' "$security_policy"
    require_contains 'unreleased 5.0 preview snapshot' "$symbols_readme"
    require_contains 'This guide describes the unreleased 5.0 draft.' "$migration"
    require_contains 'There is no `5.0.0` tag yet.' "$migration"
    ;;
  ready)
    require_line "Status: Ready for release" "$release_notes"
    release_date="$(LC_ALL=C sed -n 's/^Release date: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' "$release_notes")"
    [[ -n "$release_date" ]] \
      || fail "ready release notes require one 'Release date: YYYY-MM-DD' line."
    [[ "$(printf '%s\n' "$release_date" | LC_ALL=C awk 'NF { count += 1 } END { print count + 0 }')" == "1" ]] \
      || fail "ready release notes require exactly one release date."
    require_not_contains "Release date: TBD" "$release_notes"
    require_not_contains "Status: Draft (unreleased)" "$release_notes"
    require_not_contains 'This draft is not a published release' "$release_notes"
    require_not_contains 'must not be used to create a `5.0.0` tag.' "$release_notes"
    require_not_contains 'remains in draft status' "$release_notes"
    require_not_contains 'current draft intentionally' "$release_notes"

    require_line "# API Stability (5.x)" "$api_stability"
    require_contains '`5.0.0` is the public compatibility baseline for this contract.' "$api_stability"
    require_contains '.upToNextMajor(from: "5.0.0")' "$api_stability"
    require_not_contains "# API Stability (5.0 Draft)" "$api_stability"
    require_not_contains 'No `5.0.0` tag exists yet' "$api_stability"

    require_contains '`5.0.0` is the latest tagged stable release' "$readme"
    require_contains '.upToNextMajor(from: "5.0.0")' "$readme"
    require_contains '5.0 Release Notes: [docs/releases/5.0.0.md](docs/releases/5.0.0.md)' "$readme"
    require_not_contains '`4.0.0` is the latest tagged stable release' "$readme"
    require_not_contains 'no `5.0.0` tag exists yet' "$readme"
    require_not_contains 'Draft 5.0 Release Notes' "$readme"

    require_line "## [Unreleased]" "$changelog"
    require_line "## [5.0.0] - $release_date" "$changelog"
    require_not_contains 'These changes have not been tagged' "$changelog"
    require_not_contains 'draft release summary' "$changelog"

    require_contains '`5.x` is the actively supported tagged public release line.' "$security_policy"
    require_not_contains '`4.x` is the actively supported tagged public release line.' "$security_policy"
    require_not_contains 'unreleased 5.0 preview on `main`' "$security_policy"
    require_contains '5.0.0 release baseline' "$symbols_readme"
    require_not_contains 'unreleased 5.0 preview snapshot' "$symbols_readme"

    require_contains 'This guide describes the released 5.0.0 compatibility reset.' "$migration"
    require_not_contains 'This guide describes the unreleased 5.0 draft.' "$migration"
    require_not_contains 'There is no `5.0.0` tag yet.' "$migration"
    ;;
esac

if (( print_state == 1 )); then
  printf '%s\n' "$release_state"
else
  printf '✅ 5.0 documentation release state is coherent: %s%s\n' \
    "$release_state" "${git_ref:+ at $git_ref}"
fi
