#!/usr/bin/env bash

set -euo pipefail

scripts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generator="$scripts_root/generate-sbom.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/generate-sbom.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fixture="$test_root/resolved-dependencies.json"
first_output="$test_root/first.cdx.json"
second_output="$test_root/second.cdx.json"
core_output="$test_root/core-only.cdx.json"

cat > "$fixture" <<'JSON'
{
  "identity": "fixture-root",
  "name": "FixtureRoot",
  "url": "/Users/fixture/project",
  "version": "unspecified",
  "path": "/Users/fixture/project",
  "dependencies": [
    {
      "identity": "beta",
      "name": "Beta",
      "url": "https://example.invalid/beta.git",
      "version": "2.0.0",
      "path": "/Users/fixture/checkouts/beta",
      "dependencies": [
        {
          "identity": "gamma",
          "name": "Gamma",
          "url": "https://example.invalid/gamma.git",
          "version": "3.1.4",
          "path": "/Users/fixture/checkouts/gamma",
          "dependencies": []
        }
      ]
    },
    {
      "identity": "alpha",
      "name": "Alpha",
      "url": "https://example.invalid/alpha.git",
      "version": "1.2.3",
      "path": "/Users/fixture/checkouts/alpha",
      "dependencies": [
        {
          "identity": "gamma",
          "name": "Gamma",
          "url": "https://example.invalid/gamma.git",
          "version": "3.1.4",
          "path": "/Users/fixture/checkouts/gamma",
          "dependencies": []
        }
      ]
    },
    {
      "identity": "local-helper",
      "name": "LocalHelper",
      "url": "/Users/fixture/local-helper",
      "version": "unspecified",
      "path": "/Users/fixture/local-helper",
      "dependencies": []
    }
  ]
}
JSON

generate() {
    local output="$1"
    local profile="${2:-default}"
    env \
        SBOM_DEPENDENCY_JSON="$fixture" \
        SBOM_TRAIT_PROFILE="$profile" \
        SBOM_VERSION="9.8.7" \
        SBOM_SERIAL_NUMBER="urn:uuid:11111111-2222-4333-8444-555555555555" \
        SBOM_TIMESTAMP="2026-07-14T00:00:00Z" \
        SBOM_REVISION="0123456789abcdef" \
        SBOM_SWIFT_VERSION="Apple Swift version 6.2 (fixture)" \
        bash "$generator" "$output" >/dev/null
}

generate "$first_output"
generate "$second_output"
generate "$core_output" core-only

cmp "$first_output" "$second_output"

python3 - "$first_output" "$core_output" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
with open(sys.argv[2], encoding="utf-8") as source:
    core_document = json.load(source)

assert document["bomFormat"] == "CycloneDX"
assert document["specVersion"] == "1.5"
assert document["metadata"]["component"]["bom-ref"] == "pkg:swift/fixture-root@9.8.7"
properties = {
    item["name"]: item["value"]
    for item in document["metadata"]["component"]["properties"]
}
assert properties["swift:trait-profile"] == "default"
core_properties = {
    item["name"]: item["value"]
    for item in core_document["metadata"]["component"]["properties"]
}
assert core_properties["swift:trait-profile"] == "core-only"

components = {component["bom-ref"]: component for component in document["components"]}
assert list(components) == [
    "pkg:swift/alpha@1.2.3",
    "pkg:swift/beta@2.0.0",
    "pkg:swift/gamma@3.1.4",
    "pkg:swift/local-helper",
]
assert components["pkg:swift/gamma@3.1.4"]["version"] == "3.1.4"
assert "version" not in components["pkg:swift/local-helper"]
assert "externalReferences" not in components["pkg:swift/local-helper"]

relationships = {
    relationship["ref"]: relationship["dependsOn"]
    for relationship in document["dependencies"]
}
assert relationships == {
    "pkg:swift/alpha@1.2.3": ["pkg:swift/gamma@3.1.4"],
    "pkg:swift/beta@2.0.0": ["pkg:swift/gamma@3.1.4"],
    "pkg:swift/fixture-root@9.8.7": [
        "pkg:swift/alpha@1.2.3",
        "pkg:swift/beta@2.0.0",
        "pkg:swift/local-helper",
    ],
    "pkg:swift/gamma@3.1.4": [],
    "pkg:swift/local-helper": [],
}

