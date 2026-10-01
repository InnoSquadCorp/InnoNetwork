"""Offline positive/negative controls for dependency-only exact cache profiles."""

import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/ci-cache.py"
spec = importlib.util.spec_from_file_location("ci_cache", SCRIPT)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


_INPUTS = cache.repository_inputs(ROOT)


def inputs():
    return dict(_INPUTS)


def toolchain():
    return {
        "swift": "Apple Swift version 6.3 (swiftlang-6.3.0.4.1 clang-1700.6.5.2)\nTarget: arm64-apple-macosx26.0",
        "swift-path": "/Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
        "xcode": "Xcode 26.6\nBuild version 17G42",
        "developer-dir": "/Applications/Xcode_26.6.app/Contents/Developer",
        "os-version": "26.6", "os-build": "25G42", "architecture": "arm64",
        "sdks": {name + "26.6": {"version": "26.6", "build": "25G42", "path": "/fixture/SDKs/" + name + "26.6.sdk"} for name in (
            "macosx", "iphoneos", "iphonesimulator", "appletvos", "appletvsimulator",
            "watchos", "watchsimulator", "xros", "xrsimulator")},
    }


def fingerprint(**overrides):
    return cache.fingerprint(**{"inputs": inputs(), "toolchain": toolchain(), "profile": "build-and-test",
                                "contract": "offline cache implementation contract", **overrides})


