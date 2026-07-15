#!/usr/bin/env bash
#
# Emits a CycloneDX 1.5 SBOM (JSON) from SwiftPM's resolved dependency graph.
# The default package is the repository root. Set PACKAGE_PATH to generate an
# SBOM for another package.
#
# Output is written to the path supplied as the first argument, defaulting
# to .build/release-artifacts/sbom.cdx.json.
#
# Set SBOM_TRAIT_PROFILE to `default` (the default) or `core-only`. The latter
# resolves the graph with `--disable-default-traits`, so release artifacts can
# publish both the macro-first dependency view and the opt-out core view.
#
# The SBOM_* metadata overrides and SBOM_DEPENDENCY_JSON are primarily useful
# for deterministic, network-free tests. SBOM_DEPENDENCY_JSON must name a file
# containing `swift package show-dependencies --format json` output.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-.build/release-artifacts/sbom.cdx.json}"
package_path="${PACKAGE_PATH:-$repo_root}"
trait_profile="${SBOM_TRAIT_PROFILE:-default}"

case "$trait_profile" in
    default | core-only) ;;
    *)
        printf 'Unsupported SBOM trait profile: %s (expected default or core-only)\n' \
            "$trait_profile" >&2
        exit 1
        ;;
esac

if [[ "$package_path" != /* ]]; then
    package_path="$repo_root/$package_path"
fi

mkdir -p "$(dirname "$output")"

temporary_dependency_json=""
cleanup() {
    if [[ -n "$temporary_dependency_json" ]]; then
        rm -f "$temporary_dependency_json"
    fi
}
trap cleanup EXIT

if [[ -n "${SBOM_DEPENDENCY_JSON:-}" ]]; then
    dependency_json="$SBOM_DEPENDENCY_JSON"
    [[ -f "$dependency_json" ]] || {
        printf 'SBOM dependency graph does not exist: %s\n' "$dependency_json" >&2
        exit 1
    }
else
    [[ -d "$package_path" ]] || {
        printf 'Swift package path does not exist: %s\n' "$package_path" >&2
        exit 1
    }
    temporary_dependency_json="$(mktemp "${TMPDIR:-/tmp}/innonetwork-sbom-dependencies.XXXXXX")"
    package_arguments=(--package-path "$package_path")
    if [[ "$trait_profile" == "core-only" ]]; then
        package_arguments+=(--disable-default-traits)
    fi
    xcrun swift package "${package_arguments[@]}" \
        show-dependencies --format json > "$temporary_dependency_json"
    dependency_json="$temporary_dependency_json"
fi

version="${SBOM_VERSION:-${GITHUB_REF_NAME:-unknown}}"
serial="${SBOM_SERIAL_NUMBER:-urn:uuid:$(uuidgen | tr '[:upper:]' '[:lower:]')}"
timestamp="${SBOM_TIMESTAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
revision="${SBOM_REVISION:-$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo "unknown")}"
swift_version="${SBOM_SWIFT_VERSION:-$(xcrun swift --version 2>/dev/null | head -n 1)}"

SBOM_VERSION="$version" \
SBOM_SERIAL_NUMBER="$serial" \
SBOM_TIMESTAMP="$timestamp" \
SBOM_REVISION="$revision" \
SBOM_SWIFT_VERSION="$swift_version" \
SBOM_TRAIT_PROFILE="$trait_profile" \
python3 - "$dependency_json" "$output" <<'PY'
import datetime
import json
import os
import re
import sys
import tempfile
import urllib.parse
import uuid


dependency_json, output = sys.argv[1:]


def fail(message):
    print(f"SBOM generation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


try:
    with open(dependency_json, encoding="utf-8") as dependency_file:
        graph = json.load(dependency_file)
except (OSError, json.JSONDecodeError) as error:
    fail(f"could not read the resolved SwiftPM dependency graph: {error}")


def required_text(mapping, key, context):
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"{context} has no non-empty '{key}' field")
    return value.strip()


def normalized_version(node):
    value = node.get("version")
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value or value.lower() == "unspecified":
        return None
    return value


def package_url(identity, version=None):
    encoded_identity = urllib.parse.quote(identity.lower(), safe="._-")
    result = f"pkg:swift/{encoded_identity}"
    if version:
        result += "@" + urllib.parse.quote(version, safe="._-+")
    return result


def remote_source_url(node):
    value = node.get("url")
    if not isinstance(value, str):
        return None
    value = value.strip()
    scheme = urllib.parse.urlsplit(value).scheme.lower()
    if scheme in {"https", "http", "ssh", "git"}:
        return value
    return None


def child_nodes(node, context):
    dependencies = node.get("dependencies", [])
    if not isinstance(dependencies, list):
        fail(f"{context} has a non-array 'dependencies' field")
    for index, child in enumerate(dependencies):
        if not isinstance(child, dict):
            fail(f"{context} dependency {index} is not an object")
    return dependencies


if not isinstance(graph, dict):
    fail("resolved SwiftPM dependency graph root is not an object")

root_identity = required_text(graph, "identity", "root package")
root_name = required_text(graph, "name", "root package")
root_version = os.environ["SBOM_VERSION"] if "SBOM_VERSION" in os.environ else os.environ.get("GITHUB_REF_NAME", "unknown")
if not root_version.strip():
    fail("SBOM_VERSION must not be empty")
root_version = root_version.strip()
root_ref = package_url(root_identity, root_version)

component_records = {}
component_child_sets = {}
relationship_sets = {root_ref: set()}
visiting = set()


def visit(node, parent_ref, context):
    identity = required_text(node, "identity", context)
    name = required_text(node, "name", context)
    version = normalized_version(node)
    ref = package_url(identity, version)
    children = child_nodes(node, context)
    expected_children = {
        package_url(
            required_text(child, "identity", f"dependency of {identity}"),
            normalized_version(child),
        )
        for child in children
    }

    if ref == root_ref:
        fail(f"resolved dependency '{identity}' collides with the root component reference")
    if ref in visiting:
        fail(f"resolved dependency graph contains a cycle at '{ref}'")

    source_url = remote_source_url(node)
    record = {
        "identity": identity,
        "name": name,
        "version": version,
        "source_url": source_url,
    }
    previous = component_records.get(ref)
    if previous is not None and previous != record:
        fail(f"resolved dependency reference '{ref}' has conflicting package metadata")
    component_records[ref] = record
    relationship_sets.setdefault(ref, set())
    relationship_sets.setdefault(parent_ref, set()).add(ref)

    # A repeated package is normal in the tree-shaped show-dependencies output.
    # Traverse each stable component reference once and reject actual cycles.
    if previous is not None:
        if component_child_sets[ref] != expected_children:
            fail(f"repeated dependency '{ref}' has conflicting relationships")
        return

    component_child_sets[ref] = expected_children
    visiting.add(ref)
    for child_index, child in enumerate(children):
        visit(child, ref, f"dependency {child_index} of {identity}")
    visiting.remove(ref)


for index, dependency in enumerate(child_nodes(graph, "root package")):
    visit(dependency, root_ref, f"root dependency {index}")


def component_for(ref, record):
    component = {
        "type": "library",
        "bom-ref": ref,
        "name": record["name"],
        "scope": "required",
        "purl": ref,
        "properties": [
            {"name": "swift:identity", "value": record["identity"]},
        ],
    }
    if record["version"]:
        component["version"] = record["version"]
    if record["source_url"]:
        component["externalReferences"] = [
            {"type": "vcs", "url": record["source_url"]},
        ]
    return component


components = [
    component_for(ref, component_records[ref])
    for ref in sorted(component_records)
]
relationships = [
    {"ref": ref, "dependsOn": sorted(relationship_sets[ref])}
    for ref in sorted(relationship_sets)
]

document = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": os.environ["SBOM_SERIAL_NUMBER"],
    "version": 1,
    "metadata": {
        "timestamp": os.environ["SBOM_TIMESTAMP"],
        "tools": {
            "components": [
                {
                    "type": "application",
                    "name": "Scripts/generate-sbom.sh",
                    "version": "2.1.0",
                }
            ]
        },
        "component": {
            "type": "library",
            "bom-ref": root_ref,
            "name": root_name,
            "version": root_version,
            "scope": "required",
            "purl": root_ref,
            "properties": [
                {"name": "swift:identity", "value": root_identity},
                {"name": "swift:revision", "value": os.environ["SBOM_REVISION"]},
                {"name": "swift:toolchain", "value": os.environ["SBOM_SWIFT_VERSION"]},
                {"name": "swift:trait-profile", "value": os.environ["SBOM_TRAIT_PROFILE"]},
            ],
        },
    },
    "components": components,
    "dependencies": relationships,
}


def validate_rfc3339(value):
    if not isinstance(value, str):
        fail("metadata timestamp is not a string")
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"metadata timestamp is not RFC 3339: {value!r}")
    if parsed.tzinfo is None:
        fail("metadata timestamp must include a timezone")


def contains_local_absolute_path(value):
    if not isinstance(value, str):
        return False
    return (
        value.startswith("file://")
        or os.path.isabs(value)
        or re.match(r"^[A-Za-z]:[\\/]", value) is not None
    )


try:
    serial_value = document["serialNumber"]
    if not serial_value.startswith("urn:uuid:"):
        raise ValueError("missing urn:uuid prefix")
    uuid.UUID(serial_value.removeprefix("urn:uuid:"))
except (AttributeError, ValueError) as error:
    fail(f"serialNumber is not a valid UUID URN: {error}")

validate_rfc3339(document["metadata"]["timestamp"])

component_refs = {root_ref, *(component["bom-ref"] for component in components)}
if len(component_refs) != len(components) + 1:
    fail("component bom-ref values are not unique")
relationship_refs = {relationship["ref"] for relationship in relationships}
if relationship_refs != component_refs:
    fail("dependency relationships do not cover every component exactly once")
for relationship in relationships:
    unknown_refs = set(relationship["dependsOn"]) - component_refs
    if unknown_refs:
        fail(f"dependency relationship contains unknown references: {sorted(unknown_refs)}")


def validate_no_local_paths(value, location="$"):
    if isinstance(value, dict):
        for key, child in value.items():
            validate_no_local_paths(child, f"{location}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            validate_no_local_paths(child, f"{location}[{index}]")
    elif contains_local_absolute_path(value):
        fail(f"local absolute path leaked into output at {location}")


validate_no_local_paths(document)

output_directory = os.path.dirname(os.path.abspath(output))
temporary_output = None
try:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=output_directory,
        prefix=".sbom.",
        suffix=".tmp",
        delete=False,
    ) as output_file:
        temporary_output = output_file.name
        json.dump(document, output_file, indent=2, ensure_ascii=False)
        output_file.write("\n")
    os.replace(temporary_output, output)
except OSError as error:
    if temporary_output:
        try:
            os.unlink(temporary_output)
        except FileNotFoundError:
            pass
    fail(f"could not write output: {error}")
PY

printf 'Generated %s (revision %s, version %s, traits %s)\n' \
    "$output" "$revision" "$version" "$trait_profile"
