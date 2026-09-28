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

contracts="$test_dir/contracts"
xcrun swift run --package-path "$tool_dir" openapi-to-innonetwork \
  --input "$fixtures/contracts.json" --output "$contracts" --module-name Contracts
xcrun swiftc -typecheck -I "$bin_path" -I "$bin_path/Modules" "$contracts"/*.swift
xcrun swiftc -parse-as-library \
  "$contracts/AnimalBase.swift" "$contracts/Cat.swift" "$contracts/Dog.swift" \
  "$contracts/Pet.swift" "$contracts/NullableRecord.swift" \
  "$fixtures/contracts-runtime.swift" -o "$test_dir/contracts-runtime"
"$test_dir/contracts-runtime"

security="$test_dir/security"
xcrun swift run --package-path "$tool_dir" openapi-to-innonetwork \
  --input "$fixtures/security.json" --output "$security" --module-name Security
xcrun swift run --package-path "$tool_dir" openapi-to-innonetwork \
  --input "$fixtures/security.json" --output "$test_dir/security-again" --module-name Security
diff -ru "$security" "$test_dir/security-again"
xcrun swiftc -typecheck -I "$bin_path" -I "$bin_path/Modules" "$security"/*.swift
# SwiftPM's Apple build system emits an aggregate object; the native build
# system used by older supported toolchains emits per-source objects instead.
core_objects=()
if [[ -f "$bin_path/InnoNetwork.o" ]]; then
  core_objects+=("$bin_path/InnoNetwork.o")
else
  while IFS= read -r object; do core_objects+=("$object"); done < <(
    find "$bin_path/InnoNetwork.build" -name '*.o' -type f | sort
  )
fi
test "${#core_objects[@]}" -gt 0
xcrun swiftc -parse-as-library -I "$bin_path" -I "$bin_path/Modules" \
  "$security"/*.swift "$fixtures/security-runtime.swift" "${core_objects[@]}" \
  -o "$test_dir/security-runtime"
"$test_dir/security-runtime"

anyof="$test_dir/anyof"
xcrun swift run --package-path "$tool_dir" openapi-to-innonetwork \
  --input "$fixtures/anyof.json" --output "$anyof" --module-name AnyOf
xcrun swift run --package-path "$tool_dir" openapi-to-innonetwork \
  --input "$fixtures/anyof.json" --output "$test_dir/anyof-again" --module-name AnyOf
diff -ru "$anyof" "$test_dir/anyof-again"
xcrun swiftc -swift-version 6 -typecheck -I "$bin_path" -I "$bin_path/Modules" "$anyof"/*.swift
xcrun swiftc -swift-version 6 -parse-as-library -I "$bin_path" -I "$bin_path/Modules" \
  "$anyof"/*.swift "$fixtures/anyof-runtime.swift" "${core_objects[@]}" \
  -o "$test_dir/anyof-runtime"
"$test_dir/anyof-runtime"
if xcrun swift run --package-path "$tool_dir" openapi-to-innonetwork \
  --input "$fixtures/anyof-unsupported.json" --output "$test_dir/unsupported-anyof" \
  > "$test_dir/unsupported.stdout" 2> "$test_dir/unsupported.stderr"; then
  echo 'Generator silently discarded an anyOf constraint.' >&2
  exit 1
fi
if ! grep -Fq 'Compiled schema validation failed: unsupportedSchema' "$test_dir/unsupported.stderr"; then
  cat "$test_dir/unsupported.stderr" >&2
  echo 'Unsupported-schema fixture failed for an unexpected reason.' >&2
  exit 1
fi
test ! -e "$test_dir/unsupported-anyof"

compiled="$test_dir/schema-constraints"
for destination in "$compiled" "$test_dir/schema-constraints-again"; do
  xcrun swift run --package-path "$tool_dir" openapi-to-innonetwork \
    --input "$fixtures/schema-constraints.json" --output "$destination" --module-name Compiled
done
diff -ru "$compiled" "$test_dir/schema-constraints-again"
xcrun swiftc -swift-version 6 -parse-as-library -I "$bin_path" -I "$bin_path/Modules" \
  "$compiled"/*.swift "$fixtures/schema-constraints-runtime.swift" "${core_objects[@]}" \
  -o "$test_dir/schema-constraints-runtime"
"$test_dir/schema-constraints-runtime"

modern="$test_dir/schema-31"
for destination in "$modern" "$test_dir/schema-31-again"; do
  xcrun swift run --package-path "$tool_dir" openapi-to-innonetwork \
    --input "$fixtures/schema-31.json" --output "$destination" --module-name Modern
done
diff -ru "$modern" "$test_dir/schema-31-again"
xcrun swiftc -swift-version 6 -parse-as-library -I "$bin_path" -I "$bin_path/Modules" \
  "$modern"/*.swift "$fixtures/schema-31-runtime.swift" "${core_objects[@]}" \
  -o "$test_dir/schema-31-runtime"
"$test_dir/schema-31-runtime"

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
