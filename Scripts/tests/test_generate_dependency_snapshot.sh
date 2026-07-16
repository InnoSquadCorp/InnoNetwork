#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
generator="$repo_root/Scripts/generate_dependency_snapshot.py"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dependency-snapshot.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

sbom="$test_root/sbom.cdx.json"
first="$test_root/first.snapshot.json"
second="$test_root/second.snapshot.json"

cat > "$sbom" <<'JSON'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "metadata": {
    "component": {"bom-ref": "pkg:swift/fixture-root@main", "name": "FixtureRoot"}
  },
  "components": [
    {
      "bom-ref": "pkg:swift/alpha@1.2.3",
      "name": "Alpha",
      "version": "1.2.3",
      "purl": "pkg:swift/alpha@1.2.3",
      "externalReferences": [
        {"type": "vcs", "url": "https://github.com/Example-Org/Alpha.git"}
      ]
    },
    {
      "bom-ref": "pkg:swift/beta@2.0.0%2Bbuild.1",
      "name": "Beta",
      "version": "2.0.0+build.1",
      "purl": "pkg:swift/beta@2.0.0%2Bbuild.1",
      "externalReferences": [
        {"type": "vcs", "url": "https://github.com/example-org/beta.git"}
      ]
    },
    {
      "bom-ref": "pkg:swift/gamma@3.1.4",
      "name": "Gamma",
      "version": "3.1.4",
      "purl": "pkg:swift/gamma@3.1.4",
      "externalReferences": [
        {"type": "vcs", "url": "git@github.com:example-org/gamma.git"}
      ]
    },
    {
      "bom-ref": "pkg:swift/local-helper",
      "name": "LocalHelper",
      "purl": "pkg:swift/local-helper"
    }
  ],
  "dependencies": [
    {
      "ref": "pkg:swift/fixture-root@main",
      "dependsOn": [
        "pkg:swift/alpha@1.2.3",
        "pkg:swift/beta@2.0.0%2Bbuild.1",
        "pkg:swift/local-helper"
      ]
    },
    {
      "ref": "pkg:swift/alpha@1.2.3",
      "dependsOn": ["pkg:swift/gamma@3.1.4"]
    },
    {
      "ref": "pkg:swift/beta@2.0.0%2Bbuild.1",
      "dependsOn": ["pkg:swift/alpha@1.2.3"]
    },
    {"ref": "pkg:swift/gamma@3.1.4", "dependsOn": []},
    {"ref": "pkg:swift/local-helper", "dependsOn": []}
  ]
}
JSON

generate() {
    local output="$1"
    env \
        GITHUB_SHA="0123456789abcdef0123456789abcdef01234567" \
        GITHUB_REF="refs/heads/main" \
        GITHUB_REPOSITORY="InnoSquadCorp/InnoNetwork" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_RUN_ID="123456" \
        GITHUB_RUN_ATTEMPT="2" \
        GITHUB_WORKFLOW="Swift Dependency Submission" \
        GITHUB_JOB="submit" \
        DEPENDENCY_SNAPSHOT_SCANNED="2026-07-16T00:00:00Z" \
        python3 "$generator" "$sbom" "$output" >/dev/null
}

generate "$first"
generate "$second"
cmp "$first" "$second"

python3 - "$first" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    snapshot = json.load(source)

assert snapshot["version"] == 0
assert snapshot["sha"] == "0123456789abcdef0123456789abcdef01234567"
assert snapshot["ref"] == "refs/heads/main"
assert snapshot["job"]["correlator"] == "innonetwork-swiftpm-package-resolved"
assert snapshot["job"]["id"] == "123456.2"
assert snapshot["scanned"] == "2026-07-16T00:00:00Z"