class FingerprintTests(unittest.TestCase):
    def test_deterministic_nonempty_full_digest_and_allowlisted_paths(self):
        first = fingerprint()
        self.assertEqual(first, fingerprint(inputs=dict(reversed(list(inputs().items())))))
        self.assertRegex(first["dependency-key"], r"^innonetwork-swiftpm-deps-v1-build-and-test-default-[0-9a-f]{64}$")
        self.assertEqual(first["dependency-paths"], [
            "~/Library/Caches/org.swift.swiftpm/repositories", "~/Library/Caches/org.swift.swiftpm/prebuilts"])
        self.assertNotIn(".build", "\n".join(first["dependency-paths"]))
        self.assertNotIn("consumer-key", first)
        self.assertEqual(first, json.loads(json.dumps(first)))

    def test_every_manifest_lock_compiler_sdk_arch_os_and_contract_affects_key(self):
        original = fingerprint()["dependency-key"]
        for path in inputs():
            updated = inputs()
            if path.endswith("Package.resolved"):
                lock = json.loads(updated[path])
                lock["pins"][0]["state"]["revision"] = "1" * 40
                updated[path] = json.dumps(lock)
            else:
                updated[path] += "\n// changed manifest\n"
            with self.subTest(path=path):
                self.assertNotEqual(original, fingerprint(inputs=updated)["dependency-key"])
        for key, value in (
            ("swift", toolchain()["swift"].replace("6.3.0.4.1", "6.3.0.4.2")),
            ("swift-path", "/fixture/other/swift"), ("xcode", "Xcode 26.6\nBuild version 17G43"),
            ("developer-dir", "/fixture/other/Developer"), ("os-version", "26.6.1"),
            ("os-build", "25G43"), ("architecture", "x86_64"),
        ):
            with self.subTest(toolchain=key):
                updated = {**toolchain(), key: value}
                self.assertNotEqual(original, fingerprint(toolchain=updated)["dependency-key"])
        for sdk in toolchain()["sdks"]:
            updated = toolchain()
            updated["sdks"][sdk]["build"] = "25G43"
            self.assertNotEqual(original, fingerprint(toolchain=updated)["dependency-key"])
        self.assertNotEqual(original, fingerprint(contract="updated implementation")["dependency-key"])
        updated = inputs()
        updated["Fixtures/New/Package.swift"] = "// swift-tools-version: 6.3\n// local dependency"
        self.assertNotEqual(original, fingerprint(inputs=updated)["dependency-key"])
        updated["Fixtures/New/Package.resolved"] = updated["Package.resolved"]
        self.assertNotEqual(original, fingerprint(inputs=updated)["dependency-key"])

    def test_profiles_are_explicit_and_never_share_keys(self):
        keys = set()
        for profile, contract in cache.PROFILES.items():
            for variant in contract.get("platforms", contract.get("versions", ("default",))):
                resolved, compiler = inputs(), toolchain()
                result = fingerprint(profile=profile, variant=variant, inputs=resolved, toolchain=compiler)
                self.assertNotIn(result["dependency-key"], keys)
                keys.add(result["dependency-key"])
                self.assertEqual(result, json.loads(json.dumps(result)), profile)
        self.assertTrue(cache.PROFILES["consumer-macros"]["source-fallback"])
        self.assertEqual(cache.PROFILES["consumer-macros"]["instrumentation"], "code-coverage")
        for name in ("thread",):
            self.assertEqual(cache.PROFILES[name + "-sanitizer"]["sanitizer"], name)

    def test_unknown_or_wrong_profile_variant_is_rejected(self):
        for profile, variant in [("unknown", "default"), ("codeql", "default"), ("build-and-test", "iOS"), ("apple-platform-build-smoke", "default"),
                                 ("sample-package-builds", "macOS"), ("swift-syntax-compatibility", "605.0.0")]:
            with self.subTest(profile=profile, variant=variant), self.assertRaises(ValueError):
                fingerprint(profile=profile, variant=variant)
    def test_missing_empty_incomplete_toolchain_and_sdk_fail_closed(self):
        for key in toolchain():
            for replacement in (None, "", " "):
                with self.subTest(key=key, replacement=replacement), self.assertRaises(ValueError):
                    fingerprint(toolchain={**toolchain(), key: replacement})
            incomplete = toolchain()
            del incomplete[key]
            with self.assertRaises(ValueError):
                fingerprint(toolchain=incomplete)
        for key, value in [("swift", "Swift version 6.3"), ("swift", "Apple Swift version 6.5 (build)"),
                           ("swift", "Apple Swift version 6.3"), ("xcode", "Xcode 26.6"),
                           ("architecture", "unknown"), ("swift-path", "swift"),
                           ("os-version", "unknown"), ("os-build", "missing build")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                fingerprint(toolchain={**toolchain(), key: value})
        for bad in [{}, {"macosx26.6": {"version": "26.6"}},
                    {"macosx26.6": {"version": "26.6", "build": ""}},
                    {"iphoneos26.6": {"version": "26.6", "build": "25G42"}}]:
            with self.assertRaises(ValueError):
                fingerprint(toolchain={**toolchain(), "sdks": bad})
        incomplete = toolchain()
        del incomplete["sdks"]["watchos26.6"]
        with self.assertRaisesRegex(ValueError, "required profile SDK"):
            fingerprint(profile="apple-platform-build-smoke", variant="watchOS", toolchain=incomplete)

    def test_rejected_sdk_identity_diagnoses_only_collected_sdk_fields(self):
        current = toolchain()
        current["sdks"]["macosx26.6"]["build"] = ""
        with self.assertRaises(ValueError) as caught:
            fingerprint(toolchain=current)
        message = str(caught.exception)
        self.assertIn("incomplete required SDK build identity: macosx26.6", message)
        self.assertIn(repr(current["sdks"]), message)
        self.assertNotIn(current["swift-path"], message)
        self.assertNotIn("GITHUB_TOKEN", message)

    def test_observed_unused_sdk_raw_build_is_bound_without_weakening_required_sdks(self):
        # Exact SDK-only values from PR51 run36850829230/job110332092731.
        sdks = json.loads((Path(__file__).parent / "fixtures/xcodebuild-sdk-identities-26.6.json").read_text())
        self.assertEqual(sdks["driverkit25.5"]["build"], "")
        current = {**toolchain(), "sdks": sdks}
        original = fingerprint(toolchain=current)
        self.assertEqual(original["identity"]["required-sdks"], ["macosx"])
        for profile, contract in cache.PROFILES.items():
            for variant in contract.get("platforms", contract.get("versions", ("default",))):
                with self.subTest(profile=profile, variant=variant):
                    result = fingerprint(toolchain=current, profile=profile, variant=variant)
                    required = result["identity"]["required-sdks"]
                    self.assertIn("macosx", required)
                    for prefix in required:
                        altered = copy.deepcopy(current)
                        name = next(sdk for sdk in sdks if sdk.startswith(prefix))
                        altered["sdks"][name]["build"] = ""
                        with self.assertRaisesRegex(ValueError, "incomplete required SDK build"):
                            fingerprint(toolchain=altered, profile=profile, variant=variant)
        for raw in ("25F70", "SDK-specific.build-identity"):
            altered = copy.deepcopy(current)
            altered["sdks"]["driverkit25.5"]["build"] = raw
            self.assertNotEqual(fingerprint(toolchain=altered)["dependency-key"], original["dependency-key"])
        for malformed in (None, 42, [], {}):
            altered = copy.deepcopy(current)
            altered["sdks"]["driverkit25.5"]["build"] = malformed
            with self.subTest(malformed=malformed), self.assertRaises(ValueError):
                fingerprint(toolchain=altered)
        altered = copy.deepcopy(current)
        del altered["sdks"]["driverkit25.5"]["build"]
        with self.assertRaises(ValueError):
            fingerprint(toolchain=altered)

    def test_each_required_input_is_required_and_resolved_pins_are_exact(self):
        for path in cache.REQUIRED_INPUTS:
            missing = inputs()
            del missing[path]
            with self.subTest(path=path), self.assertRaises(ValueError):
                fingerprint(inputs=missing)
            for value in (None, "", " "):
                with self.assertRaises(ValueError):
                    fingerprint(inputs={**inputs(), path: value})
        mutations = [lambda lock: lock.update(version=1), lambda lock: lock.update(version=True),
                     lambda lock: lock.update(pins=[]), lambda lock: lock.update(pins={}),
                     lambda lock: lock["pins"].append(copy.deepcopy(lock["pins"][0])),
                     lambda lock: lock["pins"][0]["state"].update(revision="main"),
                     lambda lock: lock["pins"][0]["state"].update(version=None),
                     lambda lock: lock["pins"][0]["state"].update(branch="main"),
                     lambda lock: lock["pins"][0].update(kind="localSourceControl")]
        for mutation in mutations:
            lock = json.loads(inputs()["Package.resolved"])
            mutation(lock)
            with self.assertRaises(ValueError):
                fingerprint(inputs={**inputs(), "Package.resolved": json.dumps(lock)})
        for malformed in ("{", "null", "[]", '{"version": 3, "version": 2, "pins": []}'):
            with self.assertRaises(ValueError):
                fingerprint(inputs={**inputs(), "Package.resolved": malformed})
        for path in ("../Package.swift", "/Package.swift", "nested//Package.swift", "nested/./Package.swift"):
            with self.assertRaises(ValueError):
                fingerprint(inputs={**inputs(), path: inputs()["Package.swift"]})


    def test_network_supported_compilers_and_required_platform_sdks(self):
        for version in ("6.2", "6.3", "6.4"):
            current = toolchain()
            current["swift"] = current["swift"].replace("6.3", version)
            fingerprint(toolchain=current)
        expected = {"macOS": "macosx", "iOS": "iphonesimulator", "tvOS": "appletvos",
                    "watchOS": "watchos", "visionOS": "xros"}
        for profile in ("apple-platform-build-smoke", "release-platform-builds"):
            for platform, sdk in expected.items():
                with self.subTest(profile=profile, platform=platform):
                    result = fingerprint(profile=profile, variant=platform)
                    self.assertEqual(result["identity"]["required-sdks"], sorted({"macosx", sdk}))
                    current = toolchain()
                    del current["sdks"][sdk + "26.6"]
                    with self.assertRaisesRegex(ValueError, "required profile SDK"):
                        fingerprint(profile=profile, variant=platform, toolchain=current)

    def test_benchmark_paths_include_only_its_explicit_download_cache(self):
        self.assertEqual(fingerprint(profile="benchmarks")["dependency-paths"], [
            ".build/swiftpm-cache/repositories", ".build/swiftpm-cache/prebuilts"])
        for profile in cache.PROFILES:
            variant = "macOS" if "platforms" in cache.PROFILES[profile] else "default"
            paths = fingerprint(profile=profile, variant=variant)["dependency-paths"]
            self.assertTrue(all(path.endswith(("/repositories", "/prebuilts")) for path in paths))
            self.assertFalse(any(path.endswith(("/coverage", "/benchmarks", "/checkouts")) for path in paths))

    def test_all_consumer_graphs_are_required_but_keep_independent_paths(self):
        for group in ("examples", "macros", "openapi"):
            original = fingerprint()
            paths = original["identity"]["package-graphs"][group]
            self.assertTrue(paths)
            missing = {path: text for path, text in inputs().items() if path not in paths}
            with self.subTest(group=group), self.assertRaises(ValueError):
                fingerprint(inputs=missing)


class InputCollectionTests(unittest.TestCase):
    def test_tracked_manifest_lock_and_project_inventory_is_complete(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            all_inputs = {**inputs(), "Fixtures/Consumer/Package.swift": inputs()["Package.swift"],
                          "Fixtures/Consumer/Package.resolved": inputs()["Package.resolved"],
                          "Package@swift-6.4.swift": inputs()["Package.swift"],
                          "Sample.xcodeproj/project.pbxproj": "fixture project"}
            for path, text in all_inputs.items():
                file = root / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(text)
            tracked = "\0".join([*all_inputs, "Sources/Package.swift.fixture", "Sources/Feature.swift"]) + "\0"
            with mock.patch.object(cache, "command", side_effect=[tracked, ""]):
                self.assertEqual(cache.repository_inputs(root), all_inputs)
            with mock.patch.object(cache, "command", side_effect=[tracked, "New/Package.swift\0"]), self.assertRaises(ValueError):
                cache.repository_inputs(root)
            with mock.patch.object(cache, "command", return_value=tracked.replace("Package.resolved\0", "", 1)), self.assertRaises(ValueError):
                cache.repository_inputs(root)
            target = root / "Package.resolved"
            target.unlink()
            (root / "Fixture.lock").write_text(inputs()["Package.resolved"])
            target.symlink_to(root / "Fixture.lock")
            with mock.patch.object(cache, "command", side_effect=[tracked, ""]), self.assertRaisesRegex(ValueError, "symlinked"):
                cache.repository_inputs(root)

    def test_failed_sdk_query_reports_partial_metadata_and_never_continues(self):
        calls = []
        def output(*args):
            calls.append(args)
            if args == ("xcodebuild", "-showsdks"):
                return "macOS SDKs:\nmacOS 26.5 -sdk macosx26.5"
            if args[-1] == "--show-sdk-version":
                return "26.5"
            raise subprocess.CalledProcessError(72, args, output="partial SDK-only output")
        with mock.patch.object(cache, "command", side_effect=output), self.assertRaises(ValueError) as caught:
            cache.toolchain_identity()
        self.assertIn("macosx26.5 --show-sdk-build-version", str(caught.exception))
        self.assertIn("'version': '26.5'", str(caught.exception))
        self.assertIn("partial SDK-only output", str(caught.exception))
        self.assertFalse(any(command[-1] == "--show-sdk-path" for command in calls))

    def test_sdk_inventory_rejection_preserves_actual_listing_for_diagnosis(self):
        for listing in ("Unsupported SDK listing", "macOS -sdk macosx26.6\nmacOS alias -sdk macosx26.6"):
            with self.subTest(listing=listing), mock.patch.object(cache, "command", return_value=listing):
                with self.assertRaises(ValueError) as caught:
                    cache.toolchain_identity()
                self.assertIn("SDK inventory rejected", str(caught.exception))
                self.assertIn(repr(listing), str(caught.exception))
                self.assertIn("parsed=", str(caught.exception))
                self.assertIn("duplicates=", str(caught.exception))

    def test_toolchain_collects_each_sdk_version_and_build_without_building(self):
        commands = []

        def output(*args):
            commands.append(args)
            if args == ("xcodebuild", "-showsdks"):
                return "macOS SDKs:\n\tmacOS 26.6 -sdk macosx26.6\niOS SDKs:\n\tiOS 26.6 -sdk iphoneos26.6"
            if args[-1] == "--show-sdk-version":
                return "26.6"
            if args[-1] == "--show-sdk-build-version":
                return "25G42"
            if args[-1] == "--show-sdk-path":
                return "/fixture/SDKs/" + args[2] + ".sdk"
            return {("xcrun", "swift", "--version"): toolchain()["swift"],
                    ("xcrun", "--find", "swift"): toolchain()["swift-path"],
                    ("xcodebuild", "-version"): toolchain()["xcode"],
                    ("xcode-select", "-p"): toolchain()["developer-dir"],
                    ("sw_vers", "-productVersion"): "26.6", ("sw_vers", "-buildVersion"): "25G42",
                    ("uname", "-m"): "arm64"}[args]

        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(cache, "command", side_effect=output):
            result = cache.toolchain_identity()
        self.assertEqual(set(result["sdks"]), {"macosx26.6", "iphoneos26.6"})
        self.assertIn(("xcrun", "--sdk", "iphoneos26.6", "--show-sdk-build-version"), commands)
        self.assertFalse(any("test" in command or "build" in command or "resolve" in command for command in commands))
        for listing in ("", "macOS -sdk macosx26.6\nmacOS duplicate -sdk macosx26.6"):
            with mock.patch.object(cache, "command", return_value=listing), self.assertRaises(ValueError):
                cache.toolchain_identity()

    def test_hosted_xcode_26_6_duplicate_is_identical_and_resolves_consistently(self):
        # Exact stdout from InnoFlow PR51 run36847228322/job110320319471.
        listing = (Path(__file__).parent / "fixtures/xcodebuild-showsdks-26.6.txt").read_text()
        names = cache.sdk_identifiers(listing)
        self.assertEqual(len(names), 11)
        self.assertEqual(names.count("macosx26.5"), 2)
        self.assertEqual(len(set(names)), 10)
        queried = []
        def output(*args):
            if args == ("xcodebuild", "-showsdks"):
                return listing
            if args[0] == "xcrun" and args[1] == "--sdk":
                queried.append(args)
                name, flag = args[2:]
                return {"--show-sdk-version": name.removeprefix("driverkit") if name.startswith("driverkit") else "26.5",
                        "--show-sdk-build-version": "25G42", "--show-sdk-path": "/fixture/SDKs/" + name + ".sdk"}[flag]
            return {("xcrun", "swift", "--version"): toolchain()["swift"],
                    ("xcrun", "--find", "swift"): toolchain()["swift-path"],
                    ("xcodebuild", "-version"): "Xcode 26.6\nBuild version 17F113",
                    ("xcode-select", "-p"): toolchain()["developer-dir"],
                    ("sw_vers", "-productVersion"): "26.6.2", ("sw_vers", "-buildVersion"): "25G83",
                    ("uname", "-m"): "arm64"}[args]
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(cache, "command", side_effect=output):
            actual = cache.toolchain_identity()
            self.assertEqual(len(actual["sdks"]), 10)
            self.assertEqual(queried.count(("xcrun", "--sdk", "macosx26.5", "--show-sdk-path")), 2)
            fingerprint(toolchain=actual)
        for field in ("version", "build", "path"):
            occurrence = 0
            flag = {"version": "--show-sdk-version", "build": "--show-sdk-build-version", "path": "--show-sdk-path"}[field]
            def inconsistent(*args):
                nonlocal occurrence
                value = output(*args)
                if args == ("xcrun", "--sdk", "macosx26.5", flag):
                    occurrence += 1
                    if occurrence == 2:
                        return value + "changed"
                return value
            with self.subTest(field=field), mock.patch.object(cache, "command", side_effect=inconsistent), self.assertRaisesRegex(ValueError, "SDK resolution changed"):
                cache.toolchain_identity()

    def test_same_sdk_identifier_with_other_display_section_or_invalid_row_rejects(self):
        valid = "macOS SDKs:\nmacOS 26.5 -sdk macosx26.5\n"
        self.assertEqual(cache.sdk_identifiers(valid + "  macOS  26.5  -sdk  macosx26.5\n"), ["macosx26.5"] * 2)
        for suffix in ("macOS 99.0 -sdk macosx26.5", "iOS SDKs:\nmacOS 26.5 -sdk macosx26.5",
                       "macOS 26.5 -sdk malformed", "unparsed SDK row"):
            with self.subTest(suffix=suffix), self.assertRaisesRegex(ValueError, "SDK inventory rejected"):
                cache.sdk_identifiers(valid + suffix)
        for missing in ("", "macOS SDKs:\n", "macOS 26.5 -sdk macosx26.5"):
            with self.assertRaises(ValueError):
                cache.sdk_identifiers(missing)

    def test_sdk_path_is_bound_and_missing_profile_sdks_still_fail(self):
        baseline = fingerprint()["dependency-key"]
        changed = toolchain()
        changed["sdks"]["macosx26.6"]["path"] = "/other/SDKs/macosx26.6.sdk"
        self.assertNotEqual(fingerprint(toolchain=changed)["dependency-key"], baseline)
        for path in (None, "", "relative/sdk", "/bad\npath"):
            changed["sdks"]["macosx26.6"]["path"] = path
            with self.subTest(path=path), self.assertRaises(ValueError):
                fingerprint(toolchain=changed)
        for sdk in ("macosx26.6", "iphonesimulator26.6"):
            changed = toolchain()
            del changed["sdks"][sdk]
            with self.subTest(sdk=sdk), self.assertRaisesRegex(ValueError, "required profile SDK"):
                fingerprint(toolchain=changed, profile="apple-platform-build-smoke", variant="iOS")


    def test_tracked_build_tree_inputs_are_rejected_and_generated_inputs_are_not_hashed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            all_inputs = inputs()
            generated = ".build/checkouts/Dependency/Package.swift"
            for path, content in {**all_inputs, generated: "// swift-tools-version: 6.2"}.items():
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
            tracked = "\0".join([*all_inputs, generated]) + "\0"
            with mock.patch.object(cache, "command", side_effect=[tracked, ""]):
                with self.assertRaisesRegex(ValueError, "generated build tree"):
                    cache.repository_inputs(root)
            tracked = "\0".join(all_inputs) + "\0"
            with mock.patch.object(cache, "command", side_effect=[tracked, ""]):
                self.assertEqual(cache.repository_inputs(root), all_inputs)


class ObservationTests(unittest.TestCase):
    def test_cold_cache_is_empty_and_only_allowed_download_trees_are_observed(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            self.assertEqual(cache.observations(home), {})
            mirror = home / "Library/Caches/org.swift.swiftpm/repositories/swift-syntax/HEAD"
            mirror.parent.mkdir(parents=True)
            mirror.write_text("ref: refs/heads/main")
            for excluded in (".build/SwiftSyntax.build/product.o", "Library/Developer/Xcode/DerivedData/product.o",
                             "Library/Caches/org.swift.swiftpm/security/fingerprint.json"):
                path = home / excluded
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("must not be observed")
            first = cache.observations(home)
            self.assertEqual(list(first), ["repositories/swift-syntax/HEAD"])
            cache.validate_observations(first)
            mirror.write_text("changed")
            self.assertNotEqual(first, cache.observations(home))
            link = mirror.parent / "outside"
            link.symlink_to(home / ".build", target_is_directory=True)
            observed = cache.observations(home)
            self.assertEqual(len(observed), 2)
            self.assertEqual(observed["repositories/swift-syntax/outside"][0], "symlink")
            self.assertNotIn("product.o", json.dumps(observed))

    def test_invalid_cache_roots_metadata_and_state_paths_fail_closed(self):
        for value in (None, [], {"../outside": ["file", 1, 1]}, {".build/file.o": ["file", 1, 1]},
                      {"repositories": ["file", 1, 1]}, {"repositories/file": ["file", -1, 1]},
                      {"repositories/file": ["file", True, 1]}, {"repositories/file": ["file", 1, -1]},
                      {"repositories/file": ["file", 1]}, {"repositories/file": ["object", 1, 1]}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                cache.validate_observations(value)
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            base = home / "Library/Caches/org.swift.swiftpm"
            base.mkdir(parents=True)
            (base / "repositories").symlink_to(home, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlinked cache root"):
                cache.observations(home)
            (base / "repositories").unlink()
            (base / "repositories").write_text("not a directory")
            with self.assertRaisesRegex(ValueError, "not a directory"):
                cache.observations(home)
            target, state = home / "target", home / "state"
            target.write_text("untouched")
            state.symlink_to(target)
            with self.assertRaises(ValueError):
                cache.write_state(state, {})
            self.assertEqual(target.read_text(), "untouched")
            directory = home / "state-directory"
            directory.symlink_to(home, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlinked cache state"):
                cache.write_state(directory / "new-state.json", {})
            self.assertFalse((home / "new-state.json").exists())


    def test_benchmark_observation_excludes_compiled_and_result_siblings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            for name in (".build/swiftpm-cache/repositories/dependency/HEAD",
                         ".build/swiftpm-cache/prebuilts/download.zip",
                         ".build/benchmarks/result.json", ".build/benchmark-builds/head/product.o",
                         ".build/swiftpm-cache/security/fingerprints.json"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture")
            observed = cache.observations(root, root, "benchmarks")
            self.assertEqual(set(observed), {"repositories/dependency/HEAD", "prebuilts/download.zip"})
            self.assertEqual(cache.observations(root), {})
            with self.assertRaisesRegex(ValueError, "requires a root"):
                cache.observations(root, profile="benchmarks")


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.state, self.output, self.summary = (self.root / name for name in ("state.json", "output", "summary"))
        self.now = 100.0
        self.inputs = inputs()
        self.toolchain = toolchain()
        self.entries = {}
        patches = [
            mock.patch.dict(os.environ, {"HOME": str(self.root), "GITHUB_OUTPUT": str(self.output),
                "GITHUB_STEP_SUMMARY": str(self.summary), "DEPENDENCY_CACHE_HIT": "",
                "GITHUB_RUN_ID": "10", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_JOB": "build-and-test"}, clear=True),
            mock.patch.object(cache, "repository_inputs", side_effect=lambda root: self.inputs),
            mock.patch.object(cache, "toolchain_identity", side_effect=lambda: self.toolchain),
            mock.patch.object(cache, "observations", side_effect=lambda *args: self.entries),
            mock.patch.object(cache.time, "time", side_effect=lambda: self.now),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def run_cli(self, command, profile="build-and-test", variant="default"):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = cache.main([command, "--root", str(self.root), "--state", str(self.state),
                                 "--profile", profile, "--variant", variant])
        return result, stdout.getvalue(), stderr.getvalue()

    def succeed(self, command, **kwargs):
        result, output, error = self.run_cli(command, **kwargs)
        self.assertEqual(result, 0, error)
        return output

    def mutate_state(self, mutation):
        data = json.loads(self.state.read_text())
        mutation(data)
        self.state.write_text(json.dumps(data))

    def test_cold_and_warm_observations_never_imply_verification(self):
        for hit in ("", "false", "true"):
            with self.subTest(hit=hit):
                self.now = 100.0
                os.environ["DEPENDENCY_CACHE_HIT"] = hit
                self.succeed("fingerprint")
                self.assertIn("dependency-key=innonetwork-swiftpm-deps-v1-build-and-test-default-", self.output.read_text())
                self.assertIn("dependency-paths<<CACHE_PATHS", self.output.read_text())
                self.entries = {"prebuilts/archive.zip": ["file", 42, 100]} if hit == "true" else {}
                self.now = 102.5
                self.succeed("restored")
                self.now = 110.0
                self.entries = {**self.entries, "repositories/new/HEAD": ["file", 3, 100]}
                report = json.loads(self.succeed("report"))
                self.assertEqual(report["dependency_cache_hit"], hit)
                self.assertEqual(report["restore_elapsed_seconds"], 2.5)
                self.assertEqual(report["validation_elapsed_seconds"], 7.5)
                self.assertEqual(report["verification"], "not-evaluated-by-cache")
                self.assertEqual(report["restored_entries_unchanged"], 1 if hit == "true" else 0)
                self.assertIn("not verification", self.summary.read_text())
                self.assertNotEqual(self.run_cli("report")[0], 0)

    def test_matrix_profile_survives_json_state_round_trip(self):
        for command in ("fingerprint", "restored", "report"):
            self.succeed(command, profile="apple-platform-build-smoke", variant="watchOS")

    def test_missing_malformed_or_wrong_phase_observations_fail_closed(self):
        for command in ("restored", "report"):
            self.assertNotEqual(self.run_cli(command)[0], 0)
        self.succeed("fingerprint")
        self.assertNotEqual(self.run_cli("report")[0], 0)
        for hit in (None, "TRUE", "success", "null"):
            if hit is None:
                os.environ.pop("DEPENDENCY_CACHE_HIT", None)
            else:
                os.environ["DEPENDENCY_CACHE_HIT"] = hit
            self.assertNotEqual(self.run_cli("restored")[0], 0)
        os.environ["DEPENDENCY_CACHE_HIT"] = "false"
        self.succeed("restored")
        self.assertNotEqual(self.run_cli("restored")[0], 0)
        for mutation in (
            lambda data: data.pop("restored"), lambda data: data.update(restored=[]),
            lambda data: data.update(restored={".build/a.o": ["file", 2, 1]}),
            lambda data: data.update(dependency_hit="success"), lambda data: data.pop("dependency_hit"),
            lambda data: data.update(restore_seconds=-1), lambda data: data.update(restore_seconds=True),
            lambda data: data.update(restore_seconds=float("nan")), lambda data: data.pop("build_started"),
            lambda data: data.update(build_started=111), lambda data: data.update(started="yesterday"),
            lambda data: data.update(schema=True), lambda data: data.update(fingerprint={}),
            lambda data: data.update(context={}), lambda data: data.update(phase="reported"),
        ):
            self.succeed("fingerprint")
            self.succeed("restored")
            self.mutate_state(mutation)
            self.assertNotEqual(self.run_cli("report")[0], 0)
        for malformed in ("{", "null", "[]", '{"schema": 1, "schema": 1}'):
            self.state.write_text(malformed)
            self.assertNotEqual(self.run_cli("report")[0], 0)

    def test_changed_inputs_toolchain_profile_or_run_context_reject_observations(self):
        for command in ("restored", "report"):
            for change in ("lock", "compiler", "profile", "run-id", "run-attempt"):
                with self.subTest(command=command, change=change):
                    self.inputs, self.toolchain = inputs(), toolchain()
                    os.environ.update(GITHUB_RUN_ID="10", GITHUB_RUN_ATTEMPT="1")
                    self.succeed("fingerprint")
                    if command == "report":
                        self.succeed("restored")
                    profile = "build-and-test"
                    if change == "lock":
                        self.inputs["Package.resolved"] += "\n"
                    elif change == "compiler":
                        self.toolchain["swift"] = self.toolchain["swift"].replace("6.3.0.4.1", "6.3.0.4.2")
                    elif change == "profile":
                        profile = "consumer-macros"
                    elif change == "run-id":
                        os.environ["GITHUB_RUN_ID"] = "11"
                    else:
                        os.environ["GITHUB_RUN_ATTEMPT"] = "2"
                    self.assertNotEqual(self.run_cli(command, profile=profile)[0], 0)

    def test_tool_command_failures_empty_inputs_and_missing_output_fail_closed(self):
        with mock.patch.object(cache, "toolchain_identity", side_effect=subprocess.CalledProcessError(1, ["swift", "--version"])):
            self.assertNotEqual(self.run_cli("fingerprint")[0], 0)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.output.exists())
        self.inputs["Package.resolved"] = ""
        self.assertNotEqual(self.run_cli("fingerprint")[0], 0)
        self.inputs = inputs()
        os.environ.pop("GITHUB_OUTPUT")
        self.assertNotEqual(self.run_cli("fingerprint")[0], 0)
        self.assertFalse(self.state.exists())


class CLIIntegrationTests(unittest.TestCase):
    def test_real_cli_ignores_build_inputs_and_state_survives_build_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            root, home, binaries = (base / name for name in ("checkout", "home", "bin"))
            for directory in (root, home, binaries):
                directory.mkdir()
            for relative, contents in inputs().items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            (root / ".gitignore").write_text(".build/\nbuild/\n")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            commands = {
                "swift": "printf '%s\\n' 'Apple Swift version 6.3 (swiftlang-6.3.0.4.1 clang-1700.6.5.2)'",
                "xcodebuild": "if [ \"$1\" = '-version' ]; then printf '%s\\n' 'Xcode 26.6' 'Build version 17G42'; else printf '%s\\n' 'macOS SDKs:' 'macOS 26.6 -sdk macosx26.6' 'iOS SDKs:' 'iOS 26.6 -sdk iphoneos26.6' 'iOS Simulator SDKs:' 'Simulator - iOS 26.6 -sdk iphonesimulator26.6'; fi",
                "xcrun": "if [ \"$1\" = 'swift' ]; then swift --version; elif [ \"$1\" = '--find' ]; then echo /fixture/Xcode.app/Contents/Developer/usr/bin/swift; elif [ \"$3\" = '--show-sdk-version' ]; then echo 26.6; elif [ \"$3\" = '--show-sdk-build-version' ]; then echo 25G42; elif [ \"$3\" = '--show-sdk-path' ]; then echo /fixture/SDKs/$2.sdk; else exit 1; fi",
                "sw_vers": "if [ \"$1\" = '-productVersion' ]; then echo 26.6; else echo 25G42; fi",
                "uname": "echo arm64", "xcode-select": "echo /fixture/Xcode.app/Contents/Developer",
            }
            for name, command in commands.items():
                executable = binaries / name
                executable.write_text("#!/bin/sh\nset -eu\n" + command + "\n")
                executable.chmod(0o755)
            env = {**os.environ, "HOME": str(home), "PATH": str(binaries) + ":" + os.environ["PATH"],
                   "GITHUB_OUTPUT": str(base / "outputs"), "GITHUB_STEP_SUMMARY": str(base / "summary"),
                   "DEPENDENCY_CACHE_HIT": "false", "DEVELOPER_DIR": "/fixture/Xcode.app/Contents/Developer"}
            for phase in ("fingerprint", "restored", "report"):
                if phase == "restored":
                    generated = root / ".build/checkouts/dependency/Package.swift"
                    generated.parent.mkdir(parents=True)
                    generated.write_text("ignored generated manifest")
                elif phase == "report":
                    shutil.rmtree(root / ".build")
                    generated = root / "Examples/ConsumerSmoke/.build/checkouts/dependency/Package.swift"
                    generated.parent.mkdir(parents=True)
                    generated.write_text("ignored sample dependency manifest")
                run = subprocess.run([sys.executable, "-B", str(SCRIPT), phase, "--root", str(root),
                                      "--profile", "apple-platform-build-smoke", "--variant", "iOS"],
                                     env=env, text=True, capture_output=True)
                self.assertEqual(run.returncode, 0, (phase, run.stdout, run.stderr))
            data = json.loads((root / "build/ci-cache.json").read_text())
            self.assertEqual(data["phase"], "reported")
            self.assertEqual(data["report"]["verification"], "not-evaluated-by-cache")
            self.assertFalse((root / ".build").exists())



class CompositeActionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Ruby/Psych already powers the existing consumer contract tests.
        data = subprocess.check_output([
            "ruby", "-rjson", "-ryaml", "-e",
            "puts JSON.generate(ARGV.map { |path| YAML.safe_load(File.read(path), aliases: false) })",
            str(ROOT / ".github/actions/swiftpm-cache/action.yml"),
            str(ROOT / ".github/actions/consumer-cache/action.yml"),
        ], text=True)
        cls.generic, cls.consumer = json.loads(data)

    def validate(self, action):
        self.assertEqual(action["runs"]["using"], "composite")
        steps = action["runs"]["steps"]
        self.assertEqual(len(steps), 3)
        self.assertTrue(all("if" not in step and "continue-on-error" not in step for step in steps))
        self.assertEqual(steps[0]["id"], "fingerprint")
        self.assertEqual(steps[1]["id"], "dependency-cache")
        self.assertEqual(steps[1]["uses"], "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9")
        self.assertEqual(steps[1]["with"], {
            "path": "${{ steps.fingerprint.outputs.dependency-paths }}",
            "key": "${{ steps.fingerprint.outputs.dependency-key }}",
        })
        self.assertEqual(steps[2]["env"]["DEPENDENCY_CACHE_HIT"], "${{ steps.dependency-cache.outputs.cache-hit }}")
        self.assertIn("Scripts/ci-cache.py restored --profile ", steps[2]["run"])
        self.assertNotIn("||", steps[2]["run"])

    def test_both_actions_restore_only_exact_downloads_with_unconditional_observation(self):
        self.validate(self.generic)
        self.validate(self.consumer)
        self.assertEqual(self.generic["inputs"]["variant"]["default"], "default")
        self.assertEqual(self.consumer["inputs"]["lane"]["required"], True)
        self.assertEqual(self.generic["runs"]["steps"][0]["run"],
                         'python3 -B Scripts/ci-cache.py fingerprint --profile "$CI_CACHE_PROFILE" --variant "$CI_CACHE_VARIANT"')
        self.assertEqual(self.consumer["runs"]["steps"][0]["run"],
                         'python3 Scripts/consumer_ci_cache.py "$CONSUMER_CACHE_LANE" --github-output')

    def test_broad_fallback_compiled_paths_conditional_observation_are_rejected(self):
        for action in (self.generic, self.consumer):
            for mutation in (
                lambda steps: steps[1]["with"].update({"restore-keys": "swiftpm-"}),
                lambda steps: steps[1]["with"].update(path=".build"),
                lambda steps: steps[1]["with"].update(key="${{ github.sha }}"),
                lambda steps: steps[2].update({"if": "success()"}),
                lambda steps: steps[2].update({"continue-on-error": True}),
            ):
                broken = copy.deepcopy(action)
                mutation(broken["runs"]["steps"])
                with self.assertRaises(AssertionError):
                    self.validate(broken)


if __name__ == "__main__":
    unittest.main()
