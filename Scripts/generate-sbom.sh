#!/usr/bin/env bash
#
# Emits a CycloneDX 1.5 SBOM (JSON) describing the InnoNetwork package and
# its SwiftPM build inputs. Components are derived from the SwiftPM manifest
# rather than hardcoded, so added external dependencies appear in release
# attestations.
#
# Output is written to the path supplied as the first argument, defaulting
# to .build/release-artifacts/sbom.cdx.json.

set -euo pipefail

OUTPUT="${1:-.build/release-artifacts/sbom.cdx.json}"
mkdir -p "$(dirname "$OUTPUT")"

# Resolve metadata from the SwiftPM manifest.
package_json="$(xcrun swift package describe --type json)"
name="$(printf '%s' "$package_json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])')"
version="${SBOM_VERSION:-${GITHUB_REF_NAME:-unknown}}"
serial="urn:uuid:$(uuidgen | tr 'A-Z' 'a-z')"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
revision="$(git rev-parse HEAD 2>/dev/null || echo "unknown")"
swift_version="$(xcrun swift --version | head -n 1)"

OUTPUT="$OUTPUT" \
PACKAGE_JSON="$package_json" \
SERIAL="$serial" \
TIMESTAMP="$timestamp" \
NAME="$name" \
VERSION="$version" \
REVISION="$revision" \
SWIFT_VERSION="$swift_version" \
python3 - <<'PY'
import json
import os
import posixpath
import sys

output = os.environ["OUTPUT"]
name = os.environ["NAME"]
version = os.environ["VERSION"]
package = json.loads(os.environ["PACKAGE_JSON"])


def dependency_name(dependency):
    name = dependency.get("identity") or dependency.get("name")
    if name:
        return str(name)

    source = dependency.get("url") or dependency.get("path")
    if not source:
        return None

    trimmed = str(source).rstrip("/")
    basename = posixpath.basename(trimmed)
    if basename.endswith(".git"):
        basename = basename[:-4]
    return basename or trimmed


def dependency_version(requirement):
    if isinstance(requirement, str):
        return requirement
    if not isinstance(requirement, dict):
        return None

    exact = requirement.get("exact")
    if isinstance(exact, str):
        return exact
    if isinstance(exact, list) and exact:
        return str(exact[0])

    revision = requirement.get("revision")
    if isinstance(revision, str):
        return revision

    branch = requirement.get("branch")
    if isinstance(branch, str):
        return branch

    return None


def dependency_component(dependency):
    if not isinstance(dependency, dict):
        return None

    dep_name = dependency_name(dependency)
    if not dep_name:
        return None

    requirement = dependency.get("requirement")
    version = dependency_version(requirement)
    purl = f"pkg:swift/{dep_name}"
    if version:
        purl = f"{purl}@{version}"

    properties = []
    for key in ("identity", "url", "path"):
        value = dependency.get(key)
        if value:
            properties.append({"name": f"swift:{key}", "value": str(value)})
    if requirement:
        if isinstance(requirement, str):
            requirement_value = requirement
        else:
            requirement_value = json.dumps(requirement, sort_keys=True, separators=(",", ":"))
        properties.append({"name": "swift:requirement", "value": requirement_value})

    component = {
        "type": "library",
        "bom-ref": purl,
        "name": dep_name,
        "scope": "required",
        "purl": purl,
    }
    if version:
        component["version"] = version
    if properties:
        component["properties"] = properties
    return component


dependencies = package.get("dependencies") or []
components = [component for component in (dependency_component(dependency) for dependency in dependencies) if component]
if dependencies and not components:
    print("SBOM generation found SwiftPM dependencies but could not populate CycloneDX components.", file=sys.stderr)
    sys.exit(1)

document = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": os.environ["SERIAL"],
    "version": 1,
    "metadata": {
        "timestamp": os.environ["TIMESTAMP"],
        "tools": {
            "components": [
                {
                    "type": "application",
                    "name": "Scripts/generate-sbom.sh",
                    "version": "1.0.0",
                }
            ]
        },
        "component": {
            "type": "library",
            "bom-ref": f"pkg:swift/{name}@{version}",
            "name": name,
            "version": version,
            "scope": "required",
            "purl": f"pkg:swift/{name}@{version}",
            "properties": [
                {"name": "swift:revision", "value": os.environ["REVISION"]},
                {"name": "swift:toolchain", "value": os.environ["SWIFT_VERSION"]},
            ],
        },
    },
    "components": components,
}

with open(output, "w", encoding="utf-8") as file:
    json.dump(document, file, indent=2)
    file.write("\n")
PY

echo "Generated $OUTPUT (revision $revision, version $version)"