manifest = snapshot["manifests"]["Package.resolved"]
assert manifest["file"]["source_location"] == "Package.resolved"
resolved = manifest["resolved"]
assert list(resolved) == [
    "pkg:swift/github.com/Example-Org/Alpha@1.2.3",
    "pkg:swift/github.com/example-org/beta@2.0.0%2Bbuild.1",
    "pkg:swift/github.com/example-org/gamma@3.1.4",
]
assert resolved["pkg:swift/github.com/example-org/beta@2.0.0%2Bbuild.1"] == {
    "package_url": "pkg:swift/github.com/example-org/beta@2.0.0%2Bbuild.1",
    "relationship": "direct",
    "dependencies": ["pkg:swift/github.com/Example-Org/Alpha@1.2.3"],
}
assert resolved["pkg:swift/github.com/Example-Org/Alpha@1.2.3"] == {
    "package_url": "pkg:swift/github.com/Example-Org/Alpha@1.2.3",
    "relationship": "direct",
    "dependencies": ["pkg:swift/github.com/example-org/gamma@3.1.4"],
}
assert resolved["pkg:swift/github.com/example-org/gamma@3.1.4"]["relationship"] == "indirect"
assert "pkg:swift/local-helper" not in resolved
PY

unsupported_sbom="$test_root/unsupported-source.cdx.json"
python3 - "$sbom" "$unsupported_sbom" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
document["components"][1]["externalReferences"][0]["url"] = "https://example.invalid/beta.git"
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(document, destination)
PY

expect_snapshot_failure() {
    local input="$1"
    local stem="$2"
    local expected_message="$3"

    if env \
        GITHUB_SHA="0123456789abcdef0123456789abcdef01234567" \
        GITHUB_REF="refs/heads/main" \
        GITHUB_REPOSITORY="InnoSquadCorp/InnoNetwork" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_RUN_ID="123456" \
        GITHUB_RUN_ATTEMPT="1" \
        python3 "$generator" "$input" "$test_root/$stem.json" \
            > "$test_root/$stem.log" 2>&1; then
        printf 'Expected dependency snapshot fixture %s to fail.\n' "$stem" >&2
        exit 1
    fi

    if ! grep -q "$expected_message" "$test_root/$stem.log"; then
        printf 'Fixture %s failed without the expected validation message.\n' "$stem" >&2
        cat "$test_root/$stem.log" >&2
        exit 1
    fi
}

expect_snapshot_failure \
    "$unsupported_sbom" \
    "unsupported-source" \
    "unsupported Swift package source URL"

unversioned_remote_sbom="$test_root/unversioned-remote.cdx.json"
python3 - "$sbom" "$unversioned_remote_sbom" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
document["components"][1].pop("version")
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(document, destination)
PY
expect_snapshot_failure \
    "$unversioned_remote_sbom" \
    "unversioned-remote" \
    "remote component Beta has no resolved version"

query_source_sbom="$test_root/query-source.cdx.json"
python3 - "$sbom" "$query_source_sbom" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
document["components"][1]["externalReferences"][0]["url"] = (
    "https://github.com/example-org/beta.git?ref=main"
)
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(document, destination)
PY
expect_snapshot_failure \
    "$query_source_sbom" \
    "query-source" \
    "GitHub package source URL contains a query or fragment"

encoded_separator_sbom="$test_root/encoded-separator.cdx.json"
python3 - "$sbom" "$encoded_separator_sbom" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
document["components"][1]["externalReferences"][0]["url"] = (
    "https://github.com/example%2Forg/beta.git"
)
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(document, destination)
PY
expect_snapshot_failure \
    "$encoded_separator_sbom" \
    "encoded-separator" \
    "GitHub package source URL contains an encoded path separator"

if env -u GITHUB_SHA \
    GITHUB_REF="refs/heads/main" \
    GITHUB_REPOSITORY="InnoSquadCorp/InnoNetwork" \
    GITHUB_SERVER_URL="https://github.com" \
    GITHUB_RUN_ID="123456" \
    GITHUB_RUN_ATTEMPT="1" \
    GITHUB_WORKFLOW="Swift Dependency Submission" \
    GITHUB_JOB="submit" \
    python3 "$generator" "$sbom" "$test_root/missing-context.json" \
        > "$test_root/missing-context.log" 2>&1; then
    printf 'Expected a missing GITHUB_SHA to fail.\n' >&2
    exit 1
fi

if ! grep -q 'environment variable GITHUB_SHA is required' "$test_root/missing-context.log"; then
    printf 'Missing context failed without the expected validation message.\n' >&2
    exit 1
fi

printf '✅ dependency snapshot conversion, canonical purls, relationships, and fail-closed inputs verified.\n'
