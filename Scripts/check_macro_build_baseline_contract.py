#!/usr/bin/env python3
"""Validate committed repeated macro-consumer build baselines."""

from __future__ import annotations

import json
import math
import re
import statistics
from datetime import date
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parent.parent
BASELINES = REPOSITORY / "Benchmarks" / "MacroBuildBaselines"
MANIFEST = BASELINES / "manifest.json"
DOCUMENTATION = REPOSITORY / "Benchmarks" / "MacroBuilds.md"
EXPECTED_PHASES = {
    ("core-only", "clean"): 0,
    ("core-only", "noop-incremental"): 0,
    ("macros-0", "clean"): 0,
    ("macros-0", "noop-incremental"): 0,
    ("macros-10", "clean"): 10,
    ("macros-10", "noop-incremental"): 10,
    ("macros-10", "endpoint-edit"): 10,
    ("macros-50", "clean"): 50,
    ("macros-50", "noop-incremental"): 50,
    ("macros-50", "endpoint-edit"): 50,
    ("macros-200", "clean"): 200,
    ("macros-200", "noop-incremental"): 200,
    ("macros-200", "endpoint-edit"): 200,
}


def fail(message: str) -> None:
    raise SystemExit(f"macro-build-baseline-contract: {message}")


def load_object(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {path.relative_to(REPOSITORY)}: {error}")
    if not isinstance(value, dict):
        fail(f"{path.relative_to(REPOSITORY)} must contain a JSON object")
    return value


def positive_number(value: object, label: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        fail(f"{label} must be numeric")
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        fail(f"{label} must be finite and positive")
    return number


def validate_baseline(driver: str, path: Path) -> dict[tuple[str, str], float]:
    payload = load_object(path)
    if payload.get("schemaVersion") != 1:
        fail(f"{path.name} must use schemaVersion 1")
    if payload.get("driver") != driver:
        fail(f"{path.name} driver must be {driver!r}")
    repeat = payload.get("repeat")
    if not isinstance(repeat, int) or isinstance(repeat, bool) or repeat < 5:
        fail(f"{path.name} repeat must be an integer of at least 5")
    results = payload.get("results")
    if not isinstance(results, list):
        fail(f"{path.name} results must be an array")

    observed: set[tuple[str, str]] = set()
    medians: dict[tuple[str, str], float] = {}
    for index, result in enumerate(results):
        label = f"{path.name} results[{index}]"
        if not isinstance(result, dict):
            fail(f"{label} must be an object")
        if result.get("driver") != driver:
            fail(f"{label}.driver must be {driver!r}")
        profile = result.get("profile")
        phase = result.get("phase")
        if not isinstance(profile, str) or not isinstance(phase, str):
            fail(f"{label} must contain string profile and phase values")
        key = (profile, phase)
        if key in observed:
            fail(f"{path.name} contains duplicate phase {profile}/{phase}")
        observed.add(key)
        if key not in EXPECTED_PHASES:
            fail(f"{path.name} contains unexpected phase {profile}/{phase}")
        if result.get("endpoint_count") != EXPECTED_PHASES[key]:
            fail(f"{label}.endpoint_count does not match {profile}")
        samples = result.get("samples_seconds")
        if not isinstance(samples, list) or len(samples) != repeat:
            fail(f"{label}.samples_seconds must contain exactly {repeat} values")
        numeric_samples = [
            positive_number(value, f"{label}.samples_seconds") for value in samples
        ]
        median = positive_number(result.get("median_seconds"), f"{label}.median_seconds")
        expected_median = statistics.median(numeric_samples)
        if not math.isclose(median, expected_median, rel_tol=0, abs_tol=1e-9):
            fail(f"{label}.median_seconds does not match the sample median")
        medians[key] = median

    missing = set(EXPECTED_PHASES) - observed
    if missing:
        rendered = ", ".join(f"{profile}/{phase}" for profile, phase in sorted(missing))
        fail(f"{path.name} is missing phases: {rendered}")
    return medians


def validate_documentation(
    manifest: dict[str, object],
    baseline_medians: dict[str, dict[tuple[str, str], float]],
) -> None:
    try:
        documentation = DOCUMENTATION.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read {DOCUMENTATION.relative_to(REPOSITORY)}: {error}")
    required_values = [
        manifest["capturedAt"],
        manifest["repositoryRevision"],
        *manifest["environment"].values(),
        *manifest["baselines"].values(),
    ]
    for value in required_values:
        if value not in documentation:
            fail(f"MacroBuilds.md is missing provenance value {value!r}")

    labels = {
        "core-only": "Core only (`traits: []`)",
        "macros-0": "Macros, 0 endpoints",
        "macros-10": "Macros, 10 endpoints",
        "macros-50": "Macros, 50 endpoints",
        "macros-200": "Macros, 200 endpoints",
    }
    for driver, medians in baseline_medians.items():
        for profile, label in labels.items():
            clean = medians[(profile, "clean")]
            noop = medians[(profile, "noop-incremental")]
            edit = medians.get((profile, "endpoint-edit"))
            edit_text = "—" if edit is None else f"{edit:.2f} s"
            row = f"| {label} | {clean:.2f} s | {noop:.2f} s | {edit_text} |"
            if row not in documentation:
                fail(f"MacroBuilds.md is missing the {driver} median row: {row}")


def main() -> None:
    manifest = load_object(MANIFEST)
    if manifest.get("schemaVersion") != 1:
        fail("manifest.json must use schemaVersion 1")
    captured_at = manifest.get("capturedAt")
    if not isinstance(captured_at, str):
        fail("manifest.json capturedAt must be an ISO date")
    try:
        date.fromisoformat(captured_at)
    except ValueError:
        fail("manifest.json capturedAt must be an ISO date")
    revision = manifest.get("repositoryRevision")
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        fail("manifest.json repositoryRevision must be a full lowercase Git SHA")
    environment = manifest.get("environment")
    expected_environment = {"hardware", "macOS", "xcode", "swift"}
    if not isinstance(environment, dict) or set(environment) != expected_environment:
        fail("manifest.json environment must name hardware, macOS, xcode, and swift")
    if not all(isinstance(value, str) and value.strip() for value in environment.values()):
        fail("manifest.json environment values must be non-empty strings")
    baselines = manifest.get("baselines")
    if not isinstance(baselines, dict) or set(baselines) != {"swiftpm", "xcode"}:
        fail("manifest.json must name exactly the swiftpm and xcode baselines")
    baseline_medians: dict[str, dict[tuple[str, str], float]] = {}
    for driver in ("swiftpm", "xcode"):
        filename = baselines.get(driver)
        if not isinstance(filename, str) or Path(filename).name != filename:
            fail(f"manifest.json {driver} baseline must be a local filename")
        baseline_medians[driver] = validate_baseline(driver, BASELINES / filename)
    validate_documentation(manifest, baseline_medians)
    print("macro-build-baseline-contract: OK (2 drivers, 5 repeats, 13 phases each)")


if __name__ == "__main__":
    main()
