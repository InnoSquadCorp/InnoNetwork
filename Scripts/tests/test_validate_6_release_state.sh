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
  docs/site/index.html; do
  mkdir -p "$scratch/$(dirname "$path")"
  cp "$repo_root/$path" "$scratch/$path"
done
mkdir -p "$scratch/Scripts"
cp "$repo_root/Scripts/validate_6_release_state.sh" "$scratch/Scripts/"
git -C "$scratch" add .
git -C "$scratch" commit --quiet -m fixture

bash "$scratch/Scripts/validate_6_release_state.sh" --expect "$current_state" --ref HEAD

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
  's/1,614 declarations/1,407 declarations/g' 'the superseded 6.0 API count'
assert_scope_change_rejected Scripts/symbols/budgets.tsv \
  's/1614/1407/g' 'an outdated API budget'
assert_scope_change_rejected Scripts/symbols/tier-budgets.tsv \
  's/1275/1068/g' 'an outdated provisional tier budget'
assert_scope_change_rejected docs/ROADMAP.md \
  's/## 6.0.0 Included Capabilities/## 6.1.0 Candidate Scope/' 'a split roadmap'
assert_scope_change_rejected docs/releases/6.1.0.md \
  's/release-status: draft/release-status: ready/' 'publishable superseded notes'

bash "$scratch/Scripts/validate_6_release_state.sh" --expect "$current_state"
echo "6.0 release-state tests: OK"
