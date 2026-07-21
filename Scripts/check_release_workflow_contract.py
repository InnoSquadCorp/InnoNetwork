#!/usr/bin/env python3
"""Require manual release validation to remain publication-safe."""

from __future__ import annotations

import re
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parent.parent
WORKFLOW = REPOSITORY / ".github" / "workflows" / "release.yml"
TAG_ONLY_CONDITION = (
    "if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')"
)


def fail(message: str) -> None:
    raise SystemExit(f"release-workflow-contract: {message}")


def job_section(workflow: str, job: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(job)}:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)",
        workflow,
    )
    if match is None:
        fail(f"missing {job} job")
    return match.group(0)


def validate(path: Path = WORKFLOW) -> None:
    try:
        workflow = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read {path}: {error}")

    trigger = workflow.split("concurrency:", maxsplit=1)[0]
    if "  workflow_dispatch:\n" not in trigger:
        fail("Release must support workflow_dispatch validation")

    validation = job_section(workflow, "validate-release")
    if validation.count(TAG_ONLY_CONDITION) != 1:
        fail("release-ref validation must have exactly one tag-only condition")
    if "if: github.event_name == 'workflow_dispatch'" not in validation:
        fail("release candidate validation must be workflow_dispatch-only")
    if "bash Scripts/validate_release_candidate.sh" not in validation:
        fail("manual validation must invoke validate_release_candidate.sh")
    if (
        "bash Scripts/prepare_release_artifacts.sh .build/release-artifacts"
        not in validation
    ):
        fail("validation must prepare the exact release artifact manifest")

    publication = job_section(workflow, "publish-release")
    if publication.count(TAG_ONLY_CONDITION) != 1:
        fail("publication must have exactly one job-level tag-only condition")
    condition_index = publication.index(TAG_ONLY_CONDITION)
    needs_index = publication.find("needs:")
    if needs_index == -1 or condition_index > needs_index:
        fail("publication tag-only condition must be declared at job level")

    print("release-workflow-contract: OK (manual validation cannot publish)")


if __name__ == "__main__":
    validate()
