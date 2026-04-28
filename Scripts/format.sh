#!/usr/bin/env bash
# Apply or check swift-format across the repo.
#
# Usage:
#   Scripts/format.sh           # Format files in-place (developer workflow)
#   Scripts/format.sh --lint    # Check only, exit non-zero on diff (CI)
#
# The CI workflow invokes the --lint variant. The default in-place mode is
# what local contributors run before committing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TARGETS=(
    Sources
    Tests
    SmokeTests
    Benchmarks
    Examples
)

# Skip directories that contain non-package Swift sources or generated
# scaffolding we do not want to rewrite (consumer smoke packages each have
# their own Package.swift; we still format their sources, but exclude the
# .build artifacts produced by `swift build` runs there).
EXCLUDE_PATTERN="(^|/)(\.build|\.swiftpm|node_modules)(/|$)"

mode="format"
if [[ "${1:-}" == "--lint" ]]; then
    mode="lint"
fi

mapfile -t SWIFT_FILES < <(
    find "${TARGETS[@]}" -type f -name '*.swift' \
        | grep -Ev "$EXCLUDE_PATTERN" \
        | sort
)

if [[ ${#SWIFT_FILES[@]} -eq 0 ]]; then
    echo "No Swift files found under ${TARGETS[*]}; nothing to do."
    exit 0
fi

if [[ "$mode" == "lint" ]]; then
    echo "🔍 swift-format lint over ${#SWIFT_FILES[@]} file(s)…"
    xcrun swift-format lint --strict --configuration .swift-format "${SWIFT_FILES[@]}"
    echo "✅ swift-format lint passed."
else
    echo "🛠  swift-format format (in-place) over ${#SWIFT_FILES[@]} file(s)…"
    xcrun swift-format format --in-place --configuration .swift-format "${SWIFT_FILES[@]}"
    echo "✅ swift-format format applied."
fi
