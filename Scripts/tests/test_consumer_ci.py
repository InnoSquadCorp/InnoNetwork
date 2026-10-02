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
        from unittest import mock
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.tracked = ["Package.resolved"]
        for directory in (".", "Examples/A", "Tests/MacroCompileFailureFixtures/A",
                          "Tools/openapi-to-innonetwork"):
            path = self.root / directory
            path.mkdir(parents=True, exist_ok=True)
            manifest = path / "Package.swift"
            manifest.write_text("// swift-tools-version: 6.2\n// fixture manifest\n")
            self.tracked.append(manifest.relative_to(self.root).as_posix())
        (self.root / "Package.resolved").write_text((Path(__file__).resolve().parents[2] / "Package.resolved").read_text())
        patch = mock.patch.object(cache.cache, "command", side_effect=lambda *args:
                                  "\0".join(self.tracked) if "--others" not in args else "")
        patch.start()
        self.addCleanup(patch.stop)
        self.context = {
            "swift": "Apple Swift version 6.2 (swiftlang-6.2.0.19.9 clang-1700.3.19.1)\nTarget: arm64-apple-macosx15.0",
            "swift-path": "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
            "xcode": "Xcode 26.0.1\nBuild version 17A400",
            "developer-dir": "/Applications/Xcode.app/Contents/Developer",
            "os-version": "15.6.1", "os-build": "24G90", "architecture": "arm64",
            "sdks": {"macosx26.0": {"version": "26.0", "build": "25A354", "path": "/fixture/MacOSX26.0.sdk"}},
        }

    def spec(self, lane="examples"):
        return cache.cache_spec(self.root, lane, self.context)

    def test_same_context_reuses_key(self):
        self.assertEqual(self.spec(), self.spec())

    def test_each_toolchain_component_invalidates(self):
        baseline = self.spec()
        for key, value in (("swift", self.context["swift"].replace("19.9", "19.10")),
                           ("xcode", "Xcode 26.0.1\nBuild version 17A401"),
                           ("swift-path", "/other/swift"), ("developer-dir", "/other/Developer"),
                           ("os-version", "15.6.2"), ("os-build", "24G91"), ("architecture", "x86_64")):
            previous = self.context[key]
            self.context[key] = value
            self.assertNotEqual(baseline, self.spec(), key)
            self.context[key] = previous
        self.context["sdks"]["macosx26.0"]["build"] = "25A355"
        self.assertNotEqual(baseline, self.spec())

    def test_each_tracked_manifest_and_pin_invalidates(self):
        for manifest in sorted(self.root.glob("**/Package.swift")):
            baseline = self.spec()
            original = manifest.read_text()
            manifest.write_text(original + "// changed\n")
            self.assertNotEqual(baseline, self.spec())
            manifest.write_text(original)
            pin = manifest.with_name("Package.resolved")
            if pin == self.root / "Package.resolved":
                continue
            self.tracked.append(pin.relative_to(self.root).as_posix())
            pin.write_text((self.root / "Package.resolved").read_text())
            pinned = self.spec()
            self.assertNotEqual(baseline, pinned)
            value = json.loads(pin.read_text())
            value["pins"][0]["state"]["revision"] = "1" * 40
            pin.write_text(json.dumps(value))
            self.assertNotEqual(pinned, self.spec())
            pin.unlink()
            self.tracked.remove(pin.relative_to(self.root).as_posix())
            self.assertEqual(baseline, self.spec())

    def test_lanes_do_not_share_but_downloads_are_workspace_independent(self):
        self.assertEqual(len({self.spec(lane)['dependency-key'] for lane in cache.LANES}), 3)
        with tempfile.TemporaryDirectory() as another:
            import shutil
            other = Path(another) / "repository"
            shutil.copytree(self.root, other)
            self.assertEqual(self.spec(), cache.cache_spec(other, "examples", self.context))

    def test_packages_keep_separate_graphs_without_restoring_compiled_products(self):
        second = self.root / "Examples/B"
        second.mkdir()
        (second / "Package.swift").write_text("// swift-tools-version: 6.2\n// second graph")
        self.tracked.append("Examples/B/Package.swift")
        result = self.spec()
        self.assertEqual(result['dependency-paths'], cache.DEPENDENCY_PATHS)
        self.assertEqual(result['identity']['package-graphs']['examples'],
                         ['Examples/A/Package.swift', 'Examples/B/Package.swift'])
        self.assertEqual(result['identity']['package-graphs']['macros'],
                         ['Tests/MacroCompileFailureFixtures/A/Package.swift'])
        self.assertEqual(result['identity']['package-graphs']['openapi'],
                         ['Tools/openapi-to-innonetwork/Package.swift'])

    def test_coverage_outputs_and_fresh_core_are_not_cached(self):
        for lane in cache.LANES:
            self.assertEqual(self.spec(lane)['dependency-paths'], cache.DEPENDENCY_PATHS)
            self.assertNotIn('.build', '\n'.join(self.spec(lane)['dependency-paths']))

    def test_downloaded_products_and_generated_ignored_locks_do_not_change_key(self):
        before = self.spec()
        product = self.root / "Examples/A/.build/checkouts/Dependency"
        product.mkdir(parents=True)
        (product / "Package.swift").write_text("downloaded")
        (self.root / "Examples/A/Package.resolved").write_text("ignored generated lock")
        self.assertEqual(before, self.spec())

    def test_missing_independent_graph_fails_closed(self):
        for path in ("Examples/A/Package.swift", "Tests/MacroCompileFailureFixtures/A/Package.swift"):
            self.tracked.remove(path)
            with self.assertRaisesRegex(ValueError, "consumer package graph"):
                self.spec()
            self.tracked.append(path)

    def test_unknown_lane_rejected(self):
        with self.assertRaises(ValueError):
            self.spec("all")


if __name__ == '__main__':
    unittest.main()