serialized = json.dumps(document, sort_keys=True)
assert "/Users/fixture" not in serialized
assert '"path"' not in serialized
PY

if env \
    SBOM_DEPENDENCY_JSON="$fixture" \
    SBOM_TRAIT_PROFILE="unsupported" \
    bash "$generator" "$test_root/unsupported.cdx.json" > "$test_root/unsupported.log" 2>&1; then
    printf 'Expected an unsupported trait profile to fail.\n' >&2
    exit 1
fi

if ! grep -q 'Unsupported SBOM trait profile: unsupported' "$test_root/unsupported.log"; then
    printf 'Unsupported trait profile failed without the expected validation message.\n' >&2
    cat "$test_root/unsupported.log" >&2
    exit 1
fi

invalid_fixture="$test_root/invalid-dependencies.json"
printf '{"identity":"broken","name":"Broken","dependencies":[{}]}\n' > "$invalid_fixture"
if env \
    SBOM_DEPENDENCY_JSON="$invalid_fixture" \
    SBOM_VERSION="9.8.7" \
    SBOM_SERIAL_NUMBER="urn:uuid:11111111-2222-4333-8444-555555555555" \
    SBOM_TIMESTAMP="2026-07-14T00:00:00Z" \
    SBOM_REVISION="0123456789abcdef" \
    SBOM_SWIFT_VERSION="Apple Swift version 6.2 (fixture)" \
    bash "$generator" "$test_root/invalid.cdx.json" > "$test_root/invalid.log" 2>&1; then
    printf 'Expected malformed dependency graph generation to fail.\n' >&2
    exit 1
fi

if ! grep -q "has no non-empty 'identity' field" "$test_root/invalid.log"; then
    printf 'Malformed graph failed without the expected validation message.\n' >&2
    cat "$test_root/invalid.log" >&2
    exit 1
fi

conflicting_fixture="$test_root/conflicting-dependencies.json"
cat > "$conflicting_fixture" <<'JSON'
{
  "identity": "fixture-root",
  "name": "FixtureRoot",
  "version": "unspecified",
  "dependencies": [
    {
      "identity": "alpha",
      "name": "Alpha",
      "version": "1.0.0",
      "dependencies": [
        {"identity": "shared", "name": "Shared", "version": "1.0.0", "dependencies": []}
      ]
    },
    {
      "identity": "beta",
      "name": "Beta",
      "version": "1.0.0",
      "dependencies": [
        {
          "identity": "shared",
          "name": "Shared",
          "version": "1.0.0",
          "dependencies": [
            {"identity": "unexpected", "name": "Unexpected", "version": "1.0.0", "dependencies": []}
          ]
        }
      ]
    }
  ]
}
JSON
if env \
    SBOM_DEPENDENCY_JSON="$conflicting_fixture" \
    SBOM_VERSION="9.8.7" \
    SBOM_SERIAL_NUMBER="urn:uuid:11111111-2222-4333-8444-555555555555" \
    SBOM_TIMESTAMP="2026-07-14T00:00:00Z" \
    SBOM_REVISION="0123456789abcdef" \
    SBOM_SWIFT_VERSION="Apple Swift version 6.2 (fixture)" \
    bash "$generator" "$test_root/conflicting.cdx.json" > "$test_root/conflicting.log" 2>&1; then
    printf 'Expected conflicting repeated dependency relationships to fail.\n' >&2
    exit 1
fi

if ! grep -q "has conflicting relationships" "$test_root/conflicting.log"; then
    printf 'Conflicting graph failed without the expected validation message.\n' >&2
    cat "$test_root/conflicting.log" >&2
    exit 1
fi

printf '✅ generate-sbom.sh: deterministic graphs, trait profiles, relationships, and path redaction verified.\n'
