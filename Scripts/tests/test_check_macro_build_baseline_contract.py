#!/usr/bin/env python3
"""Fixture tests for the repeated macro-build baseline validator."""

from __future__ import annotations

import importlib.util
import json
import subprocess
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


def run_git(repository: Path, *arguments: str) -> str:
    process = subprocess.run(
        ["git", *arguments],
        cwd=repository,
        capture_output=True,
        check=True,
        text=True,
    )
    return process.stdout.strip()


def expect_provenance_failure(
    validator: ModuleType,
    revision: str,
    tree: str,
    repository: Path,
    expected: str,
) -> None:
    try:
        validator.validate_repository_provenance(revision, tree, repository)
    except SystemExit as error:
        if expected not in str(error):
            raise AssertionError(f"wanted {expected!r}, got {error!r}") from error
    else:
        raise AssertionError(f"invalid provenance unexpectedly passed: {expected}")


def validate_provenance_fixtures(validator: ModuleType) -> None:
    with tempfile.TemporaryDirectory(prefix="macro-build-provenance-test-") as directory:
        repository = Path(directory)
        run_git(repository, "init", "--quiet")
        run_git(repository, "config", "user.name", "Fixture")
        run_git(repository, "config", "user.email", "fixture@example.com")
        source = repository / "source.txt"
        source.write_text("baseline\n", encoding="utf-8")
        run_git(repository, "add", "source.txt")
        run_git(repository, "commit", "--quiet", "-m", "baseline")
        revision = run_git(repository, "rev-parse", "HEAD")
        tree = run_git(repository, "rev-parse", "HEAD^{tree}")

        source.write_text("head\n", encoding="utf-8")
        run_git(repository, "commit", "--quiet", "-am", "head")
        validator.validate_repository_provenance(revision, tree, repository)
        expect_provenance_failure(
            validator,
            revision,
            "0" * 40,
            repository,
            "does not match",
        )

        run_git(repository, "checkout", "--quiet", "--orphan", "unrelated")
        run_git(repository, "rm", "--quiet", "-f", "source.txt")
        unrelated = repository / "unrelated.txt"
        unrelated.write_text("unrelated\n", encoding="utf-8")
        run_git(repository, "add", "unrelated.txt")
        run_git(repository, "commit", "--quiet", "-m", "unrelated")
        expect_provenance_failure(
            validator,
            revision,
            tree,
            repository,
            "is not an ancestor of HEAD",
        )


def main() -> None:
    validator = load_validator()
    validator.main()
    validate_provenance_fixtures(validator)
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
