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
  docs/releases/6.0.0.md \
  docs/site/index.html; do
  mkdir -p "$scratch/$(dirname "$path")"
  cp "$repo_root/$path" "$scratch/$path"
done
mkdir -p "$scratch/Scripts"
cp "$repo_root/Scripts/validate_6_release_state.sh" "$scratch/Scripts/"
git -C "$scratch" add .
git -C "$scratch" commit --quiet -m fixture

bash "$scratch/Scripts/validate_6_release_state.sh" --expect "$current_state" --ref HEAD

echo "6.0 release-state tests: OK"
