#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-openapi-output.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

tool_dir="$repo_root/Tools/openapi-to-innonetwork"
fixtures="$tool_dir/Tests/Fixtures"
generated="$test_dir/generated"
xcrun swift run --package-path "$tool_dir" openapi-to-innonetwork \
  --input "$fixtures/valid-identifier-and-summary.json" \
  --output "$generated" \
  --module-name "RegressionAPI"

test "$(find "$generated" -maxdepth 1 -name '*.swift' -type f | wc -l | tr -d ' ')" -eq 2
grep -Fq 'public struct _1stStatus: APIDefinition' "$generated/_1stStatus.swift"
grep -Fq '/// Continue the description.' "$generated/_1stStatus.swift"
xcrun swiftc -frontend -parse "$generated"/*.swift

xcrun swift build --target InnoNetwork
bin_path="$(xcrun swift build --show-bin-path)"
xcrun swiftc -typecheck -I "$bin_path" -I "$bin_path/Modules" "$generated"/*.swift

if xcrun swift run --package-path "$tool_dir" openapi-to-innonetwork \
  --input "$fixtures/colliding-operation-names.json" \
  --output "$test_dir/collision" \
  > "$test_dir/collision.stdout" 2> "$test_dir/collision.stderr"; then
  echo 'Generator accepted colliding operation names.' >&2
  exit 1
fi
grep -Fq 'Generated name collision' "$test_dir/collision.stderr"
test ! -e "$test_dir/collision"

echo 'OpenAPI generated-output parse and typecheck passed.'
