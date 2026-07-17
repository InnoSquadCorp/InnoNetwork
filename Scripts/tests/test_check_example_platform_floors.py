#!/usr/bin/env python3

import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECKER = REPO_ROOT / "Scripts/check_example_platform_floors.py"
BUILDER_INVOCATION = "run: bash Scripts/build_consumer_examples.sh\n"


def manifest(watch_version: str = "9") -> str:
    return f"""// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Fixture",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
        .tvOS(.v16),
        .watchOS(.v{watch_version}),
        .visionOS(.v1),
    ]
)
"""


class ExamplePlatformFloorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="innonetwork-example-platform-floor-tests."
        )
        self.fixture_root = pathlib.Path(self.temporary_directory.name)
        (self.fixture_root / "Examples/Alpha").mkdir(parents=True)
        (self.fixture_root / ".github/workflows").mkdir(parents=True)
        (self.fixture_root / "Package.swift").write_text(
            manifest(), encoding="utf-8"
        )
        (self.fixture_root / "Examples/Alpha/Package.swift").write_text(
            manifest(), encoding="utf-8"
        )
        self.write_workflow("ci.yml", BUILDER_INVOCATION)
        self.write_workflow("release.yml", BUILDER_INVOCATION)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_workflow(self, name: str, source: str) -> None:
        (self.fixture_root / ".github/workflows" / name).write_text(
            source, encoding="utf-8"
        )

    def run_checker(self) -> subprocess.CompletedProcess:
        environment = os.environ.copy()
        environment["INNO_EXAMPLE_PLATFORM_ROOT"] = str(self.fixture_root)
        return subprocess.run(
            [sys.executable, str(CHECKER)],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_accepts_matching_floors_and_one_builder_per_workflow(self) -> None:
        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("both workflows use the shared builder", result.stdout)

    def test_rejects_missing_builder_invocation(self) -> None:
        self.write_workflow("ci.yml", "name: CI\n")

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("expected one shared example builder invocation, found 0", result.stderr)

    def test_rejects_duplicate_builder_invocations(self) -> None:
        self.write_workflow(
            "release.yml",
            BUILDER_INVOCATION + BUILDER_INVOCATION,
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("expected one shared example builder invocation, found 2", result.stderr)

    def test_rejects_example_floor_drift(self) -> None:
        (self.fixture_root / "Examples/Alpha/Package.swift").write_text(
            manifest(watch_version="10"), encoding="utf-8"
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("Examples/Alpha/Package.swift: expected", result.stderr)


if __name__ == "__main__":
    unittest.main()
