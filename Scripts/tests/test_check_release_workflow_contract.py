#!/usr/bin/env python3
"""Fixture tests for the release workflow safety contract."""

from __future__ import annotations

import importlib.util
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

    expect_failure(
        validator,
        workflow.replace("  workflow_dispatch:\n", "", 1),
        "must support workflow_dispatch",
    )
    expect_failure(
        validator,
        workflow.replace(
            "        if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')\n",
            "",
            1,
        ),
        "release-ref validation",
    )
    publish_condition = (
        "    if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')\n"
    )
    publish_start = workflow.index("  publish-release:\n")
    unsafe_publication = (
        workflow[:publish_start]
        + workflow[publish_start:].replace(publish_condition, "", 1)
    )
    expect_failure(validator, unsafe_publication, "publication must have")

    print("Release workflow contract fixture tests passed.")


if __name__ == "__main__":
    main()
