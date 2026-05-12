#!/usr/bin/env bash
# Enforces the "Stable Examples" contract documented in API_STABILITY.md.
#
# Each stable example directory must exist, contain at least one Swift
# source file, ship a README.md, and compile against the current package.
# The exact wording of the example is not contractual, but copyable
# starting-point code must not drift away from the public API.
#
# Wire this into the docs-contract CI job alongside
# `check_docs_contract_sync.sh`.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

stable_examples=(
    "Examples/BasicRequest"
    "Examples/Auth"
    "Examples/ErrorHandling"
)

failures=()

for example in "${stable_examples[@]}"; do
    full_path="$repo_root/$example"
    if [[ ! -d "$full_path" ]]; then
        failures+=("Stable example directory missing: $example")
        continue
    fi

    if ! find "$full_path" -name '*.swift' -type f -print -quit | grep -q .; then
        failures+=("Stable example contains no Swift sources: $example")
    fi

    if [[ ! -f "$full_path/README.md" ]]; then
        failures+=("Stable example missing README.md: $example")
    fi
done

if (( ${#failures[@]} > 0 )); then
    printf '::error::Stable example contract violation\n'
    for line in "${failures[@]}"; do
        printf '  - %s\n' "$line"
    done
    exit 1
fi

smoke_root="$repo_root/.build/stable-example-smoke"
rm -rf "$smoke_root"
mkdir -p "$smoke_root/Sources"

manifest_products=""
manifest_targets=""

for example in "${stable_examples[@]}"; do
    example_name="$(basename "$example")"
    target_name="${example_name}Smoke"

    mkdir -p "$smoke_root/Sources/$target_name"
    while IFS= read -r source_file; do
        relative_source="${source_file#"$repo_root/$example/"}"
        mkdir -p "$smoke_root/Sources/$target_name/$(dirname "$relative_source")"
        cp "$source_file" "$smoke_root/Sources/$target_name/$relative_source"
    done < <(find "$repo_root/$example" -name '*.swift' -type f | sort)

    manifest_products="${manifest_products}        .executable(name: \"$target_name\", targets: [\"$target_name\"]),"$'\n'
    manifest_targets="${manifest_targets}        .executableTarget(name: \"$target_name\", dependencies: [.product(name: \"InnoNetwork\", package: \"InnoNetwork\")]),"$'\n'
done

cat > "$smoke_root/Package.swift" <<EOF
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "StableExampleSmoke",
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

for example in "${stable_examples[@]}"; do
    example_name="$(basename "$example")"
    target_name="${example_name}Smoke"
    xcrun swift build --package-path "$smoke_root" --target "$target_name" -Xswiftc -warnings-as-errors
done

echo "✅ Stable examples contract satisfied."
