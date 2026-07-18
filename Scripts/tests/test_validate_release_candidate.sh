#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator_source="$repo_root/Scripts/validate_release_candidate.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-release-candidate-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
passed=0

new_repo() {
  current_repo="$test_root/repo-$RANDOM"
  git init -q -b main "$current_repo"
  git -C "$current_repo" config user.name Fixture
  git -C "$current_repo" config user.email fixture@example.com
  mkdir -p "$current_repo/Scripts"
  cp "$validator_source" "$current_repo/Scripts/validate_release_candidate.sh"
  printf 'candidate\n' > "$current_repo/source.txt"
  git -C "$current_repo" add .
  git -C "$current_repo" commit -q -m candidate
}

run_validator() {
  local repository="$1"
  shift
  env \
    RELEASE_CANDIDATE_REF=HEAD \
    RELEASE_MAIN_REF=refs/heads/main \
    RELEASE_FETCH_MAIN=0 \
    "$@" \
    bash "$repository/Scripts/validate_release_candidate.sh"
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

new_repo
expect_success "main HEAD is a valid candidate" run_validator "$current_repo"

new_repo
candidate_commit="$(git -C "$current_repo" rev-parse HEAD)"
printf 'advance\n' >> "$current_repo/source.txt"
git -C "$current_repo" commit -q -am advance
expect_failure "stale candidate is rejected" "does not exactly match" \
  env RELEASE_CANDIDATE_REF="$candidate_commit" \
    RELEASE_MAIN_REF=refs/heads/main RELEASE_FETCH_MAIN=0 \
    bash "$current_repo/Scripts/validate_release_candidate.sh"

new_repo
expect_failure "missing main ref is rejected" "does not resolve to a commit" \
  run_validator "$current_repo" RELEASE_MAIN_REF=refs/heads/missing

new_repo
expect_failure "invalid fetch mode is rejected" "must be 0 or 1" \
  run_validator "$current_repo" RELEASE_FETCH_MAIN=invalid

new_repo
remote_repo="$test_root/remote.git"
git clone -q --bare "$current_repo" "$remote_repo"
expect_success "fresh remote main is accepted" \
  env RELEASE_CANDIDATE_REF=HEAD RELEASE_REMOTE="$remote_repo" \
    RELEASE_MAIN_REMOTE_REF=refs/heads/main \
    RELEASE_MAIN_REF=refs/release-validation/main RELEASE_FETCH_MAIN=1 \
    bash "$current_repo/Scripts/validate_release_candidate.sh"

expect_failure "failed remote fetch is fail-closed" "refusing to use a stale main ref" \
  env RELEASE_CANDIDATE_REF=HEAD RELEASE_REMOTE="$test_root/missing.git" \
    RELEASE_MAIN_REMOTE_REF=refs/heads/main \
    RELEASE_MAIN_REF=refs/release-validation/main RELEASE_FETCH_MAIN=1 \
    bash "$current_repo/Scripts/validate_release_candidate.sh"

printf '\n✅ validate_release_candidate.sh: %d deterministic cases passed.\n' "$passed"
