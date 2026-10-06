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


def read_only_validation_job(section: str) -> None:
    permissions = re.search(r"(?m)^    permissions:\n((?:      [\w-]+: \w+\n)+)", section)
    if permissions is None or permissions[1] != "      contents: read\n":
        fail("release verification jobs must remain contents-read-only")
    for forbidden in ("secrets.", "continue-on-error", "persist-credentials: true", "allow-unsafe-pr-checkout"):
        if forbidden in section:
            fail("unsafe release verification job option: " + forbidden)
    if "ref: ${{ github.sha }}" not in section or "persist-credentials: false" not in section:
        fail("release verification must checkout the immutable source without credentials")


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

    preflight = job_section(workflow, "full-preflight")
    read_only_validation_job(preflight)
    if CANDIDATE_CONDITION not in preflight or "test \"$GITHUB_REF\" = refs/heads/main" not in preflight:
        fail("full preflight must be a manual non-publishing main-only gate")
    if "runs-on: xcode-27" not in preflight or preflight.count("bash Scripts/validate_release_candidate.sh") != 2:
        fail("full preflight must bind exact current main before and after Xcode 27 execution")
    command = "bash Scripts/run_local_release_preflight.sh --full"
    if preflight.count(command) != 1 or "--fast" in preflight or "--list" in preflight:
        fail("full preflight must execute the unchanged full gate set")
    execution = preflight.split("- name: Run all fifteen full preflight gates", 1)[-1].split("      - name:", 1)[0]
    if "set -euo pipefail" not in execution or "|| true" in execution or "continue-on-error" in execution:
        fail("full preflight failures must propagate through retained logs")
    candidate_smoke = 'bash Scripts/verify_published_consumer.sh --candidate "$GITHUB_SHA"'
    if candidate_smoke not in preflight or preflight.index(candidate_smoke) > preflight.index("- name: Revalidate exact main after full preflight"):
        fail("candidate consumer source must be prevalidated before the final main identity check")
    for evidence in ("full-preflight-${{ github.sha }}-${{ github.run_attempt }}",
                     ".build/local-release-preflight/identity.txt", ".build/local-release-preflight/run.log",
                     ".build/local-release-preflight/result.txt", ".build/published-consumer/", "if: always()"):
        if evidence not in preflight:
            fail("full preflight must retain exact-source diagnostic evidence")
    if ('PERIPHERY_VERSION: "3.8.0"' not in preflight or
            'PERIPHERY_SHA256: "07d4e286e31dd79164df39097e0b59f533c94badbe18158464a455ea88a166d7"' not in preflight or
            'shasum -a 256 -c -' not in preflight):
        fail("full preflight must retain the pinned checksum-verified Periphery tool")

    consumer = job_section(workflow, "validate-tagged-consumer")
    read_only_validation_job(consumer)
    if TAG_ONLY_CONDITION not in consumer or "bash Scripts/validate_release_ref.sh" not in consumer:
        fail("published consumer validation must bind an annotated exact-main tag")
    if ("runs-on: xcode-27" not in consumer or "--candidate" in consumer or
            'RELEASE_VERSION: ${{ github.ref_name }}' not in consumer or
            'RELEASE_COMMIT: ${{ github.sha }}' not in consumer or
            'bash Scripts/verify_published_consumer.sh "$RELEASE_VERSION" "$RELEASE_COMMIT"' not in consumer):
        fail("publication must validate the actual public tag and exact revision, never a candidate override")

    publication = job_section(workflow, "publish-release")
    if publication.count(TAG_ONLY_CONDITION) != 1:
        fail("publication must have exactly one job-level tag-only condition")
    condition_index = publication.index(TAG_ONLY_CONDITION)
    needs_index = publication.find("needs:")
    if needs_index == -1 or condition_index > needs_index:
        fail("publication tag-only condition must be declared at job level")

    for gate in ["validate-release", "validate-platform-builds", "validate-tagged-consumer"]:
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
