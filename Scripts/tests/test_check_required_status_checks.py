#!/usr/bin/env python3
"""Offline native-ruleset audit fixtures; no repository setting writes."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "Scripts" / "check_required_status_checks.py"
LOGICAL = json.loads((ROOT / ".github" / "required-status-checks.json").read_text())
AGGREGATES = json.loads((ROOT / ".github" / "automation-required-status-checks.json").read_text())


def ruleset() -> dict:
    return {
        "source_type": "Repository", "source": "InnoSquadCorp/InnoNetwork",
        "target": "branch", "enforcement": "active", "bypass_actors": [],
        "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
        "rules": [
            {"type": "required_status_checks", "parameters": {
                "strict_required_status_checks_policy": False,
                "required_status_checks": copy.deepcopy(AGGREGATES["checks"]),
            }},
            {"type": "pull_request", "parameters": {
                "required_review_thread_resolution": True,
                "required_approving_review_count": 0,
            }},
        ],
    }


class RequiredCheckTests(unittest.TestCase):
    def run_checker(self, document=None, policy=None, automation=None, extra=()):
        with tempfile.TemporaryDirectory() as directory:
            arguments = []
            for name, flag, value in (
                ("ruleset", "--ruleset-json", document),
                ("policy", "--policy", policy),
                ("automation", "--automation-policy", automation),
            ):
                if value is not None:
                    path = Path(directory) / (name + ".json")
                    path.write_text(json.dumps(value))
                    arguments.extend((flag, str(path)))
            return subprocess.run(
                ["python3", str(CHECKER), *arguments, *extra],
                check=False, capture_output=True, text=True,
            )

    def test_both_version_controlled_contracts_stay_enforced(self):
        result = self.run_checker()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("15 logical checks, 2 native aggregate checks", result.stdout)
        for key in ("policy", "automation"):
            source = LOGICAL if key == "policy" else AGGREGATES
            for change in (lambda p: p["checks"].pop(),
                           lambda p: p["checks"].append(copy.deepcopy(p["checks"][0])),
                           lambda p: p["checks"][0].update(integration_id=123),
                           lambda p: p["checks"][0].update(integration_id=True),
                           lambda p: p.update(schema_version=2),
                           lambda p: p.update(schema_version=True),
                           lambda p: p.update(unreviewed=True)):
                value = copy.deepcopy(source)
                change(value)
                with self.subTest(contract=key, change=change):
                    self.assertNotEqual(self.run_checker(**{key: value}).returncode, 0)

    def test_current_aggregate_profile_passes_without_claiming_merge_or_ci_approval(self):
        for target in (["~DEFAULT_BRANCH"], ["refs/heads/main"]):
            value = ruleset()
            value["conditions"]["ref_name"]["include"] = target
            result = self.run_checker(value)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("2 native aggregate checks and live ruleset", result.stdout)
            self.assertIn("exact-head/base CI and release approval remain separate", result.stdout)
            self.assertIn("auto-merge remains in standby", result.stdout)

    def test_strict_profile_is_explicit_and_never_inferred_from_green_ci(self):
        result = self.run_checker(ruleset(), extra=("--require-auto-merge",))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("strict up-to-date base protection", result.stderr)
        value = ruleset()
        value["rules"][0]["parameters"]["strict_required_status_checks_policy"] = True
        self.assertNotEqual(self.run_checker(value).returncode, 0)
        result = self.run_checker(value, extra=("--require-auto-merge",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.run_checker(extra=("--require-auto-merge",)).returncode, 0)

    def test_missing_wrong_app_duplicate_and_legacy_native_checks_fail(self):
        mutations = (
            lambda checks: checks.pop(),
            lambda checks: checks.append(copy.deepcopy(checks[0])),
            lambda checks: checks[0].update(integration_id=None),
            lambda checks: checks[0].update(integration_id=True),
            lambda checks: checks[0].update(integration_id=123),
            lambda checks: checks[0].update(context="CI Required lookalike"),
            lambda checks: checks.append("malformed"),
            lambda checks: checks.extend(copy.deepcopy(LOGICAL["checks"])),
        )
        for change in mutations:
            value = ruleset()
            change(value["rules"][0]["parameters"]["required_status_checks"])
            with self.subTest(change=change):
                self.assertNotEqual(self.run_checker(value).returncode, 0)

    def test_protection_identity_review_and_bypass_cannot_be_omitted(self):
        mutations = (
            lambda r: r.update(enforcement="evaluate"),
            lambda r: r.update(source="foreign/repo"),
            lambda r: r.update(source_type="Organization"),
            lambda r: r.update(target="tag"),
            lambda r: r.update(conditions=None),
            lambda r: r["conditions"].update(ref_name=[]),
            lambda r: r.pop("bypass_actors"),
            lambda r: r.update(bypass_actors=[{"actor_type": "OrganizationAdmin", "bypass_mode": "always"}]),
            lambda r: r["conditions"]["ref_name"].update(include=["refs/heads/develop"]),
            lambda r: r["conditions"]["ref_name"].update(exclude=["refs/heads/main"]),
            lambda r: r["rules"].pop(),
            lambda r: r["rules"].append(copy.deepcopy(r["rules"][1])),
            lambda r: r["rules"][1]["parameters"].update(required_review_thread_resolution=False),
            lambda r: r["rules"][1]["parameters"].update(required_approving_review_count=-1),
            lambda r: r["rules"][1]["parameters"].update(required_approving_review_count=True),
        )
        for change in mutations:
            value = ruleset()
            change(value)
            with self.subTest(change=change):
                self.assertNotEqual(self.run_checker(value).returncode, 0)

    def test_strict_field_is_a_required_boolean_in_both_profiles(self):
        for strict in (None, "false", "true", 0, 1):
            value = ruleset()
            value["rules"][0]["parameters"]["strict_required_status_checks_policy"] = strict
            for extra in ((), ("--require-auto-merge",)):
                with self.subTest(strict=strict, extra=extra):
                    self.assertNotEqual(self.run_checker(value, extra=extra).returncode, 0)


if __name__ == "__main__":
    unittest.main()
