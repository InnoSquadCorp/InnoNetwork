#!/usr/bin/env python3
"""Convert trusted dependency data into a GitHub dependency snapshot."""

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


MAX_PACKAGE_RESOLVED_BYTES = 1_048_576
MAX_PACKAGE_RESOLVED_PINS = 2_048
MAX_IDENTITY_LENGTH = 128
MAX_LOCATION_LENGTH = 512
MAX_STATE_VALUE_LENGTH = 256
MAX_PURL_LENGTH = 1_024
SEMANTIC_VERSION_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Reject duplicate JSON keys instead of silently accepting the last one."""

    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SnapshotError(f"JSON object contains duplicate key '{key}'")
        result[key] = value
    return result


def reject_json_constant(value: str) -> None:
    raise SnapshotError(f"JSON contains unsupported numeric constant '{value}'")


def validate_keys(
    mapping: dict[str, Any],
    allowed: set[str],
    required: set[str],
    context: str,
) -> None:
    unknown = sorted(set(mapping) - allowed)
    if unknown:
        raise SnapshotError(
            f"{context} contains unsupported field(s): {', '.join(unknown)}"
        )
    missing = sorted(required - set(mapping))
    if missing:
        raise SnapshotError(f"{context} is missing field(s): {', '.join(missing)}")


def bounded_text(value: Any, maximum: int, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SnapshotError(f"{context} must be a non-empty string")
    normalized = value.strip()
    if len(normalized) > maximum:
        raise SnapshotError(f"{context} exceeds the {maximum}-character limit")
    if any(ord(character) < 32 or 0x7F <= ord(character) <= 0x9F for character in normalized):
        raise SnapshotError(f"{context} contains a control character")
    if any(0xD800 <= ord(character) <= 0xDFFF for character in normalized):
        raise SnapshotError(f"{context} contains invalid Unicode")
    return normalized


def semantic_version(value: Any, context: str) -> str:
    normalized = bounded_text(value, MAX_STATE_VALUE_LENGTH, context)
    match = SEMANTIC_VERSION_PATTERN.fullmatch(normalized)
    if match is None:
        raise SnapshotError(f"{context} is not a semantic version")
    prerelease = match.group(4)
    if prerelease is not None and any(
        len(identifier) > 1 and identifier.startswith("0") and identifier.isdecimal()
        for identifier in prerelease.split(".")
    ):
        raise SnapshotError(f"{context} is not a semantic version")
    return normalized


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
    try:
        return urllib.parse.urlsplit(value)
    except ValueError as error:
        raise SnapshotError(f"malformed Swift package source URL: {value}") from error


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
    version = bounded_text(
        version,
        MAX_STATE_VALUE_LENGTH,
        f"remote component {component.get('name', '<unknown>')} version",
    )
    vcs_url = bounded_text(
        vcs_url,
        MAX_LOCATION_LENGTH,
        f"remote component {component.get('name', '<unknown>')} VCS URL",
    )

    parsed = parsed_source_url(vcs_url)
    scheme = parsed.scheme.lower()
    try:
        hostname = parsed.hostname
        port = parsed.port
    except ValueError as error:
        raise SnapshotError(f"malformed Swift package source URL: {vcs_url}") from error

    if scheme not in {"https", "ssh"} or hostname is None or hostname.lower() != "github.com":
        raise SnapshotError(
            f"unsupported Swift package source URL for {component.get('name', '<unknown>')}: "
            f"{vcs_url}"
        )
    if parsed.query or parsed.fragment:
        raise SnapshotError(
            f"GitHub package source URL contains a query or fragment: {vcs_url}"
        )
    if port is not None:
        raise SnapshotError(f"GitHub package source URL contains a port: {vcs_url}")
    if scheme == "https" and (parsed.username is not None or parsed.password is not None):
        raise SnapshotError(
            f"HTTPS GitHub package source URL contains credentials: {vcs_url}"
        )
    if scheme == "ssh" and (parsed.username != "git" or parsed.password is not None):
        raise SnapshotError(
            f"SSH GitHub package source URL must use the git user: {vcs_url}"
        )
    if "\\" in parsed.path or not parsed.path.startswith("/") or parsed.path.endswith("/"):
        raise SnapshotError(f"malformed GitHub package source URL: {vcs_url}")

    segments = parsed.path[1:].split("/")
    if len(segments) != 2 or any(not segment for segment in segments):
        raise SnapshotError(f"malformed GitHub package source URL: {vcs_url}")
    decoded_segments: list[str] = []
    for segment in segments:
        if re.search(r"%(?![0-9A-Fa-f]{2})", segment):
            raise SnapshotError(
                f"GitHub package source URL contains malformed percent encoding: {vcs_url}"
            )
        try:
            decoded = urllib.parse.unquote(segment, errors="strict")
        except UnicodeDecodeError as error:
            raise SnapshotError(
                f"GitHub package source URL contains invalid percent encoding: {vcs_url}"
            ) from error
        if "/" in decoded or "\\" in decoded:
            raise SnapshotError(
                f"GitHub package source URL contains an encoded path separator: {vcs_url}"
            )
        if decoded in {".", ".."}:
            raise SnapshotError(f"GitHub package source URL contains a dot segment: {vcs_url}")
        decoded_segments.append(
            bounded_text(decoded, MAX_LOCATION_LENGTH, "GitHub repository path segment")
        )

    owner, repository = decoded_segments
    if repository.lower().endswith(".git"):
        repository = repository[:-4]
    if not repository:
        raise SnapshotError(f"malformed GitHub package source URL: {vcs_url}")
    if re.fullmatch(r"[A-Za-z0-9_.-]+", owner) is None or re.fullmatch(
        r"[A-Za-z0-9_.-]+", repository
    ) is None:
        raise SnapshotError(
            f"GitHub package source URL contains an invalid repository name: {vcs_url}"
        )
    owner = urllib.parse.quote(owner, safe="._-~")
    repository = urllib.parse.quote(repository, safe="._-~")
    encoded_version = urllib.parse.quote(version, safe="._-~")
    purl = f"pkg:swift/github.com/{owner}/{repository}@{encoded_version}"
    if len(purl) > MAX_PURL_LENGTH:
        raise SnapshotError(
            f"package URL for {component.get('name', '<unknown>')} exceeds the "
            f"{MAX_PURL_LENGTH}-character limit"
        )
    return purl


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

    return snapshot_document(resolved)


def package_resolved_pin_state(
    state: dict[str, Any], identity: str
) -> tuple[str, str]:
    validate_keys(
        state,
        {"version", "branch", "revision"},
        {"revision"},
        f"Package.resolved pin '{identity}' state",
    )
    version = state.get("version")
    branch = state.get("branch")
    revision = bounded_text(
        state.get("revision"),
        MAX_STATE_VALUE_LENGTH,
        f"Package.resolved pin '{identity}' revision",
    )
    if re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", revision) is None:
        raise SnapshotError(
            f"Package.resolved pin '{identity}' revision is not an immutable commit hash"
        )

    if "branch" in state:
        branch_name = bounded_text(
            branch,
            MAX_STATE_VALUE_LENGTH,
            f"Package.resolved pin '{identity}' branch",
        )
        raise SnapshotError(
            f"Package.resolved pin '{identity}' uses unsupported branch '{branch_name}'"
        )
    if "version" not in state:
        raise SnapshotError(
            f"Package.resolved pin '{identity}' has no semantic version"
        )
    normalized = semantic_version(
        version,
        f"Package.resolved pin '{identity}' version",
    )
    if normalized.lower() == "unspecified":
        raise SnapshotError(
            f"Package.resolved pin '{identity}' has an unspecified version"
        )
    return normalized, revision.lower()


def package_resolved_dependencies(
    document: dict[str, Any],
) -> tuple[dict[str, dict[str, Any]], dict[str, str]]:
    validate_keys(
        document,
        {"version", "pins", "originHash"},
        {"version", "pins"},
        "Package.resolved",
    )
    if document.get("version") != 3:
        raise SnapshotError("Package.resolved must use schema version 3")
    origin_hash = document.get("originHash")
    if origin_hash is not None:
        normalized_origin_hash = bounded_text(
            origin_hash, MAX_STATE_VALUE_LENGTH, "Package.resolved originHash"
        )
        if re.fullmatch(r"[0-9a-fA-F]{64}", normalized_origin_hash) is None:
            raise SnapshotError("Package.resolved originHash must be a 64-character hash")

    pins = document.get("pins")
    if not isinstance(pins, list):
        raise SnapshotError("Package.resolved has no pins array")
    if len(pins) > MAX_PACKAGE_RESOLVED_PINS:
        raise SnapshotError(
            f"Package.resolved exceeds the {MAX_PACKAGE_RESOLVED_PINS}-pin limit"
        )

    identities: set[str] = set()
    coordinates: set[str] = set()
    resolved: dict[str, dict[str, Any]] = {}
    revisions: dict[str, str] = {}
    for index, pin in enumerate(pins):
        if not isinstance(pin, dict):
            raise SnapshotError(f"Package.resolved pin {index} is not an object")
        context = f"Package.resolved pin {index}"
        validate_keys(
            pin,
            {"identity", "kind", "location", "state"},
            {"identity", "kind", "location", "state"},
            context,
        )
        identity = bounded_text(
            pin.get("identity"), MAX_IDENTITY_LENGTH, f"{context} identity"
        )
        normalized_identity = identity.casefold()
        if normalized_identity in identities:
            raise SnapshotError(f"Package.resolved identity '{identity}' is duplicated")
        identities.add(normalized_identity)

        kind = bounded_text(pin.get("kind"), 64, f"{context} kind")
        if kind != "remoteSourceControl":
            raise SnapshotError(
                f"Package.resolved pin '{identity}' has unsupported kind '{kind}'"
            )
        location = bounded_text(
            pin.get("location"), MAX_LOCATION_LENGTH, f"{context} location"
        )
        state = pin.get("state")
        if not isinstance(state, dict):
            raise SnapshotError(f"Package.resolved pin '{identity}' has no state object")
        version, revision = package_resolved_pin_state(state, identity)
        purl = github_purl(
            {
                "name": identity,
                "version": version,
                "externalReferences": [{"type": "vcs", "url": location}],
            }
        )
        if purl is None:
            raise SnapshotError(
                f"Package.resolved pin '{identity}' did not produce a package URL"
            )
        if purl in resolved:
            raise SnapshotError(f"Package.resolved package URL '{purl}' is duplicated")
        coordinate = purl.rsplit("@", 1)[0]
        normalized_coordinate = coordinate.casefold()
        if normalized_coordinate in coordinates:
            raise SnapshotError(
                f"Package.resolved repository coordinate '{coordinate}' is duplicated"
            )
        coordinates.add(normalized_coordinate)
        # Package.resolved records the complete resolved set but not graph edges.
        # Omitting relationship metadata avoids inventing direct/transitive data.
        resolved[purl] = {"package_url": purl}
        revisions[purl] = revision

    if not resolved:
        raise SnapshotError("Package.resolved contains no versioned remote dependencies")
    return resolved, revisions


def build_package_resolved_snapshot(document: dict[str, Any]) -> dict[str, Any]:
    resolved, _ = package_resolved_dependencies(document)
    return snapshot_document(resolved)


def verify_package_resolved_transition(
    base_document: dict[str, Any], head_document: dict[str, Any]
) -> None:
    _, base_revisions = package_resolved_dependencies(base_document)
    _, head_revisions = package_resolved_dependencies(head_document)
    for purl in sorted(base_revisions.keys() & head_revisions.keys()):
        if base_revisions[purl] != head_revisions[purl]:
            raise SnapshotError(
                f"Package.resolved keeps '{purl}' at the same version but changes its "
                "immutable revision"
            )


def snapshot_document(resolved: dict[str, dict[str, Any]]) -> dict[str, Any]:
    if not resolved:
        raise SnapshotError("dependency graph contains no versioned remote dependencies")

    sha = os.environ.get("DEPENDENCY_SNAPSHOT_SHA", "").strip()
    if not sha:
        sha = required_environment("GITHUB_SHA")
    if re.fullmatch(r"[0-9a-fA-F]{40}", sha) is None:
        raise SnapshotError("dependency snapshot SHA must be a 40-character commit SHA")
    ref = os.environ.get("DEPENDENCY_SNAPSHOT_REF", "").strip()
    if not ref:
        ref = required_environment("GITHUB_REF")
    if not ref.startswith("refs/"):
        raise SnapshotError("dependency snapshot ref must be a fully qualified ref")
    repository = required_environment("GITHUB_REPOSITORY")
    if repository.count("/") != 1 or any(
        not component for component in repository.split("/", 1)
    ):
        raise SnapshotError("GITHUB_REPOSITORY must use owner/name form")
    server_url = required_environment("GITHUB_SERVER_URL").rstrip("/")
    run_id = required_environment("GITHUB_RUN_ID")
    run_attempt = required_environment("GITHUB_RUN_ATTEMPT")
    if not run_id.isdecimal() or not run_attempt.isdecimal():
        raise SnapshotError("GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT must be decimal numbers")
    detector_sha = os.environ.get("DEPENDENCY_SNAPSHOT_DETECTOR_SHA", sha).strip()
    if re.fullmatch(r"[0-9a-fA-F]{40}", detector_sha) is None:
        raise SnapshotError(
            "DEPENDENCY_SNAPSHOT_DETECTOR_SHA must be a 40-character commit SHA"
        )

    scanned = os.environ.get("DEPENDENCY_SNAPSHOT_SCANNED")
    if scanned is None:
        scanned = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
        scanned = scanned.replace("+00:00", "Z")
    try:
        parsed_scanned = dt.datetime.fromisoformat(scanned.replace("Z", "+00:00"))
    except ValueError as error:
        raise SnapshotError("snapshot scanned time must use ISO 8601") from error
    if parsed_scanned.tzinfo is None:
        raise SnapshotError("snapshot scanned time must include a timezone")

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
            "version": "2.0.0",
            "url": (
                f"{server_url}/{repository}/blob/{detector_sha.lower()}/"
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


def load_json_document(source: Path, package_resolved: bool) -> dict[str, Any]:
    if package_resolved and source.stat().st_size > MAX_PACKAGE_RESOLVED_BYTES:
        raise SnapshotError(
            f"Package.resolved exceeds the {MAX_PACKAGE_RESOLVED_BYTES}-byte limit"
        )
    with source.open(encoding="utf-8") as source_file:
        document = json.load(
            source_file,
            object_pairs_hook=strict_object,
            parse_constant=reject_json_constant,
        )
    if not isinstance(document, dict):
        raise SnapshotError("dependency input JSON root must be an object")
    return document


def main() -> int:
    arguments = sys.argv[1:]
    transition_mode = bool(
        arguments and arguments[0] == "--verify-package-resolved-transition"
    )
    package_resolved_mode = bool(arguments and arguments[0] == "--package-resolved")
    if transition_mode or package_resolved_mode:
        arguments = arguments[1:]
    if len(arguments) != 2:
        print(
            "usage: generate_dependency_snapshot.py "
            "[--package-resolved <input.json> <snapshot.json> | "
            "--verify-package-resolved-transition <base.json> <head.json> | "
            "<sbom.json> <snapshot.json>]",
            file=sys.stderr,
        )
        return 2

    try:
        if transition_mode:
            base_document = load_json_document(Path(arguments[0]), True)
            head_document = load_json_document(Path(arguments[1]), True)
            verify_package_resolved_transition(base_document, head_document)
            print("dependency-snapshot: lock transition OK")
            return 0

        source = Path(arguments[0])
        destination = Path(arguments[1])
        document = load_json_document(source, package_resolved_mode)
        snapshot = (
            build_package_resolved_snapshot(document)
            if package_resolved_mode
            else build_snapshot(document)
        )
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("w", encoding="utf-8") as destination_file:
            json.dump(snapshot, destination_file, indent=2, sort_keys=True)
            destination_file.write("\n")
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        RecursionError,
        SnapshotError,
    ) as error:
        print(f"dependency-snapshot: {error}", file=sys.stderr)
        return 1

    resolved_count = len(
        snapshot["manifests"]["Package.resolved"]["resolved"]
    )
    print(f"dependency-snapshot: OK ({resolved_count} Swift packages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
