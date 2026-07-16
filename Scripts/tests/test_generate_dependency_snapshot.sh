#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
generator="$repo_root/Scripts/generate_dependency_snapshot.py"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dependency-snapshot.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

sbom="$test_root/sbom.cdx.json"
first="$test_root/first.snapshot.json"
second="$test_root/second.snapshot.json"
package_resolved="$test_root/Package.resolved"
resolved_snapshot="$test_root/resolved.snapshot.json"

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

cat > "$package_resolved" <<'JSON'
{
  "originHash": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
  "pins": [
    {
      "identity": "alpha",
      "kind": "remoteSourceControl",
      "location": "https://github.com/Example-Org/Alpha.git",
      "state": {
        "revision": "1111111111111111111111111111111111111111",
        "version": "1.2.3"
      }
    },
    {
      "identity": "beta",
      "kind": "remoteSourceControl",
      "location": "https://github.com/example-org/beta.git",
      "state": {
        "revision": "2222222222222222222222222222222222222222",
        "version": "2.0.0+build.1"
      }
    },
    {
      "identity": "gamma",
      "kind": "remoteSourceControl",
      "location": "git@github.com:example-org/gamma.git",
      "state": {
        "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "version": "3.1.4"
      }
    }
  ],
  "version": 3
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

env \
    GITHUB_SHA="0123456789abcdef0123456789abcdef01234567" \
    GITHUB_REF="refs/heads/main" \
    GITHUB_REPOSITORY="InnoSquadCorp/InnoNetwork" \
    GITHUB_SERVER_URL="https://github.com" \
    GITHUB_RUN_ID="654321" \
    GITHUB_RUN_ATTEMPT="3" \
    DEPENDENCY_SNAPSHOT_SHA="fedcba9876543210fedcba9876543210fedcba98" \
    DEPENDENCY_SNAPSHOT_REF="refs/pull/76/head" \
    DEPENDENCY_SNAPSHOT_DETECTOR_SHA="0123456789abcdef0123456789abcdef01234567" \
    DEPENDENCY_SNAPSHOT_SCANNED="2026-07-16T00:00:00Z" \
    python3 "$generator" --package-resolved \
        "$package_resolved" "$resolved_snapshot" >/dev/null

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

python3 - "$resolved_snapshot" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    snapshot = json.load(source)

assert snapshot["sha"] == "fedcba9876543210fedcba9876543210fedcba98"
assert snapshot["ref"] == "refs/pull/76/head"
assert snapshot["job"]["id"] == "654321.3"
assert snapshot["detector"]["url"].endswith(
    "/blob/0123456789abcdef0123456789abcdef01234567/"
    "Scripts/generate_dependency_snapshot.py"
)
resolved = snapshot["manifests"]["Package.resolved"]["resolved"]
assert list(resolved) == [
    "pkg:swift/github.com/Example-Org/Alpha@1.2.3",
    "pkg:swift/github.com/example-org/beta@2.0.0%2Bbuild.1",
    "pkg:swift/github.com/example-org/gamma@3.1.4",
]
assert all(value == {"package_url": purl} for purl, value in resolved.items())
PY

safe_transition="$test_root/safe-transition.resolved"
retag_transition="$test_root/retag-transition.resolved"
python3 - "$package_resolved" "$safe_transition" "$retag_transition" <<'PY'
import copy
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)

safe = copy.deepcopy(document)
safe["pins"][0]["state"]["version"] = "1.2.4"
safe["pins"][0]["state"]["revision"] = "3333333333333333333333333333333333333333"
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(safe, destination)

retag = copy.deepcopy(document)
retag["pins"][0]["state"]["revision"] = "4444444444444444444444444444444444444444"
with open(sys.argv[3], "w", encoding="utf-8") as destination:
    json.dump(retag, destination)
PY

python3 "$generator" --verify-package-resolved-transition \
    "$package_resolved" "$safe_transition" >/dev/null
