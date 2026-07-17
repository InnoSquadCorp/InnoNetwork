#!/usr/bin/env python3
"""Fixture tests for the repeated macro-build baseline validator."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
from copy import deepcopy
from pathlib import Path
from types import ModuleType


REPOSITORY = Path(__file__).resolve().parents[2]
VALIDATOR = REPOSITORY / "Scripts" / "check_macro_build_baseline_contract.py"
SWIFTPM_BASELINE = (
    REPOSITORY
    / "Benchmarks"
    / "MacroBuildBaselines"
    / "swiftpm-2026-07-18.json"
)


def load_validator() -> ModuleType:
    sys.dont_write_bytecode = True
    specification = importlib.util.spec_from_file_location(
        "macro_build_baseline_contract", VALIDATOR
    )
    if specification is None or specification.loader is None:
        raise SystemExit("Unable to load macro build baseline validator")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def expect_failure(
    validator: ModuleType,
    payload: dict[str, object],
    expected: str,
) -> None:
    with tempfile.TemporaryDirectory(prefix="macro-build-baseline-test-") as directory:
        path = Path(directory) / "swiftpm.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        try:
            validator.validate_baseline("swiftpm", path)
        except SystemExit as error:
            if expected not in str(error):
                raise AssertionError(f"wanted {expected!r}, got {error!r}") from error
        else:
            raise AssertionError(f"invalid baseline unexpectedly passed: {expected}")


def main() -> None:
    validator = load_validator()
    validator.main()
    source = json.loads(SWIFTPM_BASELINE.read_text(encoding="utf-8"))

    short_repeat = deepcopy(source)
    short_repeat["repeat"] = 4
    expect_failure(
        validator,
        short_repeat,
        "repeat must be an integer of at least 5",
    )

    missing_phase = deepcopy(source)
    missing_phase["results"].pop()
    expect_failure(
        validator,
        missing_phase,
        "is missing phases",
    )

    invalid_median = deepcopy(source)
    invalid_median["results"][0]["median_seconds"] += 1
    expect_failure(
        validator,
        invalid_median,
        "median_seconds does not match",
    )

    invalid_sample = deepcopy(source)
    invalid_sample["results"][0]["samples_seconds"][0] = 0
    expect_failure(
        validator,
        invalid_sample,
        "must be finite and positive",
    )

    duplicate_phase = deepcopy(source)
    duplicate_phase["results"].append(deepcopy(duplicate_phase["results"][0]))
    expect_failure(
        validator,
        duplicate_phase,
        "contains duplicate phase",
    )
    print("Macro build baseline contract fixture tests passed.")


if __name__ == "__main__":
    main()
