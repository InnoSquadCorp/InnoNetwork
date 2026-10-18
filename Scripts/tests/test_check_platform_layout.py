#!/usr/bin/env python3
"""Positive and negative controls for native package-root compatibility."""

import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("platform_layout", ROOT / "Scripts/check_platform_layout.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PlatformLayoutTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve() / "repo"
        for relative in MODULE.REQUIRED_DIRS:
            (self.root / relative).mkdir(parents=True, exist_ok=True)
        for relative in MODULE.REQUIRED_FILES:
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)

    def update_json(self, relative, mutate):
        path = self.root / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        mutate(value)
        path.write_text(json.dumps(value), encoding="utf-8")

    def assert_rejected(self, message):
        self.assertTrue(any(message in error for error in MODULE.validate(self.root)))

    def test_current_roots_pass(self):
        self.assertEqual(MODULE.validate(self.root), [])

    def test_missing_swift_manifest_fails(self):
        (self.root / "Package.swift").unlink()
        self.assert_rejected("Package.swift")

    def test_symlinked_swift_manifest_fails(self):
        manifest = self.root / "Package.swift"
        target = self.root / "manifest-copy"
        manifest.rename(target)
        manifest.symlink_to(target)
        self.assert_rejected("Package.swift")

    def test_missing_android_module_fails(self):
        (self.root / "Platforms/Android/innonetwork-client/build.gradle.kts").unlink()
        self.assert_rejected("innonetwork-client/build.gradle.kts")

    def test_android_settings_drift_fails(self):
        path = self.root / "Platforms/Android/settings.gradle.kts"
        path.write_text(path.read_text().replace('include(":innonetwork-client")', ""))
        self.assert_rejected("no longer includes :innonetwork-client")

    def test_web_repository_directory_drift_fails(self):
        self.update_json("Platforms/Web/package.json", lambda value: value["repository"].update(directory="."))
        self.assert_rejected("repository.directory")

    def test_commented_android_module_does_not_count(self):
        path = self.root / "Platforms/Android/settings.gradle.kts"
        path.write_text(path.read_text().replace('include(":innonetwork-client")', '// include(":innonetwork-client")'))
        self.assert_rejected("no longer includes :innonetwork-client")

    def test_android_composite_path_drift_fails(self):
        path = self.root / "SmokeTests/AndroidConsumer/settings.gradle.kts"
        path.write_text(path.read_text().replace('includeBuild("../../Platforms/Android")', 'includeBuild("../../")'))
        self.assert_rejected("Android consumer composite")

    def test_android_preview_path_drift_fails(self):
        path = self.root / "SmokeTests/AndroidConsumer/settings.gradle.kts"
        path.write_text(path.read_text().replace("../../Platforms/Android/build/preview-repository", "../../build/preview-repository"))
        self.assert_rejected("Android consumer Maven preview")

    def test_published_consumer_tree_fails(self):
        self.update_json("Platforms/Web/package.json", lambda value: value["files"].append("SmokeTests"))
        self.assert_rejected("exclude repository or consumer trees")

    def test_escaping_web_entry_fails(self):
        self.update_json("Platforms/Web/package.json", lambda value: value.update(main="./dist/../../Sources/file.js"))
        self.assert_rejected("Web main")

    def test_missing_web_export_fails(self):
        self.update_json("Platforms/Web/package.json", lambda value: value["exports"]["."].pop("types"))
        self.assert_rejected("Web exports.types")

    def test_consumer_path_drift_fails(self):
        self.update_json("SmokeTests/ReactConsumer/package.json", lambda value: value["dependencies"].update({"@innosquad/innonetwork": "file:../../"}))
        self.assert_rejected("points outside Platforms/Web")

    def test_public_consumer_fixture_fails(self):
        self.update_json("SmokeTests/WebConsumer/package.json", lambda value: value.update(private=False))
        self.assert_rejected("private consumer fixture")

    def test_stale_web_license_fails(self):
        (self.root / "Platforms/Web/LICENSE").write_text("stale license")
        self.assert_rejected("LICENSE differs")

    def test_invalid_json_fails(self):
        (self.root / "Platforms/Web/package.json").write_text("not json")
        self.assert_rejected("invalid package manifest")

    def test_json_array_manifest_fails(self):
        (self.root / "Platforms/Web/package.json").write_text("[]")
        self.assert_rejected("expected an object")


if __name__ == "__main__":
    unittest.main()
