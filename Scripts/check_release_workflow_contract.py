#!/usr/bin/env python3
"""Require manual release validation to remain publication-safe."""

from __future__ import annotations

import re
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parent.parent
WORKFLOW = REPOSITORY / ".github" / "workflows" / "release.yml"
TAG_ONLY_CONDITION = (
    "if: startsWith(github.ref, 'refs/tags/') && (github.event_name == 'push' || (github.event_name == 'workflow_dispatch' && inputs.publish))"
)
REF_CONDITION = "if: github.event_name == 'push' || (github.event_name == 'workflow_dispatch' && inputs.publish)"
CANDIDATE_CONDITION = "if: github.event_name == 'workflow_dispatch' && !inputs.publish"


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

    if not re.search(r"(?ms)^      publish:\n        description:.*?^        type: boolean\n        required: false\n        default: false\n", trigger):
        fail("manual publication requires explicit boolean publish with default false")
    validation = job_section(workflow, "validate-release")
    if validation.count(REF_CONDITION) != 1:
        fail("release-ref validation must have exactly one tag-only condition")
    if CANDIDATE_CONDITION not in validation:
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

    for gate in ["validate-release", "validate-platform-builds"]:
        if "      - " + gate not in publication:
            fail("publication must retain every validation gate")
    if "Revalidate exact release ref before publication" not in publication or "bash Scripts/validate_release_ref.sh" not in publication:
        fail("publication must revalidate the exact current-main tag")
    if ".build/release-artifacts/benchmarks-json-codec.json" not in validation:
        fail("validation must upload the JSON codec benchmark artifact")
    diagnostics = re.search(
        r"(?ms)^      - name: Retain raw benchmark diagnostics\n(?P<body>.*?)(?=^      - name:|\Z)",
        validation,
    )
    if diagnostics is None:
        fail("validation must retain raw benchmark diagnostics")
    body = diagnostics.group("body")
    if "        if: always()\n" not in body:
        fail("raw benchmark diagnostics must survive benchmark failures")
    for required in (
        "uses: actions/upload-artifact@",
        "path: .build/release-artifacts/benchmarks/\n",
        "include-hidden-files: true\n",
        "release-benchmark-diagnostics-${{ github.sha }}-${{ github.run_attempt }}",
    ):
        if required not in body:
            fail("raw benchmark diagnostics must retain both lanes and attempt identity")
    signing = publication.split("artifacts=(", maxsplit=1)[-1].split(")", maxsplit=1)[0]
    if ".release-artifacts/benchmarks-json-codec.json" not in signing:
        fail("publication must sign the JSON codec benchmark artifact")
    assets = publication.split("          files: |", maxsplit=1)[-1]
    asset_lines = {line.strip() for line in assets.splitlines()}
    for suffix in ("", ".sig", ".crt"):
        if f".release-artifacts/benchmarks-json-codec.json{suffix}" not in asset_lines:
            fail("publication must retain the JSON codec benchmark and signatures")

    print("release-workflow-contract: OK (manual validation defaults to no publication; explicit tag publication keeps every gate)")


if __name__ == "__main__":
    validate()
