#!/usr/bin/env python3
"""Convert the release CycloneDX graph into a GitHub dependency snapshot."""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import urllib.parse
from pathlib import Path
from typing import Any


class SnapshotError(ValueError):
    """Raised when the SBOM or GitHub workflow context is incomplete."""


def required_text(mapping: dict[str, Any], key: str, context: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SnapshotError(f"{context} has no non-empty '{key}' field")
    return value.strip()


def required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SnapshotError(f"environment variable {name} is required")
    return value


def parsed_source_url(value: str) -> urllib.parse.SplitResult:
    """Parse URL-style and SCP-style Git source locations."""

    if "://" not in value:
        scp_match = re.fullmatch(
            r"(?:(?P<user>[^@\s/:]+)@)?(?P<host>[^\s/:]+):(?P<path>.+)",
            value,
        )
        if scp_match is not None:
            user = scp_match.group("user")
            authority = scp_match.group("host")
            if user is not None:
                authority = f"{user}@{authority}"
            value = f"ssh://{authority}/{scp_match.group('path')}"
    return urllib.parse.urlsplit(value)


def github_purl(component: dict[str, Any]) -> str | None:
    """Return GitHub's canonical Swift purl, skipping local path packages."""

    references = component.get("externalReferences", [])
    if not isinstance(references, list):
        raise SnapshotError("component externalReferences must be an array")
    vcs_url: str | None = None
    for reference in references:
        if not isinstance(reference, dict):
            raise SnapshotError("component externalReferences entries must be objects")
        if reference.get("type") == "vcs":
            candidate = reference.get("url")
            if isinstance(candidate, str) and candidate.strip():
                vcs_url = candidate.strip()
                break
    if vcs_url is None:
        version = component.get("version")
        if not isinstance(version, str) or not version.strip():
            # Local path packages are not represented by Package.resolved.
            return None
        raise SnapshotError(
            f"versioned component {component.get('name', '<unknown>')} has no VCS URL"
        )

    version = component.get("version")
    if not isinstance(version, str) or not version.strip():
        raise SnapshotError(
            f"remote component {component.get('name', '<unknown>')} has no resolved version"
        )
    version = version.strip()

    parsed = parsed_source_url(vcs_url)
    if parsed.hostname and parsed.hostname.lower() == "github.com":
        if parsed.query or parsed.fragment:
            raise SnapshotError(
                f"GitHub package source URL contains a query or fragment: {vcs_url}"
            )
        segments = [segment for segment in parsed.path.split("/") if segment]
        if len(segments) == 2:
            owner = urllib.parse.unquote(segments[0])
            repository = urllib.parse.unquote(segments[1])
            if "/" in owner or "/" in repository:
                raise SnapshotError(
                    f"GitHub package source URL contains an encoded path separator: {vcs_url}"
                )
            if repository.lower().endswith(".git"):
                repository = repository[:-4]
            if not owner or not repository:
                raise SnapshotError(f"malformed GitHub package source URL: {vcs_url}")
            owner = urllib.parse.quote(owner, safe="._-~")
            repository = urllib.parse.quote(repository, safe="._-~")
            encoded_version = urllib.parse.quote(version, safe="._-~")
            return f"pkg:swift/github.com/{owner}/{repository}@{encoded_version}"

    raise SnapshotError(
        f"unsupported Swift package source URL for {component.get('name', '<unknown>')}: "
        f"{vcs_url}"
    )


def dependency_relationships(document: dict[str, Any]) -> dict[str, list[str]]:
    entries = document.get("dependencies")
    if not isinstance(entries, list):
        raise SnapshotError("CycloneDX document has no dependencies array")

    relationships: dict[str, list[str]] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise SnapshotError("CycloneDX dependency entries must be objects")
        reference = required_text(entry, "ref", "CycloneDX dependency")
        children = entry.get("dependsOn", [])
        if not isinstance(children, list) or not all(
            isinstance(child, str) and child for child in children
        ):
            raise SnapshotError(f"dependency '{reference}' has invalid dependsOn data")
        if reference in relationships:
            raise SnapshotError(f"dependency '{reference}' is declared more than once")
        relationships[reference] = children
    return relationships


def build_snapshot(document: dict[str, Any]) -> dict[str, Any]:
    if document.get("bomFormat") != "CycloneDX":
        raise SnapshotError("input is not a CycloneDX document")

    metadata = document.get("metadata")
    if not isinstance(metadata, dict):
        raise SnapshotError("CycloneDX document has no metadata object")
    root_component = metadata.get("component")
    if not isinstance(root_component, dict):
        raise SnapshotError("CycloneDX metadata has no root component")
    root_reference = required_text(root_component, "bom-ref", "root component")

    raw_components = document.get("components")
    if not isinstance(raw_components, list):
        raise SnapshotError("CycloneDX document has no components array")
    components: dict[str, dict[str, Any]] = {}
    for component in raw_components:
        if not isinstance(component, dict):
            raise SnapshotError("CycloneDX components must be objects")
        reference = required_text(component, "bom-ref", "CycloneDX component")
        if reference in components:
            raise SnapshotError(f"component '{reference}' is declared more than once")
        components[reference] = component

    relationships = dependency_relationships(document)
    if root_reference not in relationships:
        raise SnapshotError("CycloneDX graph has no root dependency relationship")

    purls_by_reference: dict[str, str] = {}
    references_by_purl: dict[str, str] = {}
    for reference, component in components.items():
        purl = github_purl(component)
        if purl is None:
            continue
        previous = references_by_purl.get(purl)
        if previous is not None and previous != reference:
            raise SnapshotError(
                f"components '{previous}' and '{reference}' normalize to the same purl"
            )
        purls_by_reference[reference] = purl
        references_by_purl[purl] = reference

    direct_references = set(relationships[root_reference])
    resolved: dict[str, dict[str, Any]] = {}
    for reference, purl in sorted(purls_by_reference.items(), key=lambda item: item[1]):
        children = sorted(
            purls_by_reference[child]
            for child in relationships.get(reference, [])
            if child in purls_by_reference
        )
        resolved[purl] = {
            "package_url": purl,
            "relationship": "direct" if reference in direct_references else "indirect",
            "dependencies": children,
        }

    if not resolved:
        raise SnapshotError("CycloneDX graph contains no versioned remote dependencies")

    sha = required_environment("GITHUB_SHA")
    if re.fullmatch(r"[0-9a-fA-F]{40}", sha) is None:
        raise SnapshotError("GITHUB_SHA must be a 40-character commit SHA")
    ref = required_environment("GITHUB_REF")
    if not ref.startswith("refs/"):
        raise SnapshotError("GITHUB_REF must be a fully qualified ref")
    repository = required_environment("GITHUB_REPOSITORY")
    if repository.count("/") != 1:
        raise SnapshotError("GITHUB_REPOSITORY must use owner/name form")
    server_url = required_environment("GITHUB_SERVER_URL").rstrip("/")
    run_id = required_environment("GITHUB_RUN_ID")
    run_attempt = required_environment("GITHUB_RUN_ATTEMPT")
    if not run_id.isdecimal() or not run_attempt.isdecimal():
        raise SnapshotError("GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT must be decimal numbers")

    scanned = os.environ.get("DEPENDENCY_SNAPSHOT_SCANNED")
    if scanned is None:
        scanned = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
        scanned = scanned.replace("+00:00", "Z")

    return {
        "version": 0,
        "sha": sha.lower(),
        "ref": ref,
        "job": {
            "correlator": "innonetwork-swiftpm-package-resolved",
            "id": f"{run_id}.{run_attempt}",
            "html_url": f"{server_url}/{repository}/actions/runs/{run_id}",
        },
        "detector": {
            "name": "InnoNetwork SwiftPM dependency snapshot",
            "version": "1.0.0",
            "url": (
                f"{server_url}/{repository}/blob/{sha}/"
                "Scripts/generate_dependency_snapshot.py"
            ),
        },
        "scanned": scanned,
        "manifests": {
            "Package.resolved": {
                "name": "Package.resolved",
                "file": {"source_location": "Package.resolved"},
                "resolved": resolved,
            }
        },
    }


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: generate_dependency_snapshot.py <sbom.cdx.json> <snapshot.json>",
            file=sys.stderr,
        )
        return 2

    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    try:
        with source.open(encoding="utf-8") as source_file:
            document = json.load(source_file)
        if not isinstance(document, dict):
            raise SnapshotError("CycloneDX document root must be an object")
        snapshot = build_snapshot(document)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("w", encoding="utf-8") as destination_file:
            json.dump(snapshot, destination_file, indent=2, sort_keys=True)
            destination_file.write("\n")
    except (OSError, json.JSONDecodeError, SnapshotError) as error:
        print(f"dependency-snapshot: {error}", file=sys.stderr)
        return 1

    resolved_count = len(
        snapshot["manifests"]["Package.resolved"]["resolved"]
    )
    print(f"dependency-snapshot: OK ({resolved_count} Swift packages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
