#!/usr/bin/env bash
# Validates a pre-tag release candidate against freshly fetched canonical main.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf '❌ Release candidate validation failed: %s\n' "$1" >&2
  exit 1
}

candidate_ref="${RELEASE_CANDIDATE_REF:-HEAD}"
release_remote="${RELEASE_REMOTE:-origin}"
main_remote_ref="${RELEASE_MAIN_REMOTE_REF:-refs/heads/main}"
main_ref="${RELEASE_MAIN_REF:-refs/remotes/${release_remote}/main}"
fetch_main="${RELEASE_FETCH_MAIN:-1}"

git -C "$repo_root" check-ref-format "$main_ref" >/dev/null 2>&1 \
  || fail "main ref '$main_ref' is not a valid full Git ref."
git -C "$repo_root" check-ref-format "$main_remote_ref" >/dev/null 2>&1 \
  || fail "remote main ref '$main_remote_ref' is not a valid full Git ref."

case "$fetch_main" in
  0)
    ;;
  1)
    if ! git -C "$repo_root" fetch --no-tags "$release_remote" \
      "+${main_remote_ref}:${main_ref}"; then
      fail "could not fetch '$main_remote_ref' from '$release_remote'; refusing to use a stale main ref."
    fi
    ;;
  *)
    fail "RELEASE_FETCH_MAIN must be 0 or 1, got '$fetch_main'."
    ;;
esac

candidate_commit="$(git -C "$repo_root" rev-parse --verify "${candidate_ref}^{commit}" 2>/dev/null || true)"
[[ -n "$candidate_commit" ]] \
  || fail "candidate ref '$candidate_ref' does not resolve to a commit."

main_commit="$(git -C "$repo_root" rev-parse --verify "${main_ref}^{commit}" 2>/dev/null || true)"
[[ -n "$main_commit" ]] \
  || fail "configured main ref '$main_ref' does not resolve to a commit."

if [[ "$candidate_commit" != "$main_commit" ]]; then
  fail "candidate commit '$candidate_commit' does not exactly match configured main ref '$main_ref' ($main_commit)."
fi

printf 'release-candidate-validation: OK (%s matches %s)\n' \
  "$candidate_commit" "$main_ref"
