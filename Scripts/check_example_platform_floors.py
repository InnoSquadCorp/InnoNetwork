#!/usr/bin/env python3
"""Validate independent example floors and shared builder adoption."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


PLATFORM_PATTERN = re.compile(
    r"\.(iOS|macOS|tvOS|watchOS|visionOS)\(\.v([A-Za-z0-9_]+)\)"
)
WORKFLOW_PATHS = (
    Path(".github/workflows/ci.yml"),
    Path(".github/workflows/release.yml"),
)
BUILDER_INVOCATION = "bash Scripts/build_consumer_examples.sh"


def platform_floors(manifest: Path) -> dict[str, str]:
    source = manifest.read_text(encoding="utf-8")
    marker = source.find("platforms:")
    if marker < 0:
        raise ValueError("missing platforms declaration")
    opening = source.find("[", marker)
    closing = source.find("]", opening)
    if opening < 0 or closing < 0:
        raise ValueError("malformed platforms declaration")

    matches = PLATFORM_PATTERN.findall(source[opening : closing + 1])
    floors = dict(matches)
    if not matches or len(floors) != len(matches):
        raise ValueError("missing or duplicate Apple platform floor")
    return floors


def main() -> int:
    repo_root = Path(
        os.environ.get(
            "INNO_EXAMPLE_PLATFORM_ROOT",
            Path(__file__).resolve().parent.parent,
        )
    )
    root_manifest = repo_root / "Package.swift"
    try:
        expected = platform_floors(root_manifest)
    except ValueError as error:
        print(f"example-platform-floors: {root_manifest}: {error}", file=sys.stderr)
        return 1

    manifests = sorted((repo_root / "Examples").glob("*/Package.swift"))
    if not manifests:
        print("example-platform-floors: no independent example manifests found", file=sys.stderr)
        return 1

    failures: list[str] = []
    for workflow_path in WORKFLOW_PATHS:
        absolute_path = repo_root / workflow_path
        if not absolute_path.is_file():
            failures.append(f"{workflow_path}: missing workflow")
            continue
        source = absolute_path.read_text(encoding="utf-8")
        invocation_count = source.count(BUILDER_INVOCATION)
        if invocation_count != 1:
            failures.append(
                f"{workflow_path}: expected one shared example builder invocation, "
                f"found {invocation_count}"
            )

    for manifest in manifests:
        try:
            actual = platform_floors(manifest)
        except ValueError as error:
            failures.append(f"{manifest.relative_to(repo_root)}: {error}")
            continue
        if actual != expected:
            failures.append(
                f"{manifest.relative_to(repo_root)}: expected {expected}, found {actual}"
            )

    if failures:
        print("example-platform-floors: FAILED", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print(
        "example-platform-floors: OK "
        f"({len(manifests)} manifests match {expected} and both workflows use the shared builder)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
