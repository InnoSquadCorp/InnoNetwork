#!/usr/bin/env bash
#
# Emits a CycloneDX 1.5 SBOM (JSON) describing the InnoNetwork package and
# its SwiftPM build inputs. The package currently has zero external
# dependencies, so the document is intentionally compact — it is still
# useful for supply-chain auditing and sigstore attestation.
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
SERIAL="$serial" \
TIMESTAMP="$timestamp" \
NAME="$name" \
VERSION="$version" \
REVISION="$revision" \
SWIFT_VERSION="$swift_version" \
python3 - <<'PY'
import json
import os

output = os.environ["OUTPUT"]
name = os.environ["NAME"]
version = os.environ["VERSION"]

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
    "components": [],
}

with open(output, "w", encoding="utf-8") as file:
    json.dump(document, file, indent=2)
    file.write("\n")
PY

echo "Generated $OUTPUT (revision $revision, version $version)"
