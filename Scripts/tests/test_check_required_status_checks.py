#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER = REPO_ROOT / "Scripts" / "check_required_status_checks.py"
POLICY = REPO_ROOT / ".github" / "required-status-checks.json"


def run(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(CHECKER), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )


policy = json.loads(POLICY.read_text())
checks = policy["checks"]

with tempfile.TemporaryDirectory() as temporary_directory:
    root = Path(temporary_directory)
    ruleset_path = root / "ruleset.json"
    ruleset_path.write_text(
        json.dumps(
            {
                "rules": [
                    {
                        "type": "required_status_checks",
                        "parameters": {
                            "strict_required_status_checks_policy": True,
                            "required_status_checks": checks,
                        },
                    }
                ]
            }
        )
    )
    result = run("--ruleset-json", str(ruleset_path))
    assert result.returncode == 0, result.stderr
    assert "14 policy checks and live ruleset" in result.stdout

    missing_ruleset = json.loads(ruleset_path.read_text())
    missing_ruleset["rules"][0]["parameters"]["required_status_checks"] = checks[:-1]
    ruleset_path.write_text(json.dumps(missing_ruleset))
    result = run("--ruleset-json", str(ruleset_path))
    assert result.returncode != 0
    assert "live ruleset differs from policy" in result.stderr

with tempfile.TemporaryDirectory() as temporary_directory:
    duplicate_policy = Path(temporary_directory) / "policy.json"
    duplicate_policy.write_text(
        json.dumps({"schema_version": 1, "checks": checks + [checks[0]]})
    )
    result = run("--policy", str(duplicate_policy))
    assert result.returncode != 0
    assert "duplicate check contexts" in result.stderr

with tempfile.TemporaryDirectory() as temporary_directory:
    incomplete_policy = Path(temporary_directory) / "policy.json"
    incomplete_policy.write_text(json.dumps({"schema_version": 1, "checks": checks[:-1]}))
    result = run("--policy", str(incomplete_policy))
    assert result.returncode != 0
    assert "omits mandatory contexts" in result.stderr

print("required-status-check fixtures: OK")
