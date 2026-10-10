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
  Scripts/published-releases.json \
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
cp "$repo_root/Scripts/validate_6_1_release_state.py" "$scratch/Scripts/"
git -C "$scratch" add .
git -C "$scratch" commit --quiet -m fixture

bash "$scratch/Scripts/validate_6_release_state.sh" --expect "$current_state" --ref HEAD

# A later candidate has a separate lifecycle, but a marker-only transition
# must fail. Coherent Draft/Ready/published fixtures are exercised below.
minor_transition='s/release-status: ready/release-status: draft/'
if grep -Fxq '<!-- release-status: draft -->' "$repo_root/docs/releases/6.1.0.md"; then
  minor_transition='s/release-status: draft/release-status: ready/'
fi
sed "$minor_transition" "$repo_root/docs/releases/6.1.0.md" > "$scratch/docs/releases/6.1.0.md"
if bash "$scratch/Scripts/validate_6_release_state.sh" --expect "$current_state" \
  > "$scratch/rejection.log" 2>&1; then
  echo "6.1 release-state test: accepted a marker-only transition" >&2
  exit 1
fi
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
# The actual historical layout predates the encoded-request inventory. Do not
# create a synthetic old-layout/new-inventory tree and call it historical.
sed '/<!-- encoded-request-/d' "$repo_root/API_STABILITY.md" > "$scratch/API_STABILITY.md"
sed 's/1,764/1,702/g;s/| 367 |/| 307 |/g;s/1,364/1,362/g' \
  "$repo_root/Scripts/symbols/README.md" > "$scratch/Scripts/symbols/README.md"
sed 's/1764/1702/g' "$repo_root/Scripts/symbols/budgets.tsv" > "$scratch/Scripts/symbols/budgets.tsv"
sed 's/1764/1702/g;s/367/307/g;s/1364/1362/g' \
  "$repo_root/Scripts/symbols/tier-budgets.tsv" > "$scratch/Scripts/symbols/tier-budgets.tsv"
# Historical fixture must also retain the pre-rename companion owner/version.
for path in docs/Migration-6.0.0.md Sources/InnoNetwork/InnoNetwork.docc/MigrationTo6.md; do
  sed 's/package: "InnoNetwork-Stream"/package: "InnoStream"/g;s/\.exact("6.1.1")/.upToNextMajor(from: "1.0.0")/g' \
    "$repo_root/$path" > "$scratch/$path"
done
git -C "$scratch" add docs/releases API_STABILITY.md Scripts/symbols docs/Migration-6.0.0.md Sources/InnoNetwork/InnoNetwork.docc/MigrationTo6.md
git -C "$scratch" commit --quiet -m legacy-layout
bash "$scratch/Scripts/validate_6_release_state.sh" --expect "$current_state" --ref HEAD
mv "$scratch/superseded-record.md" "$scratch/docs/releases/archive/6.1.0-superseded-roadmap.md"
cp "$repo_root/docs/releases/6.1.0.md" "$scratch/docs/releases/6.1.0.md"
for path in API_STABILITY.md Scripts/symbols/README.md Scripts/symbols/budgets.tsv Scripts/symbols/tier-budgets.tsv docs/Migration-6.0.0.md Sources/InnoNetwork/InnoNetwork.docc/MigrationTo6.md; do
  cp "$repo_root/$path" "$scratch/$path"
done

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
assert_scope_change_rejected Scripts/symbols/budgets.tsv \
  's/1764/1765/g' 'an unapproved runtime inventory increase'
assert_scope_change_rejected Scripts/symbols/tier-budgets.tsv \
  's/367/368/g' 'an unapproved Stable inventory increase'
assert_scope_change_rejected Scripts/symbols/tier-budgets.tsv \
  's/33/34/g' 'an unapproved SPI inventory increase'
printf '\nTOTAL\t9999\n' >> "$scratch/Scripts/symbols/budgets.tsv"
if bash "$scratch/Scripts/validate_6_release_state.sh" > "$scratch/rejection.log" 2>&1; then
  echo "6.1 release-state test: accepted duplicate runtime inventory budgets" >&2
  exit 1
fi
grep -Fq 'expected exactly one TOTAL budget' "$scratch/rejection.log"
cp "$repo_root/Scripts/symbols/budgets.tsv" "$scratch/Scripts/symbols/budgets.tsv"
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
python3 "$repo_root/Scripts/tests/test_validate_6_1_release_state.py"
