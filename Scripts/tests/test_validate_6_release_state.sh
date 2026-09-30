#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

current_state="$(bash "$repo_root/Scripts/validate_6_release_state.sh" --print-state)"
bash "$repo_root/Scripts/validate_6_release_state.sh" --expect "$current_state"

opposite_state="ready"
if [[ "$current_state" == "ready" ]]; then
  opposite_state="draft"
fi
if bash "$repo_root/Scripts/validate_6_release_state.sh" --expect "$opposite_state" \
  >/dev/null 2>&1; then
  echo "6.0 release-state test: $current_state unexpectedly passed as $opposite_state" >&2
  exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-6-release-test.XXXXXX")"
cleanup() {
  rm -rf "$scratch"
}
trap cleanup EXIT

git -C "$scratch" init --quiet
git -C "$scratch" config user.name "InnoNetwork Tests"
git -C "$scratch" config user.email "tests@example.invalid"
for path in \
  API_STABILITY.md \
  README.md \
  CHANGELOG.md \
  SECURITY.md \
  Scripts/symbols/README.md \
  Scripts/symbols/budgets.tsv \
  Scripts/symbols/tier-budgets.tsv \
  Sources/InnoNetwork/InnoNetwork.docc/MigrationTo6.md \
  docs/Migration-6.0.0.md \
  docs/ROADMAP.md \
  docs/releases/6.0.0.md \
  docs/releases/6.1.0.md \
  docs/releases/archive/6.1.0-superseded-roadmap.md \
  docs/site/index.html; do
  mkdir -p "$scratch/$(dirname "$path")"
  cp "$repo_root/$path" "$scratch/$path"
done
mkdir -p "$scratch/Scripts"
cp "$repo_root/Scripts/validate_6_release_state.sh" "$scratch/Scripts/"
git -C "$scratch" add .
git -C "$scratch" commit --quiet -m fixture

bash "$scratch/Scripts/validate_6_release_state.sh" --expect "$current_state" --ref HEAD

# A later candidate can become Ready without publishing the superseded roadmap
# or changing the historical 6.0 contract. This edits only the disposable fixture.
sed 's/release-status: draft/release-status: ready/' \
  "$repo_root/docs/releases/6.1.0.md" > "$scratch/docs/releases/6.1.0.md"
bash "$scratch/Scripts/validate_6_release_state.sh" --expect "$current_state"
cp "$repo_root/docs/releases/6.1.0.md" "$scratch/docs/releases/6.1.0.md"

# Losing the archive must not silently treat the new candidate as old scope.
mv "$scratch/docs/releases/archive/6.1.0-superseded-roadmap.md" "$scratch/superseded-record.md"
if bash "$scratch/Scripts/validate_6_release_state.sh" \
  --expect "$current_state" > "$scratch/rejection.log" 2>&1; then
  echo "6.0 release-state test: accepted a missing historical scope record" >&2
  exit 1
fi
grep -Fq "missing" "$scratch/rejection.log"

# Existing tags retain the old layout. Validate that committed layout even when
# the working tree subsequently restores the new canonical candidate/archive.
cp "$scratch/superseded-record.md" "$scratch/docs/releases/6.1.0.md"
git -C "$scratch" add docs/releases
git -C "$scratch" commit --quiet -m legacy-layout
bash "$scratch/Scripts/validate_6_release_state.sh" --expect "$current_state" --ref HEAD
mv "$scratch/superseded-record.md" "$scratch/docs/releases/archive/6.1.0-superseded-roadmap.md"
cp "$repo_root/docs/releases/6.1.0.md" "$scratch/docs/releases/6.1.0.md"

assert_scope_change_rejected() {
  local relative_path="$1"
  local substitution="$2"
  local description="$3"
  sed "$substitution" "$repo_root/$relative_path" > "$scratch/$relative_path"
  if bash "$scratch/Scripts/validate_6_release_state.sh" \
    --expect "$current_state" > "$scratch/rejection.log" 2>&1; then
    echo "6.0 release-state test: accepted $description" >&2
    exit 1
  fi
  # Ref validation must still use the coherent committed tree rather than
  # reading the deliberately inconsistent working-tree file.
  bash "$scratch/Scripts/validate_6_release_state.sh" \
    --expect "$current_state" --ref HEAD >/dev/null
  cp "$repo_root/$relative_path" "$scratch/$relative_path"
}

assert_scope_change_rejected docs/releases/6.0.0.md \
  's/1,702 declarations/1,407 declarations/g' 'the superseded 6.0 API count'
assert_scope_change_rejected Scripts/symbols/budgets.tsv \
  's/1702/1407/g;s/1764/1407/g' 'an outdated API budget'
assert_scope_change_rejected Scripts/symbols/tier-budgets.tsv \
  's/1362/1068/g;s/1364/1068/g' 'an outdated provisional tier budget'
if grep -Fq 'encoded-request-candidate: 6.1.0' "$repo_root/API_STABILITY.md"; then
  assert_scope_change_rejected API_STABILITY.md \
    '/encoded-request-candidate: 6.1.0/d' 'an implicit new-version inventory'
  assert_scope_change_rejected API_STABILITY.md \
    '/These additions are unpublished; they do not alter 6.0.0./d' 'a candidate without its unpublished boundary'
fi
assert_scope_change_rejected docs/ROADMAP.md \
  's/## 6.0.0 Included Capabilities/## 6.1.0 Candidate Scope/' 'a split roadmap'
assert_scope_change_rejected docs/releases/archive/6.1.0-superseded-roadmap.md \
  's/release-status: draft/release-status: ready/' 'publishable superseded notes'

assert_scope_change_rejected docs/releases/6.0.0.md \
  "s/release-status: $current_state/release-status: $opposite_state/" 'a marker-only transition'

if [[ "$current_state" == "ready" ]]; then
  assert_scope_change_rejected docs/releases/6.0.0.md \
    '/Confirm the matching tag and GitHub Release before adopting 6.0.0./d' \
    'ready contents without the publication boundary'
  assert_scope_change_rejected docs/releases/6.0.0.md \
    's/^Release date: .*/Release date: TBD/' 'ready contents without a date'

  assert_publication_claim_rejected() {
    local relative_path="$1"
    local claim="$2"
    printf '\n%s\n' "$claim" >> "$scratch/$relative_path"
    if bash "$scratch/Scripts/validate_6_release_state.sh" \
      --expect ready > "$scratch/rejection.log" 2>&1; then
      echo "6.0 release-state test: ready falsely claimed publication in $relative_path" >&2
      exit 1
    fi
    grep -Fq 'unexpected' "$scratch/rejection.log"
    bash "$scratch/Scripts/validate_6_release_state.sh" --expect ready --ref HEAD >/dev/null
    cp "$repo_root/$relative_path" "$scratch/$relative_path"
  }

  assert_publication_claim_rejected README.md \
    '`6.0.0` is the latest tagged stable release'
  assert_publication_claim_rejected SECURITY.md \
    '`6.x` is the actively supported tagged public release line.'
  assert_publication_claim_rejected docs/Migration-6.0.0.md \
    'This guide describes the released InnoNetwork 6.0 compatibility reset.'
  assert_publication_claim_rejected docs/site/index.html \
    'The latest tagged stable release is 6.0.0.'
fi

bash "$scratch/Scripts/validate_6_release_state.sh" --expect "$current_state"
echo "6.0 release-state tests: OK"