if python3 "$generator" --verify-package-resolved-transition \
    "$package_resolved" "$retag_transition" \
    > "$test_root/retag-transition.log" 2>&1; then
    printf 'Expected a same-version revision change to fail.\n' >&2
    exit 1
fi
if ! grep -q 'at the same version but changes its immutable revision' \
    "$test_root/retag-transition.log"; then
    printf 'Retag transition failed without the expected validation message.\n' >&2
    cat "$test_root/retag-transition.log" >&2
    exit 1
fi

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
    local input_mode="${4:-sbom}"
    local generator_arguments=()
    if [[ "$input_mode" == "package-resolved" ]]; then
        generator_arguments+=(--package-resolved)
    fi

    if env \
        GITHUB_SHA="0123456789abcdef0123456789abcdef01234567" \
        GITHUB_REF="refs/heads/main" \
        GITHUB_REPOSITORY="InnoSquadCorp/InnoNetwork" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_RUN_ID="123456" \
        GITHUB_RUN_ATTEMPT="1" \
        python3 "$generator" "${generator_arguments[@]}" \
            "$input" "$test_root/$stem.json" \
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

file_source_sbom="$test_root/file-source.cdx.json"
python3 - "$sbom" "$file_source_sbom" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
document["components"][1]["externalReferences"][0]["url"] = (
    "file://github.com/example-org/beta.git"
)
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(document, destination)
PY
expect_snapshot_failure \
    "$file_source_sbom" \
    "file-source" \
    "unsupported Swift package source URL"

unsupported_kind="$test_root/unsupported-kind.resolved"
python3 - "$package_resolved" "$unsupported_kind" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
document["pins"][1]["kind"] = "registry"
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(document, destination)
PY
expect_snapshot_failure \
    "$unsupported_kind" \
    "unsupported-kind" \
    "has unsupported kind 'registry'" \
    "package-resolved"

branch_pin="$test_root/branch-pin.resolved"
python3 - "$package_resolved" "$branch_pin" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
document["pins"][2]["state"].pop("version")
document["pins"][2]["state"]["branch"] = "main"
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(document, destination)
PY
expect_snapshot_failure \
    "$branch_pin" \
    "branch-pin" \
    "uses unsupported branch 'main'" \
    "package-resolved"

duplicate_identity="$test_root/duplicate-identity.resolved"
python3 - "$package_resolved" "$duplicate_identity" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
duplicate = dict(document["pins"][0])
duplicate["identity"] = "ALPHA"
document["pins"].append(duplicate)
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(document, destination)
PY
expect_snapshot_failure \
    "$duplicate_identity" \
    "duplicate-identity" \
    "identity 'ALPHA' is duplicated" \
    "package-resolved"

unsupported_schema="$test_root/unsupported-schema.resolved"
python3 - "$package_resolved" "$unsupported_schema" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
document["version"] = 2
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(document, destination)
PY
expect_snapshot_failure \
    "$unsupported_schema" \
    "unsupported-schema" \
    "Package.resolved must use schema version 3" \
    "package-resolved"

python3 - "$package_resolved" "$test_root" <<'PY'
import copy
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
output_root = Path(sys.argv[2])
document = json.loads(source.read_text(encoding="utf-8"))

fixtures = {}

unknown_field = copy.deepcopy(document)
unknown_field["unexpected"] = True
fixtures["unknown-field.resolved"] = unknown_field

invalid_origin = copy.deepcopy(document)
invalid_origin["originHash"] = "not-a-hash"
fixtures["invalid-origin.resolved"] = invalid_origin

invalid_revision = copy.deepcopy(document)
invalid_revision["pins"][0]["state"]["revision"] = "mutable"
fixtures["invalid-revision.resolved"] = invalid_revision

missing_revision = copy.deepcopy(document)
missing_revision["pins"][0]["state"].pop("revision")
fixtures["missing-revision.resolved"] = missing_revision

