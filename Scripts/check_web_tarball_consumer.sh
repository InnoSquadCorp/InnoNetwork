#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-web-tarball.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
# npm's project identity checks can misread a macOS TMPDIR containing symlinks or `//`.
work_dir="$(cd "$work_dir" && pwd -P)"

npm --prefix "$repo_root/Platforms/Web" run build >/dev/null
(
    cd "$repo_root/Platforms/Web"
    npm pack --pack-destination "$work_dir" --ignore-scripts >/dev/null
)

tarballs=("$work_dir"/*.tgz)
if [[ ${#tarballs[@]} -ne 1 || ! -f "${tarballs[0]}" ]]; then
    echo "Expected exactly one npm tarball." >&2
    exit 1
fi

consumer_dir="$work_dir/consumer"
fixture="$repo_root/SmokeTests/WebTarballConsumer"
mkdir "$consumer_dir"
cp "$fixture/package.json" "$fixture/package-lock.json" \
    "$fixture/tsconfig.json" "$fixture/tsconfig.node.json" "$consumer_dir/"
cp -R "$fixture/src" "$consumer_dir/src"
npm --prefix "$consumer_dir" ci --ignore-scripts --no-audit >/dev/null
npm --prefix "$consumer_dir" install \
    "${tarballs[0]}" \
    --no-save \
    --package-lock=false \
    --ignore-scripts \
    --no-audit >/dev/null

installed_package="$consumer_dir/node_modules/@innosquad/innonetwork"
if [[ -L "$installed_package" ]]; then
    echo "Tarball smoke accidentally installed a workspace link." >&2
    exit 1
fi

node -e '
const manifest = require(process.argv[1]);
const fs = require("node:fs");
const path = require("node:path");
if (manifest.version !== "1.0.0") {
  throw new Error("Expected 1.0.0, received " + manifest.version);
}
if (Object.keys(manifest.dependencies || {}).length !== 0) {
  throw new Error("The Web core must have zero runtime dependencies");
}
const dist = path.join(path.dirname(process.argv[1]), "dist");
for (const name of fs.readdirSync(dist).filter(name => name.endsWith(".map"))) {
  const map = JSON.parse(fs.readFileSync(path.join(dist, name), "utf8"));
  for (const source of map.sources) {
    if (!fs.existsSync(path.resolve(dist, source))) {
      throw new Error("Source map target is missing from the tarball: " + source);
    }
  }
}
' "$installed_package/package.json"

npm --prefix "$consumer_dir" run check >/dev/null
(cd "$consumer_dir" && node_modules/.bin/tsc -p tsconfig.node.json --noEmit)
"${INNO_NODE_BINARY:-node}" "$consumer_dir/src/runtime.mjs"
echo "Web 1.0.0 tarball consumer: OK"
