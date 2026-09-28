#!/usr/bin/env python3
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_consumer_ci_results as gate
import consumer_ci_cache as cache


class GateTests(unittest.TestCase):
    def setUp(self):
        self.good = {key: {"result": "success", "outputs": {}} for key in gate.LANES}

    def test_success(self):
        gate.validate(self.good)

    def test_all_non_success_results_fail(self):
        for job in gate.LANES:
            for status in ("failure", "cancelled", "skipped", "", "neutral", None):
                with self.subTest(job=job, status=status):
                    value = copy.deepcopy(self.good)
                    value[job]["result"] = status
                    with self.assertRaises(ValueError):
                        gate.validate(value)

    def test_malformed_or_missing_jobs(self):
        values = [None, [], {}, {**self.good, "extra": {"result": "success"}}]
        for job in gate.LANES:
            values.extend([{k: v for k, v in self.good.items() if k != job},
                           {**self.good, job: {}}, {**self.good, job: "success"}])
        for value in values:
            with self.subTest(value=value), self.assertRaises(ValueError):
                gate.validate(value)

    def test_cli_rejects_invalid_or_duplicate_json(self):
        for value in ("", "{", '{"consumer-examples": {}, "consumer-examples": {}}'):
            result = subprocess.run([sys.executable, gate.__file__], capture_output=True,
                                    env={**os.environ, "CONSUMER_JOB_RESULTS": value})
            self.assertNotEqual(result.returncode, 0)

    def test_cli_accepts_success(self):
        result = subprocess.run([sys.executable, gate.__file__], capture_output=True,
                                env={**os.environ, "CONSUMER_JOB_RESULTS": json.dumps(self.good)})
        self.assertEqual(result.returncode, 0, result.stderr)


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in (".", "Examples/A", "Tests/MacroCompileFailureFixtures/A",
                          "Tools/openapi-to-innonetwork"):
            path = self.root / directory
            path.mkdir(parents=True, exist_ok=True)
            (path / "Package.swift").write_text("manifest")
        self.context = dict(xcode="26.0.1", swift="6.2", sdk="25A", arch="arm64",
                            os="24A", runner_image="20260928")

    def spec(self, lane="examples"):
        return cache.cache_spec(self.root, lane, self.context)

    def test_same_context_reuses_key(self):
        self.assertEqual(self.spec(), self.spec())

    def test_each_toolchain_component_invalidates(self):
        baseline = self.spec()
        for key in self.context:
            self.context[key] += "-new"
            self.assertNotEqual(baseline, self.spec(), key)
            self.context[key] = self.context[key].removesuffix("-new")

    def test_each_manifest_and_pin_invalidates(self):
        for manifest in self.root.glob("**/Package.swift"):
            baseline = self.spec()
            manifest.write_text("changed")
            self.assertNotEqual(baseline, self.spec())
            manifest.write_text("manifest")
            pin = manifest.with_name("Package.resolved")
            pin.write_text("pin 1")
            self.assertNotEqual(baseline, self.spec())
            pinned = self.spec()
            pin.write_text("pin 2")
            self.assertNotEqual(pinned, self.spec())
            pin.unlink()
            self.assertEqual(baseline, self.spec())

    def test_lane_and_workspace_do_not_share(self):
        self.assertEqual(len({self.spec(lane)['prefix'] for lane in cache.LANES}), 3)
        with tempfile.TemporaryDirectory() as another:
            import shutil
            other = Path(another) / "repository"
            shutil.copytree(self.root, other)
            self.assertNotEqual(self.spec(), cache.cache_spec(other, "examples", self.context))

    def test_packages_keep_separate_build_directories(self):
        second = self.root / "Examples/B"
        second.mkdir()
        (second / "Package.swift").write_text("manifest")
        self.assertEqual(self.spec()['paths'], ['Examples/A/.build', 'Examples/B/.build',
                                               *cache.DEPENDENCY_PATHS])

    def test_coverage_outputs_and_fresh_core_are_not_cached(self):
        self.assertEqual(self.spec("macros")['paths'], cache.DEPENDENCY_PATHS)
        for lane in cache.LANES:
            self.assertNotIn('.build', self.spec(lane)['paths'])
            self.assertNotIn('.build/core-only-trait-build', self.spec(lane)['paths'])

    def test_build_products_do_not_change_key(self):
        before = self.spec()
        product = self.root / "Examples/A/.build/checkouts/Dependency"
        product.mkdir(parents=True)
        (product / "Package.swift").write_text("downloaded")
        self.assertEqual(before, self.spec())

    def test_build_policy_invalidates_key(self):
        before = self.spec()
        policy = self.root / ".github/workflows/ci.yml"
        policy.parent.mkdir(parents=True)
        policy.write_text("changed build flags")
        self.assertNotEqual(before, self.spec())

    def test_unknown_lane_rejected(self):
        with self.assertRaises(ValueError):
            self.spec("all")


if __name__ == '__main__':
    unittest.main()