revision_only = copy.deepcopy(document)
revision_only["pins"][0]["state"].pop("version")
fixtures["revision-only.resolved"] = revision_only

invalid_version = copy.deepcopy(document)
invalid_version["pins"][0]["state"]["version"] = "latest"
fixtures["invalid-version.resolved"] = invalid_version

insecure_http = copy.deepcopy(document)
insecure_http["pins"][0]["location"] = "http://github.com/Example-Org/Alpha.git"
fixtures["insecure-http.resolved"] = insecure_http

https_credentials = copy.deepcopy(document)
https_credentials["pins"][0]["location"] = (
    "https://token@github.com/Example-Org/Alpha.git"
)
fixtures["https-credentials.resolved"] = https_credentials

wrong_ssh_user = copy.deepcopy(document)
wrong_ssh_user["pins"][0]["location"] = (
    "ssh://root@github.com/Example-Org/Alpha.git"
)
fixtures["wrong-ssh-user.resolved"] = wrong_ssh_user

duplicate_coordinate = copy.deepcopy(document)
duplicate_pin = copy.deepcopy(duplicate_coordinate["pins"][0])
duplicate_pin["identity"] = "alpha-alias"
duplicate_pin["state"]["version"] = "9.9.9"
duplicate_coordinate["pins"].append(duplicate_pin)
fixtures["duplicate-coordinate.resolved"] = duplicate_coordinate

case_variant_coordinate = copy.deepcopy(document)
case_variant_pin = copy.deepcopy(case_variant_coordinate["pins"][0])
case_variant_pin["identity"] = "alpha-case-variant"
case_variant_pin["location"] = "https://github.com/example-org/alpha.git"
case_variant_pin["state"]["version"] = "9.9.9"
case_variant_coordinate["pins"].append(case_variant_pin)
fixtures["case-variant-coordinate.resolved"] = case_variant_coordinate

for name, fixture in fixtures.items():
    (output_root / name).write_text(
        json.dumps(fixture), encoding="utf-8", newline="\n"
    )

duplicate_key = source.read_text(encoding="utf-8").replace(
    '"version": 3', '"version": 3, "version": 3'
)
(output_root / "duplicate-key.resolved").write_text(
    duplicate_key, encoding="utf-8", newline="\n"
)

(output_root / "oversized.resolved").write_bytes(b"{" + b" " * 1_048_576)
PY

expect_snapshot_failure \
    "$test_root/unknown-field.resolved" \
    "unknown-field" \
    "contains unsupported field(s): unexpected" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/invalid-origin.resolved" \
    "invalid-origin" \
    "originHash must be a 64-character hash" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/invalid-revision.resolved" \
    "invalid-revision" \
    "revision is not an immutable commit hash" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/missing-revision.resolved" \
    "missing-revision" \
    "state is missing field(s): revision" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/revision-only.resolved" \
    "revision-only" \
    "has no semantic version" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/invalid-version.resolved" \
    "invalid-version" \
    "version is not a semantic version" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/insecure-http.resolved" \
    "insecure-http" \
    "unsupported Swift package source URL" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/https-credentials.resolved" \
    "https-credentials" \
    "HTTPS GitHub package source URL contains credentials" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/wrong-ssh-user.resolved" \
    "wrong-ssh-user" \
    "SSH GitHub package source URL must use the git user" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/duplicate-coordinate.resolved" \
    "duplicate-coordinate" \
    "repository coordinate" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/case-variant-coordinate.resolved" \
    "case-variant-coordinate" \
    "repository coordinate" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/duplicate-key.resolved" \
    "duplicate-key" \
    "JSON object contains duplicate key 'version'" \
    "package-resolved"
expect_snapshot_failure \
    "$test_root/oversized.resolved" \
    "oversized" \
    "exceeds the 1048576-byte limit" \
    "package-resolved"

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
