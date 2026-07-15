#!/usr/bin/env bash

set -euo pipefail

scripts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator_source="$scripts_root/validate_release_ref.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/validate-release-ref.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

test_index=0
passed=0

new_repo() {
    local version="$1"
    local include_notes="${2:-1}"
    local release_status="${3:-ready}"

    test_index=$((test_index + 1))
    current_repo="$test_root/repo-$test_index"
    git init -q --initial-branch=main "$current_repo"
    git -C "$current_repo" config user.name "Release Validator Test"
    git -C "$current_repo" config user.email "release-validator@example.invalid"

    mkdir -p "$current_repo/docs/releases" "$current_repo/Scripts"
    if [[ "$include_notes" == "1" ]]; then
        printf '<!-- release-status: %s -->\n\n# Release %s\n' \
            "$release_status" "$version" > "$current_repo/docs/releases/${version}.md"
    else
        printf '# Fixture\n' > "$current_repo/README.md"
    fi
    git -C "$current_repo" add .
    git -C "$current_repo" commit -q -m "fixture"
    cp "$validator_source" "$current_repo/Scripts/validate_release_ref.sh"
}

annotate() {
    local repo="$1"
    local tag="$2"
    git -C "$repo" tag -a "$tag" -m "Release $tag"
}

run_validator() {
    local repo="$1"
    local tag="$2"
    shift 2

    env \
        RELEASE_TAG="$tag" \
        RELEASE_TAG_REF="refs/tags/$tag" \
        RELEASE_MAIN_REF="refs/heads/main" \
        RELEASE_FETCH_MAIN=0 \
        "$@" \
        bash "$repo/Scripts/validate_release_ref.sh"
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

new_repo "5.0.0"
annotate "$current_repo" "5.0.0"
expect_success "annotated stable SemVer at exact main HEAD with ready notes" \
    run_validator "$current_repo" "5.0.0"

new_repo "5.0.0-rc.1+build.7"
annotate "$current_repo" "5.0.0-rc.1+build.7"
expect_success "annotated prerelease SemVer on main" \
    run_validator "$current_repo" "5.0.0-rc.1+build.7"

new_repo "5.0.0"
annotate "$current_repo" "5.0.0"
expect_failure "v-prefixed tag is rejected" "not an unprefixed SemVer" \
    run_validator "$current_repo" "v5.0.0" \
    RELEASE_TAG_REF=refs/tags/5.0.0
expect_failure "leading-zero tag is rejected" "not an unprefixed SemVer" \
    run_validator "$current_repo" "5.00.0" \
    RELEASE_TAG_REF=refs/tags/5.0.0

new_repo "5.0.0"
git -C "$current_repo" tag "5.0.0"
expect_failure "lightweight tag is rejected" "must exist as an annotated tag" \
    run_validator "$current_repo" "5.0.0"

new_repo "5.0.0" 0
annotate "$current_repo" "5.0.0"
expect_failure "missing versioned notes is rejected" "does not contain required release notes" \
    run_validator "$current_repo" "5.0.0"

new_repo "5.0.0" 1 draft
annotate "$current_repo" "5.0.0"
expect_failure "draft release notes are rejected" "is marked 'draft'" \
    run_validator "$current_repo" "5.0.0"

new_repo "5.0.0" 1 unreleased
annotate "$current_repo" "5.0.0"
expect_failure "unreleased release notes are rejected" "is marked 'unreleased'" \
    run_validator "$current_repo" "5.0.0"

new_repo "5.0.0"
sed -i.bak '1d' "$current_repo/docs/releases/5.0.0.md"
rm "$current_repo/docs/releases/5.0.0.md.bak"
git -C "$current_repo" add docs/releases/5.0.0.md
git -C "$current_repo" commit -q -m "remove release status"
annotate "$current_repo" "5.0.0"
expect_failure "missing release-status marker is rejected" "exactly one release-status marker" \
    run_validator "$current_repo" "5.0.0"

new_repo "5.0.0"
printf '\n<!-- release-status: ready -->\n' >> "$current_repo/docs/releases/5.0.0.md"
git -C "$current_repo" add docs/releases/5.0.0.md
git -C "$current_repo" commit -q -m "duplicate release status"
annotate "$current_repo" "5.0.0"
expect_failure "duplicate release-status markers are rejected" "exactly one release-status marker" \
    run_validator "$current_repo" "5.0.0"

new_repo "5.0.0"
printf '\n<!-- release-status: draft -->\n' >> "$current_repo/docs/releases/5.0.0.md"
git -C "$current_repo" add docs/releases/5.0.0.md
git -C "$current_repo" commit -q -m "conflicting release status"
annotate "$current_repo" "5.0.0"
expect_failure "conflicting release-status markers are rejected" "exactly one release-status marker" \
    run_validator "$current_repo" "5.0.0"

new_repo "5.0.0"
printf '\nThe old inline <!-- release-status: draft --> marker must not remain.\n' \
    >> "$current_repo/docs/releases/5.0.0.md"
git -C "$current_repo" add docs/releases/5.0.0.md
git -C "$current_repo" commit -q -m "add inline release status"
annotate "$current_repo" "5.0.0"
expect_failure "inline duplicate release-status marker is rejected" "exactly one release-status marker" \
    run_validator "$current_repo" "5.0.0"

new_repo "5.0.0"
annotate "$current_repo" "5.0.0"
printf 'main advanced\n' > "$current_repo/main.txt"
git -C "$current_repo" add main.txt
git -C "$current_repo" commit -q -m "advance main"
expect_failure "tag behind main HEAD is rejected" "does not exactly match configured main ref" \
    run_validator "$current_repo" "5.0.0"

new_repo "5.0.0"
git -C "$current_repo" switch -q -c release-side
printf 'side\n' > "$current_repo/side.txt"
git -C "$current_repo" add side.txt
git -C "$current_repo" commit -q -m "side commit"
annotate "$current_repo" "5.0.0"
git -C "$current_repo" switch -q main
expect_failure "tag on a side branch is rejected" "does not exactly match configured main ref" \
    run_validator "$current_repo" "5.0.0"

new_repo "5.0.0"
annotate "$current_repo" "5.0.0"
expect_failure "missing configured main ref has no fallback" "does not resolve to a commit" \
    run_validator "$current_repo" "5.0.0" \
    RELEASE_MAIN_REF=refs/heads/does-not-exist

new_repo "5.0.0"
annotate "$current_repo" "5.0.0"
git -C "$current_repo" update-ref refs/tags/6.0.0 "refs/tags/5.0.0"
cp "$current_repo/docs/releases/5.0.0.md" "$current_repo/docs/releases/6.0.0.md"
git -C "$current_repo" add docs/releases/6.0.0.md
git -C "$current_repo" commit -q -m "add alternate notes"
expect_failure "annotated tag name mismatch is rejected" "not '6.0.0'" \
    run_validator "$current_repo" "6.0.0"

new_repo "5.0.0"
annotate "$current_repo" "5.0.0"
remote_repo="$test_root/local-remote.git"
git clone -q --bare "$current_repo" "$remote_repo"
expect_success "injected local remote fetches main without network" \
    run_validator "$current_repo" "5.0.0" \
    RELEASE_REMOTE="$remote_repo" \
    RELEASE_MAIN_REMOTE_REF=refs/heads/main \
    RELEASE_MAIN_REF=refs/release-validation/main \
    RELEASE_FETCH_MAIN=1

new_repo "5.0.0"
annotate "$current_repo" "5.0.0"
tag_commit="$(git -C "$current_repo" rev-parse 'refs/tags/5.0.0^{commit}')"
stale_remote="$test_root/stale-remote.git"
git clone -q --bare "$current_repo" "$stale_remote"
git -C "$current_repo" update-ref refs/release-validation/main "$tag_commit"
printf 'remote main advanced\n' > "$current_repo/remote-main.txt"
git -C "$current_repo" add remote-main.txt
git -C "$current_repo" commit -q -m "advance remote main"
git -C "$current_repo" push -q "$stale_remote" main
expect_failure "stale local main ref is refreshed and rejected" "does not exactly match configured main ref" \
    run_validator "$current_repo" "5.0.0" \
    RELEASE_REMOTE="$stale_remote" \
    RELEASE_MAIN_REMOTE_REF=refs/heads/main \
    RELEASE_MAIN_REF=refs/release-validation/main \
    RELEASE_FETCH_MAIN=1

expect_failure "failed remote fetch does not use a stale ref" "refusing to use a stale main ref" \
    run_validator "$current_repo" "5.0.0" \
    RELEASE_REMOTE="$test_root/does-not-exist.git" \
    RELEASE_MAIN_REMOTE_REF=refs/heads/main \
    RELEASE_MAIN_REF=refs/release-validation/main \
    RELEASE_FETCH_MAIN=1

printf '\n✅ validate_release_ref.sh: %d deterministic cases passed.\n' "$passed"
