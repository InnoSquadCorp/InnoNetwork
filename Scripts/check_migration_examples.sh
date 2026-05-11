#!/usr/bin/env bash
# Enforces compile-time correctness for opted-in migration guide examples.
#
# The migration guides under `docs/Migration-*.md` are predominantly
# illustrative — they show side-by-side "before / after" fragments with
# `// ...` placeholders that are not meant to compile on their own.
# A small subset of blocks, however, are full enough to compile against
# the current public surface, and those *should* be verified so the
# guide cannot drift past a renamed or removed API.
#
# To opt a code block in, place the HTML comment marker
#
#     <!-- compile-check -->
#
# on the line immediately preceding the opening ```swift fence:
#
#     <!-- compile-check -->
#     ```swift
#     import InnoNetwork
#     // …code that must continue to compile…
#     ```
#
# Each marked block is extracted to its own Swift file, wrapped in a
# smoke target that depends on `InnoNetwork`, and compiled. Unmarked
# blocks are skipped.
#
# Wire this into the docs-contract CI job alongside
# `check_docs_contract_sync.sh` and `check_stable_examples.sh`.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

shopt -s nullglob
migration_docs=("$repo_root"/docs/Migration-*.md)
shopt -u nullglob

if (( ${#migration_docs[@]} == 0 )); then
    echo "No docs/Migration-*.md files found; nothing to verify."
    exit 0
fi

smoke_root="$repo_root/.build/migration-example-smoke"
rm -rf "$smoke_root"
mkdir -p "$smoke_root/Sources"

manifest_products=""
manifest_targets=""
extracted=0

for doc in "${migration_docs[@]}"; do
    doc_name="$(basename "$doc" .md)"
    # Use python3 to pull out marker-tagged ```swift blocks because the
    # marker→fence relationship requires a small bit of state that awk's
    # default block-form makes awkward to express cleanly. One interpreter
    # pass per document keeps block discovery and extraction in sync.
    while IFS=$'\t' read -r target_name; do
        [[ -z "$target_name" ]] && continue
        manifest_products+="        .executable(name: \"$target_name\", targets: [\"$target_name\"]),"$'\n'
        manifest_targets+="        .executableTarget(name: \"$target_name\", dependencies: [.product(name: \"InnoNetwork\", package: \"InnoNetwork\")]),"$'\n'
        extracted=$((extracted + 1))
    done < <(
        python3 - "$doc" "$doc_name" "$smoke_root" <<'PY'
import hashlib
import os
import re
import sys

doc_path, doc_name, smoke_root = sys.argv[1], sys.argv[2], sys.argv[3]

with open(doc_path, "r", encoding="utf-8") as handle:
    lines = handle.readlines()

slug = re.sub(r"[^A-Za-z0-9]", "", doc_name) or "MigrationDoc"
doc_hash = hashlib.sha256(doc_name.encode("utf-8")).hexdigest()[:8]

count = 0
i = 0
while i < len(lines):
    if lines[i].strip() == "<!-- compile-check -->":
        j = i + 1
        while j < len(lines) and lines[j].strip() == "":
            j += 1
        if j < len(lines) and lines[j].rstrip() == "```swift":
            count += 1
            end = j + 1
            while end < len(lines) and lines[end].rstrip() != "```":
                end += 1
            target_name = f"{slug}{doc_hash}Block{count}"
            target_dir = os.path.join(smoke_root, "Sources", target_name)
            if os.path.exists(target_dir):
                sys.exit(
                    f"Duplicate migration example target '{target_name}' generated from {doc_path}"
                )
            os.makedirs(target_dir, exist_ok=False)
            with open(os.path.join(target_dir, "Snippet.swift"), "w", encoding="utf-8") as output:
                output.write("".join(lines[j + 1:end]))
            print(target_name)
            i = end + 1
            continue
    i += 1
PY
    )
done

if (( extracted == 0 )); then
    echo "✅ No migration code blocks opted in via <!-- compile-check -->; nothing to compile."
    exit 0
fi

cat > "$smoke_root/Package.swift" <<EOF
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MigrationExampleSmoke",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1)
    ],
    products: [
$manifest_products    ],
    dependencies: [
        .package(path: "$repo_root")
    ],
    targets: [
$manifest_targets    ]
)
EOF

xcrun swift build --package-path "$smoke_root"

echo "✅ $extracted migration code block(s) compiled successfully."
