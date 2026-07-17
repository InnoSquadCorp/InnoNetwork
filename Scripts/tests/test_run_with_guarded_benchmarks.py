#!/usr/bin/env python3

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
RUNNER = REPO_ROOT / "Scripts/run_with_guarded_benchmarks.py"


class GuardedBenchmarkRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="innonetwork-guarded-benchmark-runner-tests."
        )
        self.fixture_root = pathlib.Path(self.temporary_directory.name)
        (self.fixture_root / "Benchmarks/Baselines").mkdir(parents=True)
        self.identifiers = [
            "client/request-pipeline",
            "cache/response-cache-lookup",
        ]
        self.write_contract(self.identifiers)
        baseline = {
            "results": [
                {"group": group, "name": name}
                for group, name in (
                    identifier.split("/", maxsplit=1)
                    for identifier in self.identifiers
                )
            ]
        }
        (self.fixture_root / "Benchmarks/Baselines/default.json").write_text(
            json.dumps(baseline),
            encoding="utf-8",
        )
        self.environment = os.environ.copy()
        self.environment["INNO_GUARDED_BENCHMARK_CONTRACT_ROOT"] = str(
            self.fixture_root
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_contract(self, identifiers) -> None:
        (self.fixture_root / "Benchmarks/guarded-benchmarks.txt").write_text(
            "".join(f"{identifier}\n" for identifier in identifiers),
            encoding="utf-8",
        )

    def run_runner(self, *arguments: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(RUNNER), *arguments],
            check=False,
            capture_output=True,
            text=True,
            env=self.environment,
        )

    def test_appends_each_guard_to_wrapped_command_in_contract_order(self) -> None:
        capture_script = self.fixture_root / "capture.py"
        output_path = self.fixture_root / "arguments.json"
        capture_script.write_text(
            "import json, pathlib, sys\n"
            "pathlib.Path(sys.argv[1]).write_text(json.dumps(sys.argv[2:]))\n",
            encoding="utf-8",
        )

        result = self.run_runner(
            "--",
            sys.executable,
            str(capture_script),
            str(output_path),
            "existing-argument",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(output_path.read_text(encoding="utf-8")),
            [
                "existing-argument",
                "--guard-benchmark",
                "client/request-pipeline",
                "--guard-benchmark",
                "cache/response-cache-lookup",
            ],
        )

    def test_requires_command_separator_and_command(self) -> None:
        result = self.run_runner(sys.executable)

        self.assertEqual(result.returncode, 64)
        self.assertIn("usage:", result.stderr)

    def test_rejects_duplicate_contract_entries_before_execution(self) -> None:
        self.write_contract([self.identifiers[0], self.identifiers[0]])

        result = self.run_runner("--", sys.executable, "--version")

        self.assertEqual(result.returncode, 1)
        self.assertIn("duplicate guard identifier", result.stderr)

    def test_reports_unavailable_wrapped_command(self) -> None:
        result = self.run_runner("--", "innonetwork-command-that-does-not-exist")

        self.assertEqual(result.returncode, 69)
        self.assertIn("command is unavailable", result.stderr)


if __name__ == "__main__":
    unittest.main()
