#!/usr/bin/env python3

import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECKER = REPO_ROOT / "Scripts/check_apple_platform_build_contract.py"


PACKAGE_MANIFEST = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Fixture",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ]
)
"""

MATRIX = """        include:
          - destination: "platform=macOS"
            runtime: "macOS"
            sdk: "macosx"
            builder: "xcodebuild"
          - destination: "generic/platform=iOS Simulator"
            runtime: "iOS"
            sdk: "iphonesimulator"
            builder: "xcodebuild"
          - triple: "arm64-apple-tvos16.0"
            runtime: "tvOS"
            sdk: "appletvos"
            builder: "swiftpm-cross"
          - triple: "arm64_32-apple-watchos9.0"
            runtime: "watchOS"
            sdk: "watchos"
            builder: "swiftpm-cross"
          - triple: "arm64-apple-xros1.0"
            runtime: "visionOS"
            sdk: "xros"
            builder: "swiftpm-cross"
"""

LOCAL_PREFLIGHT = """run_apple_platform_builds() {
  xcodebuild -destination 'platform=macOS'
  xcodebuild -destination 'generic/platform=iOS Simulator'
  bash Scripts/build_apple_platform_targets.sh \\
    tvOS appletvos arm64-apple-tvos16.0
  bash Scripts/build_apple_platform_targets.sh \\
    watchOS watchos arm64_32-apple-watchos9.0
  bash Scripts/build_apple_platform_targets.sh \\
    visionOS xros arm64-apple-xros1.0
}
"""

CROSS_BUILD_HELPER = """case "$runtime:$sdk:$target_triple" in
  "tvOS:appletvos:arm64-apple-tvos16.0" | \\
    "watchOS:watchos:arm64_32-apple-watchos9.0" | \\
    "visionOS:xros:arm64-apple-xros1.0")
    ;;
esac
"""


class ApplePlatformBuildContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="innonetwork-apple-platform-build-contract-tests."
        )
        self.fixture_root = pathlib.Path(self.temporary_directory.name)
        (self.fixture_root / ".github/workflows").mkdir(parents=True)
        (self.fixture_root / "Scripts").mkdir()
        self.write("Package.swift", PACKAGE_MANIFEST)
        self.write(
            ".github/workflows/ci.yml",
            "jobs:\n  apple-platform-build-smoke:\n"
            + MATRIX
            + "  consumer-smoke:\n",
        )
        self.write(
            ".github/workflows/release.yml",
            "jobs:\n  validate-platform-builds:\n"
            + MATRIX
            + "  publish-release:\n",
        )
        self.write("Scripts/run_local_release_preflight.sh", LOCAL_PREFLIGHT)
        self.write("Scripts/build_apple_platform_targets.sh", CROSS_BUILD_HELPER)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write(self, relative_path: str, source: str) -> None:
        (self.fixture_root / relative_path).write_text(source, encoding="utf-8")

    def run_checker(self) -> subprocess.CompletedProcess:
        environment = os.environ.copy()
        environment["INNO_APPLE_PLATFORM_CONTRACT_ROOT"] = str(
            self.fixture_root
        )
        return subprocess.run(
            [sys.executable, str(CHECKER)],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_accepts_all_aligned_platform_build_consumers(self) -> None:
        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CI, release, local, and helper aligned", result.stdout)

    def test_rejects_package_floor_drift(self) -> None:
        self.write("Package.swift", PACKAGE_MANIFEST.replace(".tvOS(.v16)", ".tvOS(.v17)"))

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn(".github/workflows/ci.yml triples mismatch", result.stderr)

    def test_rejects_release_matrix_drift(self) -> None:
        release_path = self.fixture_root / ".github/workflows/release.yml"
        source = release_path.read_text(encoding="utf-8").replace(
            "arm64-apple-xros1.0", "arm64-apple-xros2.0"
        )
        release_path.write_text(source, encoding="utf-8")

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn(".github/workflows/release.yml triples mismatch", result.stderr)

    def test_rejects_local_preflight_drift(self) -> None:
        self.write(
            "Scripts/run_local_release_preflight.sh",
            LOCAL_PREFLIGHT.replace("arm64_32-apple-watchos9.0", "arm64_32-apple-watchos10.0"),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("run_local_release_preflight.sh triples mismatch", result.stderr)

    def test_rejects_cross_build_helper_drift(self) -> None:
        self.write(
            "Scripts/build_apple_platform_targets.sh",
            CROSS_BUILD_HELPER.replace("arm64-apple-tvos16.0", "arm64-apple-tvos17.0"),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("build_apple_platform_targets.sh allowed tuples mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
