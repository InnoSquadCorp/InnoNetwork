#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-release-source.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1"
    else
        sha256sum "$1"
    fi
}

source_manifest() {
    (
        cd "$repo_root"
        git ls-files --cached --others --exclude-standard -- \
            LICENSE CHANGELOG.md Platforms SmokeTests/AndroidConsumer SmokeTests/WebConsumer \
            SmokeTests/ReactConsumer SmokeTests/WebTarballConsumer SmokeTests/BrowserConsumer \
            'Scripts/check_android_*' 'Scripts/check_web_*' Scripts/check_cross_platform.sh \
            Scripts/prepare_cross_platform_release.sh Scripts/serve_web_browser_smoke.mjs \
            .github/workflows/cross-platform.yml .github/workflows/codeql.yml |
            LC_ALL=C sort -u |
            while IFS= read -r source_file; do hash_file "$source_file"; done
    )
}

source_manifest >"$work_dir/before.sha256"
"$repo_root/Scripts/check_cross_platform.sh"
source_manifest >"$work_dir/after.sha256"
cmp "$work_dir/before.sha256" "$work_dir/after.sha256" || {
    echo "Source changed during release validation; refusing to package stale evidence." >&2
    exit 1
}

mkdir -p "$repo_root/output"
bundle="$(mktemp -d "$repo_root/output/innonetwork-1.0.0.XXXXXX")"
repository="$repo_root/Platforms/Android/build/preview-repository/com/innosquad/innonetwork"
for module in innonetwork innonetwork-client innonetwork-kotlinx-serialization innonetwork-ksp; do
    destination="$bundle/maven/com/innosquad/innonetwork/$module"
    mkdir -p "$destination"
    cp -R "$repository/$module/1.0.0" "$destination/1.0.0"
done
mkdir "$bundle/npm"
(cd "$repo_root/Platforms/Web" && npm pack --quiet --ignore-scripts --pack-destination "$bundle/npm")
cp "$work_dir/after.sha256" "$bundle/SOURCE_SHA256SUMS"
cp "$repo_root/Platforms/RELEASE_READINESS.md" "$bundle/README.md"
node -e '
const fs = require("node:fs");
const {execFileSync} = require("node:child_process");
const root = process.argv[2];
const git = (...args) => execFileSync("git", args, {cwd: root, encoding: "utf8"}).trim();
fs.writeFileSync(process.argv[1], JSON.stringify({
  version: "1.0.0",
  createdAtUTC: new Date().toISOString(),
  baseRevision: git("rev-parse", "HEAD"),
  includesUncommittedSources: git("status", "--porcelain").length > 0,
  nodeVersion: process.version,
  portableValidation: "passed",
  sourceChangedDuringValidation: false,
  registryPublished: false,
  signed: false,
  remoteCI: "not established by this bundle",
  platformQualification: "see README.md for separate browser and Android runtime evidence"
}, null, 2) + "\n");
' "$bundle/receipt.json" "$repo_root"
(
    cd "$bundle"
    { find maven npm -type f -print; printf '%s\n' README.md receipt.json SOURCE_SHA256SUMS; } |
        LC_ALL=C sort | while IFS= read -r artifact_file; do hash_file "$artifact_file"; done
) >"$bundle/SHA256SUMS"
echo "InnoNetwork 1.0.0 local Maven/npm bundle: $bundle"
