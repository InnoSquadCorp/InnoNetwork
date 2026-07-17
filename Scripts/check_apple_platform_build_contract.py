#!/usr/bin/env python3
"""Keep Package.swift platform floors and every release build tuple aligned."""

from __future__ import annotations

import os
import pathlib
import re
import sys


PLATFORM_PATTERN = re.compile(
    r"\.(iOS|macOS|tvOS|watchOS|visionOS)\(\.v([A-Za-z0-9_]+)\)"
)
PLATFORM_ORDER = ("macOS", "iOS", "tvOS", "watchOS", "visionOS")


def fail(message: str) -> None:
    print(f"apple-platform-build-contract: {message}", file=sys.stderr)
    raise SystemExit(1)


def package_floors(repo_root: pathlib.Path) -> dict[str, str]:
    manifest_path = repo_root / "Package.swift"
    source = manifest_path.read_text(encoding="utf-8")
    marker = source.find("platforms:")
    opening = source.find("[", marker)
    closing = source.find("]", opening)
    if marker < 0 or opening < 0 or closing < 0:
        fail("Package.swift has no readable platforms declaration")

    matches = PLATFORM_PATTERN.findall(source[opening : closing + 1])
    floors = dict(matches)
    expected_names = set(PLATFORM_ORDER)
    if len(matches) != len(floors) or set(floors) != expected_names:
        fail(
            "Package.swift must declare each supported Apple platform exactly once"
        )
    return floors


def triple_version(swift_version: str) -> str:
    normalized = swift_version.replace("_", ".")
    return normalized if "." in normalized else f"{normalized}.0"


def extract_job(source: str, start: str, following: str, path: str) -> str:
    start_marker = f"  {start}:"
    following_marker = f"  {following}:"
    start_index = source.find(start_marker)
    end_index = source.find(following_marker, start_index + len(start_marker))
    if start_index < 0 or end_index < 0:
        fail(f"{path} is missing the {start} job boundary")
    return source[start_index:end_index]


def require_sequence(
    actual: list[str], expected: list[str], path: str, field: str
) -> None:
    if actual != expected:
        fail(f"{path} {field} mismatch: expected {expected}, found {actual}")


def validate_workflow(
    repo_root: pathlib.Path,
    relative_path: str,
    start_job: str,
    following_job: str,
    expected_rows: list[dict[str, str]],
) -> None:
    source = (repo_root / relative_path).read_text(encoding="utf-8")
    job = extract_job(source, start_job, following_job, relative_path)

    require_sequence(
        re.findall(r'^\s*- destination: "([^"]+)"', job, re.MULTILINE),
        [row["destination"] for row in expected_rows if "destination" in row],
        relative_path,
        "destinations",
    )
    require_sequence(
        re.findall(r'^\s*- triple: "([^"]+)"', job, re.MULTILINE),
        [row["triple"] for row in expected_rows if "triple" in row],
        relative_path,
        "triples",
    )
    for field in ("runtime", "sdk", "builder"):
        require_sequence(
            re.findall(rf'^\s+{field}: "([^"]+)"', job, re.MULTILINE),
            [row[field] for row in expected_rows],
            relative_path,
            field,
        )


def validate_local_preflight(
    repo_root: pathlib.Path, expected_rows: list[dict[str, str]]
) -> None:
    relative_path = "Scripts/run_local_release_preflight.sh"
    source = (repo_root / relative_path).read_text(encoding="utf-8")
    match = re.search(
        r"^run_apple_platform_builds\(\) \{(?P<body>.*?)^\}",
        source,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        fail(f"{relative_path} is missing run_apple_platform_builds")
    body = match.group("body")

    destinations = re.findall(r"-destination\s+['\"]([^'\"]+)['\"]", body)
    require_sequence(
        destinations,
        [row["destination"] for row in expected_rows if "destination" in row],
        relative_path,
        "destinations",
    )

    expected_cross_rows = [row for row in expected_rows if "triple" in row]
    actual_triples = re.findall(
        r"(?:arm64|arm64_32)-apple-(?:tvos|watchos|xros)[0-9.]+", body
    )
    require_sequence(
        actual_triples,
        [row["triple"] for row in expected_cross_rows],
        relative_path,
        "triples",
    )
    for row in expected_cross_rows:
        pattern = re.compile(
            rf"\b{re.escape(row['runtime'])}\s+"
            rf"{re.escape(row['sdk'])}\s+{re.escape(row['triple'])}\b"
        )
        if len(pattern.findall(body)) != 1:
            fail(
                f"{relative_path} must invoke exactly one "
                f"{row['runtime']} / {row['sdk']} / {row['triple']} build"
            )


def validate_cross_build_helper(
    repo_root: pathlib.Path, expected_rows: list[dict[str, str]]
) -> None:
    relative_path = "Scripts/build_apple_platform_targets.sh"
    source = (repo_root / relative_path).read_text(encoding="utf-8")
    actual = re.findall(r'"((?:tvOS|watchOS|visionOS):[^"]+)"', source)
    expected = [
        f"{row['runtime']}:{row['sdk']}:{row['triple']}"
        for row in expected_rows
        if "triple" in row
    ]
    require_sequence(actual, expected, relative_path, "allowed tuples")


def main() -> None:
    repo_root = pathlib.Path(
        os.environ.get(
            "INNO_APPLE_PLATFORM_CONTRACT_ROOT",
            pathlib.Path(__file__).resolve().parent.parent,
        )
    )
    floors = package_floors(repo_root)
    expected_rows = [
        {
            "destination": "platform=macOS",
            "runtime": "macOS",
            "sdk": "macosx",
            "builder": "xcodebuild",
        },
        {
            "destination": "generic/platform=iOS Simulator",
            "runtime": "iOS",
            "sdk": "iphonesimulator",
            "builder": "xcodebuild",
        },
        {
            "triple": f"arm64-apple-tvos{triple_version(floors['tvOS'])}",
            "runtime": "tvOS",
            "sdk": "appletvos",
            "builder": "swiftpm-cross",
        },
        {
            "triple": f"arm64_32-apple-watchos{triple_version(floors['watchOS'])}",
            "runtime": "watchOS",
            "sdk": "watchos",
            "builder": "swiftpm-cross",
        },
        {
            "triple": f"arm64-apple-xros{triple_version(floors['visionOS'])}",
            "runtime": "visionOS",
            "sdk": "xros",
            "builder": "swiftpm-cross",
        },
    ]

    validate_workflow(
        repo_root,
        ".github/workflows/ci.yml",
        "apple-platform-build-smoke",
        "consumer-smoke",
        expected_rows,
    )
    validate_workflow(
        repo_root,
        ".github/workflows/release.yml",
        "validate-platform-builds",
        "publish-release",
        expected_rows,
    )
    validate_local_preflight(repo_root, expected_rows)
    validate_cross_build_helper(repo_root, expected_rows)

    floor_summary = ", ".join(
        f"{platform} {floors[platform]}" for platform in PLATFORM_ORDER
    )
    print(
        "apple-platform-build-contract: OK "
        f"({floor_summary}; CI, release, local, and helper aligned)"
    )


if __name__ == "__main__":
    main()
