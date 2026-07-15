#!/usr/bin/env bash

set -euo pipefail

scripts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator_source="$scripts_root/validate_docs_release_state.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/validate-docs-release-state.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

test_index=0
passed=0

new_fixture() {
  local state="$1"

  test_index=$((test_index + 1))
  current_repo="$test_root/repo-$test_index"
  mkdir -p \
    "$current_repo/Scripts/symbols" \
    "$current_repo/docs/releases"
  cp "$validator_source" "$current_repo/Scripts/validate_docs_release_state.sh"

  if [[ "$state" == "draft" ]]; then
    cat > "$current_repo/API_STABILITY.md" <<'EOF'
# API Stability (5.0 Draft)

No `5.0.0` tag exists yet: `4.0.0` remains the latest tagged baseline.

`.upToNextMajor(from: "4.0.0")`
EOF
    cat > "$current_repo/README.md" <<'EOF'
# Fixture

`4.0.0` is the latest tagged stable release; no `5.0.0` tag exists yet.

Draft 5.0 Release Notes: [docs/releases/5.0.0.md](docs/releases/5.0.0.md)
EOF
    cat > "$current_repo/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

These changes have not been tagged.
EOF
    cat > "$current_repo/SECURITY.md" <<'EOF'
# Security

`4.x` is the actively supported tagged public release line.
The unreleased 5.0 preview on `main` is not a support line.
EOF
    cat > "$current_repo/Scripts/symbols/README.md" <<'EOF'
# Symbols

This is an unreleased 5.0 preview snapshot.
EOF
    cat > "$current_repo/docs/Migration-5.0.0.md" <<'EOF'
# Migration Guide: 5.0.0

This guide describes the unreleased 5.0 draft. There is no `5.0.0` tag yet.
EOF
    cat > "$current_repo/docs/releases/5.0.0.md" <<'EOF'
<!-- release-status: draft -->
# InnoNetwork 5.0.0 Release Notes

Status: Draft (unreleased)

Release date: TBD

This draft is not a published release and must not be used to create a `5.0.0` tag.
EOF
  else
    cat > "$current_repo/API_STABILITY.md" <<'EOF'
# API Stability (5.x)

`5.0.0` is the public compatibility baseline for this contract.

`.upToNextMajor(from: "5.0.0")`
EOF
    cat > "$current_repo/README.md" <<'EOF'
# Fixture

`5.0.0` is the latest tagged stable release.

`.upToNextMajor(from: "5.0.0")`

5.0 Release Notes: [docs/releases/5.0.0.md](docs/releases/5.0.0.md)
EOF
    cat > "$current_repo/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [5.0.0] - 2026-07-16
EOF
    cat > "$current_repo/SECURITY.md" <<'EOF'
# Security

`5.x` is the actively supported tagged public release line.
EOF
    cat > "$current_repo/Scripts/symbols/README.md" <<'EOF'
# Symbols

## Current sizes (5.0.0 release baseline)
EOF
    cat > "$current_repo/docs/Migration-5.0.0.md" <<'EOF'
# Migration Guide: 5.0.0

This guide describes the released 5.0.0 compatibility reset.
EOF
    cat > "$current_repo/docs/releases/5.0.0.md" <<'EOF'
<!-- release-status: ready -->
# InnoNetwork 5.0.0 Release Notes

Status: Ready for release

Release date: 2026-07-16
EOF
  fi
}

run_validator() {
  local repo="$1"
  shift
  bash "$repo/Scripts/validate_docs_release_state.sh" "$@"
}

expect_success() {
  local name="$1"
  shift
  local output

  if ! output="$("$@" 2>&1)"; then
    printf '❌ %s: expected success\n%s\n' "$name" "$output" >&2
    exit 1
  fi
  passed=$((passed + 1))
  printf '✅ %s\n' "$name"
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output

  if output="$("$@" 2>&1)"; then
    printf '❌ %s: expected failure\n%s\n' "$name" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    printf '❌ %s: failure did not contain %q\n%s\n' "$name" "$expected" "$output" >&2
    exit 1
  fi
  passed=$((passed + 1))
  printf '✅ %s\n' "$name"
}

new_fixture draft
expect_success "coherent draft state" run_validator "$current_repo" --expect draft

new_fixture ready
expect_success "coherent ready state" run_validator "$current_repo" --expect ready

new_fixture draft
expect_failure "explicit expected state mismatch" "expected 'ready' release state" \
  run_validator "$current_repo" --expect ready

new_fixture ready
printf '\n`4.0.0` is the latest tagged stable release.\n' >> "$current_repo/README.md"
expect_failure "ready marker cannot retain preview README claims" \
  '`4.0.0` is the latest tagged stable release' \
  run_validator "$current_repo"

new_fixture draft
printf '\n<!-- release-status: ready -->\n' >> "$current_repo/docs/releases/5.0.0.md"
expect_failure "duplicate status markers fail closed" "exactly one release-status marker" \
  run_validator "$current_repo"

new_fixture draft
sed -i.bak '1s/draft/pending/' "$current_repo/docs/releases/5.0.0.md"
rm "$current_repo/docs/releases/5.0.0.md.bak"
expect_failure "unknown status marker fails closed" "exact draft or ready release-status marker" \
  run_validator "$current_repo"

new_fixture ready
git init -q --initial-branch=main "$current_repo"
git -C "$current_repo" config user.name "Docs State Test"
git -C "$current_repo" config user.email "docs-state@example.invalid"
git -C "$current_repo" add .
git -C "$current_repo" commit -q -m "ready fixture"
printf '\n`4.0.0` is the latest tagged stable release.\n' >> "$current_repo/README.md"
expect_success "--ref validates the committed tree instead of dirty worktree files" \
  run_validator "$current_repo" --expect ready --ref HEAD

printf '\n✅ validate_docs_release_state.sh: %d deterministic cases passed.\n' "$passed"
