#!/usr/bin/env python3
"""Audit logical CI coverage and native aggregate checks without changing GitHub.

The current non-strict ruleset permits manual integration, not autonomous native
auto-merge. The latter still requires strict base protection in the coordinator.
Neither ruleset profile proves that a candidate's exact head/base CI succeeded.
"""

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
    "Build and Test (SwiftPM) — Xcode 27.0",
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
AGGREGATE_CONTEXTS = {"CI Required", "Dependabot Merge Ready"}
REPOSITORY = "InnoSquadCorp/InnoNetwork"
GITHUB_ACTIONS_APP = 15368


def fail(message: str) -> None:
    raise SystemExit(f"required-status-checks: {message}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {path}: {error}")


def validate_policy(path: Path, mandatory: set[str] = MANDATORY_CONTEXTS) -> list[dict[str, Any]]:
    document = load_json(path)
    if (not isinstance(document, dict) or type(document.get("schema_version")) is not int
            or document["schema_version"] != 1):
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
        if type(integration_id) is not int or integration_id != GITHUB_ACTIONS_APP:
            fail(f"checks[{index}].integration_id must be GitHub Actions app {GITHUB_ACTIONS_APP}")
        contexts.append(context)
        normalized.append({"context": context, "integration_id": integration_id})

    if len(contexts) != len(set(contexts)):
        fail("policy contains duplicate check contexts")
    missing = sorted(mandatory - set(contexts))
    if missing:
        fail(f"policy omits mandatory contexts: {', '.join(missing)}")
    if mandatory == AGGREGATE_CONTEXTS and set(contexts) != mandatory:
        fail("aggregate policy must contain exactly CI Required and Dependabot Merge Ready")
    return normalized


def validate_ruleset(path: Path, expected: list[dict[str, Any]], require_auto_merge: bool = False) -> None:
    document = load_json(path)
    if not isinstance(document, dict):
        fail(f"{path} must contain a ruleset object")
    if (document.get("source_type") != "Repository" or document.get("source") != REPOSITORY
            or document.get("target") != "branch" or document.get("enforcement") != "active"):
        fail("live ruleset must be active repository-owned branch protection")
    conditions = document.get("conditions")
    if not isinstance(conditions, dict) or not isinstance(conditions.get("ref_name"), dict):
        fail("live ruleset must declare branch conditions")
    refs = conditions["ref_name"]
    if refs.get("include") not in (["~DEFAULT_BRANCH"], ["refs/heads/main"]) or refs.get("exclude") != []:
        fail("live ruleset must cover main without exclusions")
    # Require an unredacted export. A missing bypass list is not an empty list;
    # this static audit does not establish the coordinator token's capabilities.
    if document.get("bypass_actors") != []:
        fail("live ruleset must expose an empty bypass list")
    rules = document.get("rules")
    if not isinstance(rules, list) or not all(isinstance(rule, dict) for rule in rules):
        fail("live ruleset has malformed rules")
    review_rules = [rule for rule in rules if rule.get("type") == "pull_request"]
    if len(review_rules) != 1:
        fail("live ruleset must contain exactly one pull_request rule")
    review = review_rules[0].get("parameters")
    if not isinstance(review, dict) or review.get("required_review_thread_resolution") is not True:
        fail("live ruleset must require resolved review threads")
    approval_count = review.get("required_approving_review_count")
    if type(approval_count) is not int or approval_count < 0:
        fail("live ruleset must declare a valid approval count")
    matching_rules = [
        rule
        for rule in rules
        if isinstance(rule, dict) and rule.get("type") == "required_status_checks"
    ]
    if len(matching_rules) != 1:
        fail("live ruleset must contain exactly one required_status_checks rule")
    parameters = matching_rules[0].get("parameters")
    if not isinstance(parameters, dict):
        fail("live required_status_checks rule has no parameters")
    if parameters.get("strict_required_status_checks_policy") is not require_auto_merge:
        if require_auto_merge:
            fail("autonomous auto-merge requires strict up-to-date base protection; current manual profile stays in standby")
        fail("live ruleset differs from the current non-strict manual-integration profile")

    actual = parameters.get("required_status_checks")
    if not isinstance(actual, list):
        fail("live ruleset has no required_status_checks array")
    if not all(isinstance(item, dict) and isinstance(item.get("context"), str)
               and type(item.get("integration_id")) is int for item in actual):
        fail("live ruleset contains malformed required checks")
    actual_pairs = {(item["context"], item["integration_id"]) for item in actual}
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
    parser.add_argument(
        "--automation-policy", type=Path,
        default=repo_root / ".github" / "automation-required-status-checks.json",
    )
    parser.add_argument(
        "--require-auto-merge", action="store_true",
        help="Audit strict native protection as an additional auto-merge prerequisite, never enable it.",
    )
    args = parser.parse_args()

    logical = validate_policy(args.policy)
    expected = validate_policy(args.automation_policy, AGGREGATE_CONTEXTS)
    if args.require_auto_merge and args.ruleset_json is None:
        fail("--require-auto-merge needs a complete --ruleset-json export")
    if args.ruleset_json is not None:
        validate_ruleset(args.ruleset_json, expected, args.require_auto_merge)
    suffix = " and live ruleset" if args.ruleset_json is not None else ""
    print(f"required-status-checks: OK ({len(logical)} logical checks, {len(expected)} native aggregate checks{suffix})")
    if args.ruleset_json is not None:
        print("Ruleset audit only: exact-head/base CI and release approval remain separate.")
        if not args.require_auto_merge:
            print("Current non-strict profile: autonomous native auto-merge remains in standby.")


if __name__ == "__main__":
    main()
