#!/usr/bin/env python3
"""Fixture tests for the release workflow safety contract."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path
from types import ModuleType


REPOSITORY = Path(__file__).resolve().parents[2]
VALIDATOR = REPOSITORY / "Scripts" / "check_release_workflow_contract.py"
WORKFLOW = REPOSITORY / ".github" / "workflows" / "release.yml"


def load_validator() -> ModuleType:
    sys.dont_write_bytecode = True
    specification = importlib.util.spec_from_file_location(
        "release_workflow_contract", VALIDATOR
    )
    if specification is None or specification.loader is None:
        raise SystemExit("Unable to load release workflow contract validator")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def expect_failure(validator: ModuleType, workflow: str, expected: str) -> None:
    with tempfile.TemporaryDirectory(prefix="release-workflow-test-") as directory:
        path = Path(directory) / "release.yml"
        path.write_text(workflow, encoding="utf-8")
        try:
            validator.validate(path)
        except SystemExit as error:
            if expected not in str(error):
                raise AssertionError(f"wanted {expected!r}, got {error!r}") from error
        else:
            raise AssertionError(f"unsafe release workflow passed: {expected}")


def main() -> None:
    validator = load_validator()
    validator.validate()
    workflow = WORKFLOW.read_text(encoding="utf-8")

    expect_failure(validator, workflow.replace("        if: always()\n", "        if: success()\n", 1),
                   "must survive benchmark failures")
    expect_failure(validator, workflow.replace("path: .build/release-artifacts/benchmarks/\n", "path: results.json\n", 1),
                   "must retain both lanes")
    expect_failure(validator, workflow.replace("${{ github.sha }}-${{ github.run_attempt }}", "latest", 1),
                   "must retain both lanes")

    expect_failure(
        validator,
        workflow.replace("  workflow_dispatch:\n", "", 1),
        "must support workflow_dispatch",
    )
    expect_failure(
        validator,
        workflow.replace(
            "        " + validator.REF_CONDITION + "\n",
            "",
            1,
        ),
        "release-ref validation",
    )
    expect_failure(
        validator,
        workflow.replace(
            "        run: bash Scripts/prepare_release_artifacts.sh .build/release-artifacts\n",
            "",
            1,
        ),
        "exact release artifact manifest",
    )
    for old, new, reason in [
        ("default: false", "default: true", "default false"),
        ("type: boolean", "type: string", "explicit boolean"),
        (validator.CANDIDATE_CONDITION, "if: github.event_name == 'workflow_dispatch'", "workflow_dispatch-only"),
        ("      - validate-platform-builds", "", "every validation gate"),
        ("      - name: Revalidate exact release ref before publication", "      - name: Removed ref validation", "revalidate the exact current-main tag"),
    ]:
        expect_failure(validator, workflow.replace(old, new, 1), reason)
    publish_condition = (
        "    " + validator.TAG_ONLY_CONDITION + "\n"
    )
    publish_start = workflow.index("  publish-release:\n")
    unsafe_publication = (
        workflow[:publish_start]
        + workflow[publish_start:].replace(publish_condition, "", 1)
    )
    expect_failure(validator, unsafe_publication, "publication must have")
    expect_failure(
        validator,
        workflow.replace("            .build/release-artifacts/benchmarks-json-codec.json\n", "", 1),
        "must upload the JSON codec",
    )
    expect_failure(
        validator,
        workflow.replace("            .release-artifacts/benchmarks-json-codec.json\n", "", 1),
        "must sign the JSON codec",
    )
    expect_failure(
        validator,
        workflow.replace("            .release-artifacts/benchmarks-json-codec.json.sig\n", "", 1),
        "must retain the JSON codec",
    )
    expect_failure(
        validator,
        "".join(workflow.rsplit("            .release-artifacts/benchmarks-json-codec.json\n", 1)),
        "must retain the JSON codec",
    )

    for old, new, reason in [
        ("      - validate-tagged-consumer", "", "every validation gate"),
        ("bash Scripts/run_local_release_preflight.sh --full", "bash Scripts/run_local_release_preflight.sh --fast", "full gate set"),
        ('test "$GITHUB_REF" = refs/heads/main', 'true', "main-only gate"),
        ('bash Scripts/verify_published_consumer.sh "$RELEASE_VERSION" "$RELEASE_COMMIT"',
         'bash Scripts/verify_published_consumer.sh --candidate "$RELEASE_COMMIT"', "never a candidate override"),
        ('full-preflight-${{ github.sha }}-${{ github.run_attempt }}', 'full-preflight-latest', "exact-source diagnostic evidence"),
        ('PERIPHERY_SHA256: "07d4e286e31dd79164df39097e0b59f533c94badbe18158464a455ea88a166d7"',
         'PERIPHERY_SHA256: "unverified"', "checksum-verified Periphery"),
    ]:
        expect_failure(validator, workflow.replace(old, new, 1), reason)
    for name in ("full-preflight", "validate-tagged-consumer"):
        section = validator.job_section(workflow, name)
        for old, new, reason in [
            ("      contents: read", "      contents: write", "contents-read-only"),
            ("          ref: ${{ github.sha }}", "          ref: main", "immutable source"),
            ("          persist-credentials: false", "          persist-credentials: true", "unsafe release verification"),
        ]:
            expect_failure(validator, workflow.replace(section, section.replace(old, new, 1)), reason)
    preflight = validator.job_section(workflow, "full-preflight")
    broken = preflight.replace("bash Scripts/validate_release_candidate.sh", "true", 1)
    expect_failure(validator, workflow.replace(preflight, broken), "before and after")
    broken = preflight.replace(
        "      - name: Run all fifteen full preflight gates\n        run: |\n          set -euo pipefail",
        "      - name: Run all fifteen full preflight gates\n        run: |\n          set -eu",
    )
    expect_failure(validator, workflow.replace(preflight, broken), "failures must propagate")

    subprocess.run([sys.executable, "-B", str(REPOSITORY / "Scripts/tests/test_verify_published_consumer.py")], check=True)

    print("Release workflow contract fixture tests passed.")


if __name__ == "__main__":
    main()
