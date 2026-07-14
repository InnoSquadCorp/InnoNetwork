#!/usr/bin/env bash
# Validates that a release workflow was triggered from a trustworthy Git tag.
#
# The release tag must be a SemVer 2.0.0 version, be an annotated tag that
# names that same version, peel to a commit on the configured main ref, and
# contain versioned release notes. By default the configured remote main ref
# is fetched first, so a stale local tracking ref is never accepted.
#
# Environment overrides are intentionally explicit so the validator can be
# exercised with local refs and local remotes in deterministic tests:
#   RELEASE_TAG             Version to validate (defaults to GITHUB_REF_NAME)
#   RELEASE_TAG_REF         Tag ref (defaults to GITHUB_REF or refs/tags/<tag>)
#   RELEASE_REMOTE          Remote to fetch (defaults to origin)
#   RELEASE_MAIN_REMOTE_REF Remote main source ref (defaults to refs/heads/main)
#   RELEASE_MAIN_REF        Local validation ref (defaults to
#                           refs/remotes/<remote>/main)
#   RELEASE_FETCH_MAIN      1 to fetch main first; 0 for an injected local ref

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf '❌ Release ref validation failed: %s\n' "$1" >&2
    exit 1
}

release_tag="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
[[ -n "$release_tag" ]] || fail "RELEASE_TAG or GITHUB_REF_NAME is required."

# SemVer 2.0.0 without a leading "v". The GitHub release trigger is *.*.*,
# so every accepted tag has the same unprefixed major.minor.patch core while
# still allowing standard prerelease and build metadata suffixes.
numeric_identifier='(0|[1-9][0-9]*)'
prerelease_identifier='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
semver_pattern="^${numeric_identifier}\\.${numeric_identifier}\\.${numeric_identifier}(-${prerelease_identifier}(\\.${prerelease_identifier})*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"

if [[ ! "$release_tag" =~ $semver_pattern ]]; then
    fail "tag '$release_tag' is not an unprefixed SemVer 2.0.0 version."
fi

release_remote="${RELEASE_REMOTE:-origin}"
main_remote_ref="${RELEASE_MAIN_REMOTE_REF:-refs/heads/main}"
main_ref="${RELEASE_MAIN_REF:-refs/remotes/${release_remote}/main}"
fetch_main="${RELEASE_FETCH_MAIN:-1}"

if [[ -n "${RELEASE_TAG_REF:-}" ]]; then
    tag_ref="$RELEASE_TAG_REF"
elif [[ -n "${GITHUB_REF:-}" ]]; then
    tag_ref="$GITHUB_REF"
else
    tag_ref="refs/tags/$release_tag"
fi

git -C "$repo_root" check-ref-format "$tag_ref" >/dev/null 2>&1 \
    || fail "tag ref '$tag_ref' is not a valid full Git ref."
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

tag_object_type="$(git -C "$repo_root" cat-file -t "$tag_ref" 2>/dev/null || true)"
if [[ "$tag_object_type" != "tag" ]]; then
    fail "'$tag_ref' must exist as an annotated tag (found '${tag_object_type:-nothing}')."
fi

declared_tag="$(git -C "$repo_root" cat-file -p "$tag_ref" \
    | sed -n 's/^tag //p' \
    | head -n 1)"
if [[ "$declared_tag" != "$release_tag" ]]; then
    fail "annotated tag object declares '$declared_tag', not '$release_tag'."
fi

tag_commit="$(git -C "$repo_root" rev-parse --verify "${tag_ref}^{commit}" 2>/dev/null || true)"
[[ -n "$tag_commit" ]] \
    || fail "annotated tag '$tag_ref' does not peel to a commit."

main_commit="$(git -C "$repo_root" rev-parse --verify "${main_ref}^{commit}" 2>/dev/null || true)"
[[ -n "$main_commit" ]] \
    || fail "configured main ref '$main_ref' does not resolve to a commit."

if ! git -C "$repo_root" merge-base --is-ancestor "$tag_commit" "$main_commit"; then
    fail "tag commit '$tag_commit' is not reachable from '$main_ref' ($main_commit)."
fi

release_notes="docs/releases/${release_tag}.md"
if ! git -C "$repo_root" cat-file -e "${tag_commit}:${release_notes}" 2>/dev/null; then
    fail "tagged commit does not contain required release notes '$release_notes'."
fi

notes_type="$(git -C "$repo_root" cat-file -t "${tag_commit}:${release_notes}" 2>/dev/null || true)"
if [[ "$notes_type" != "blob" ]]; then
    fail "'$release_notes' must be a file in the tagged commit (found '${notes_type:-nothing}')."
fi

printf '✅ Release ref validated: %s peels to %s, is reachable from %s, and contains %s.\n' \
    "$release_tag" "$tag_commit" "$main_ref" "$release_notes"
