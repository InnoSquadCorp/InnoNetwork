#!/usr/bin/env python3
"""Validate the version-controlled and live GitHub required-check contracts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


MANDATORY_CONTEXTS = {
    "Dependency Review",
    "Lint (swift-format)",
    "Lint (Periphery)",
    "Build and Test (SwiftPM) — Xcode 26.0.1",
    "Test (Bounded Target Shards) — Xcode 26.0.1",
    "Docs / Contract Sync",
    "Consumer Smoke",
    "Benchmark Smoke",
    "Apple Platform Build Smoke (platform=macOS, macOS, macosx, xcodebuild)",
    "Apple Platform Build Smoke (generic/platform=iOS Simulator, iOS, iphonesimulator, xcodebuild)",
    "Apple Platform Build Smoke (arm64-apple-tvos16.0, tvOS, appletvos, swiftpm-cross)",
    "Apple Platform Build Smoke (arm64_32-apple-watchos9.0, watchOS, watchos, swiftpm-cross)",
    "Apple Platform Build Smoke (arm64-apple-xros1.0, visionOS, xros, swiftpm-cross)",
    "CodeQL / Swift (swift)",
}


def fail(message: str) -> None:
    raise SystemExit(f"required-status-checks: {message}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {path}: {error}")


def validate_policy(path: Path) -> list[dict[str, Any]]:
    document = load_json(path)
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        fail(f"{path} must use schema_version 1")
    if set(document) != {"schema_version", "checks"}:
        fail(f"{path} contains unknown top-level fields")
    checks = document.get("checks")
    if not isinstance(checks, list) or not checks:
        fail(f"{path} must contain a non-empty checks array")

    normalized: list[dict[str, Any]] = []
    contexts: list[str] = []
    for index, check in enumerate(checks):
        if not isinstance(check, dict) or set(check) != {"context", "integration_id"}:
            fail(f"checks[{index}] must contain only context and integration_id")
        context = check.get("context")
        integration_id = check.get("integration_id")
        if not isinstance(context, str) or not context.strip():
            fail(f"checks[{index}].context must be a non-empty string")
        if not isinstance(integration_id, int) or isinstance(integration_id, bool) or integration_id <= 0:
            fail(f"checks[{index}].integration_id must be a positive integer")
        contexts.append(context)
        normalized.append({"context": context, "integration_id": integration_id})

    if len(contexts) != len(set(contexts)):
        fail("policy contains duplicate check contexts")
    missing = sorted(MANDATORY_CONTEXTS - set(contexts))
    if missing:
        fail(f"policy omits mandatory contexts: {', '.join(missing)}")
    return normalized


def validate_ruleset(path: Path, expected: list[dict[str, Any]]) -> None:
    document = load_json(path)
    if not isinstance(document, dict):
        fail(f"{path} must contain a ruleset object")
    matching_rules = [
        rule
        for rule in document.get("rules", [])
        if isinstance(rule, dict) and rule.get("type") == "required_status_checks"
    ]
    if len(matching_rules) != 1:
        fail("live ruleset must contain exactly one required_status_checks rule")
    parameters = matching_rules[0].get("parameters")
    if not isinstance(parameters, dict):
        fail("live required_status_checks rule has no parameters")
    if parameters.get("strict_required_status_checks_policy") is not True:
        fail("live ruleset must require the branch to be up to date")

    actual = parameters.get("required_status_checks")
    if not isinstance(actual, list):
        fail("live ruleset has no required_status_checks array")
    actual_pairs = {(item.get("context"), item.get("integration_id")) for item in actual if isinstance(item, dict)}
    expected_pairs = {(item["context"], item["integration_id"]) for item in expected}
    if len(actual_pairs) != len(actual):
        fail("live ruleset contains malformed or duplicate required checks")
    if actual_pairs != expected_pairs:
        missing = sorted(context for context, app_id in expected_pairs - actual_pairs)
        unexpected = sorted(context for context, app_id in actual_pairs - expected_pairs)
        details = []
        if missing:
            details.append(f"missing: {', '.join(missing)}")
        if unexpected:
            details.append(f"unexpected: {', '.join(unexpected)}")
        fail(f"live ruleset differs from policy ({'; '.join(details)})")


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--policy",
        type=Path,
        default=repo_root / ".github" / "required-status-checks.json",
    )
    parser.add_argument("--ruleset-json", type=Path)
    args = parser.parse_args()

    expected = validate_policy(args.policy)
    if args.ruleset_json is not None:
        validate_ruleset(args.ruleset_json, expected)
    suffix = " and live ruleset" if args.ruleset_json is not None else ""
    print(f"required-status-checks: OK ({len(expected)} policy checks{suffix})")


if __name__ == "__main__":
    main()
