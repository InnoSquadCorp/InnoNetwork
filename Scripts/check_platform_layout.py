#!/usr/bin/env python3
"""Check the native package roots without building or publishing a package."""

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import sys


ANDROID_MODULES = (
    "innonetwork", "innonetwork-client", "innonetwork-ksp",
    "innonetwork-kotlinx-serialization",
)
REQUIRED_FILES = (
    "Package.swift", "Package.resolved", "LICENSE",
    "Platforms/Android/settings.gradle.kts", "Platforms/Android/build.gradle.kts",
    "Platforms/Android/gradlew", "Platforms/Android/gradlew.bat",
    "Platforms/Android/gradle/wrapper/gradle-wrapper.jar",
    "Platforms/Android/gradle/wrapper/gradle-wrapper.properties",
    "Platforms/Web/package.json", "Platforms/Web/LICENSE",
    "SmokeTests/AndroidConsumer/settings.gradle.kts",
    "SmokeTests/WebConsumer/package.json", "SmokeTests/ReactConsumer/package.json",
) + tuple(f"Platforms/Android/{module}/build.gradle.kts" for module in ANDROID_MODULES)
REQUIRED_DIRS = ("Sources", "Tests", "Platforms/Web/src") + tuple(
    f"Platforms/Android/{module}/src/main" for module in ANDROID_MODULES
)


def validate(root: Path) -> list[str]:
    root = root.resolve()
    errors = []
    for relative, is_file in [(p, True) for p in REQUIRED_FILES] + [
        (p, False) for p in REQUIRED_DIRS
    ]:
        path = root / relative
        exists = path.is_file() if is_file else path.is_dir()
        if not exists or path.is_symlink() or not path.resolve().is_relative_to(root):
            errors.append(f"missing, redirected or invalid package path: {relative}")
    if errors:
        return errors

    def read_json(relative):
        try:
            value = json.loads((root / relative).read_text(encoding="utf-8"))
            if not isinstance(value, dict):
                raise ValueError("expected an object")
            return value
        except (OSError, ValueError) as error:
            errors.append(f"invalid package manifest {relative}: {error}")
            return {}

    def settings_text(relative):
        text = (root / relative).read_text(encoding="utf-8")
        return re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.DOTALL)

    settings = settings_text("Platforms/Android/settings.gradle.kts")
    for module in ANDROID_MODULES:
        if not re.search(r'include\(\s*":' + re.escape(module) + r'"\s*\)', settings):
            errors.append(f"Android settings no longer includes :{module}")

    consumer_root = root / "SmokeTests/AndroidConsumer"
    consumer_settings = settings_text("SmokeTests/AndroidConsumer/settings.gradle.kts")
    composite_paths = re.findall(r'includeBuild\(\s*"([^"]+)"\s*\)', consumer_settings)
    preview_paths = re.findall(r'file\(\s*"([^"]*preview-repository)"\s*\)', consumer_settings)
    if len(composite_paths) != 1 or (consumer_root / composite_paths[0]).resolve() != root / "Platforms/Android":
        errors.append("Android consumer composite must point to Platforms/Android")
    if len(preview_paths) != 1 or (consumer_root / preview_paths[0]).resolve() != root / "Platforms/Android/build/preview-repository":
        errors.append("Android consumer Maven preview must point to its native build repository")

    web = read_json("Platforms/Web/package.json")
    if web.get("name") != "@innosquad/innonetwork" or web.get("private") is True:
        errors.append("Web manifest must identify the publishable @innosquad/innonetwork package")
    repository = web.get("repository", {})
    if not isinstance(repository, dict) or repository.get("directory") != "Platforms/Web":
        errors.append("Web repository.directory must remain Platforms/Web")
    files = web.get("files", [])
    allowed_files = {"dist", "src", "README.md", "LICENSE"}
    if (not isinstance(files, list) or not all(isinstance(p, str) for p in files)
            or not {"dist", "src"}.issubset(files)
            or any(p not in allowed_files for p in files)):
        errors.append("Web files must include dist/src and exclude repository or consumer trees")

    exports = web.get("exports", {})
    entry = exports.get(".", {}) if isinstance(exports, dict) else {}
    entries = {
        "main": web.get("main"), "types": web.get("types"),
        "exports.types": entry.get("types") if isinstance(entry, dict) else None,
        "exports.import": entry.get("import") if isinstance(entry, dict) else None,
    }
    for name, value in entries.items():
        if (not isinstance(value, str) or not value.startswith("./dist/")
                or ".." in PurePosixPath(value).parts or "\\" in value
                or not (root / "Platforms/Web" / value).resolve().is_relative_to(
                    root / "Platforms/Web/dist"
                )):
            errors.append(f"Web {name} must resolve inside its own ./dist directory")
    if (root / "Platforms/Web/LICENSE").read_bytes() != (root / "LICENSE").read_bytes():
        errors.append("Web LICENSE differs from the repository license")

    for consumer in ("WebConsumer", "ReactConsumer"):
        relative = f"SmokeTests/{consumer}/package.json"
        manifest = read_json(relative)
        if manifest.get("private") is not True:
            errors.append(f"{consumer} must remain a private consumer fixture")
        dependencies = manifest.get("dependencies", {})
        dependency = dependencies.get("@innosquad/innonetwork") if isinstance(dependencies, dict) else None
        if not isinstance(dependency, str) or not dependency.startswith("file:"):
            errors.append(f"{consumer} must reference the local Web package explicitly")
        elif (root / "SmokeTests" / consumer / dependency[5:]).resolve() != root / "Platforms/Web":
            errors.append(f"{consumer} package dependency points outside Platforms/Web")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        errors = validate(args.root)
    except (OSError, UnicodeError) as error:
        errors = [f"cannot read package layout: {error}"]
    if errors:
        for error in errors:
            print(f"platform-layout: {error}", file=sys.stderr)
        return 1
    print("Platform package layout: OK (SwiftPM root; isolated Android/Web; consumer paths)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
