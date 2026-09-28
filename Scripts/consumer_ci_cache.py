#!/usr/bin/env python3
"""Conservative SwiftPM cache scope; a hit never replaces a build or test."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

LANES = ("examples", "macros", "openapi")
DEPENDENCY_PATHS = [".build/checkouts", ".build/repositories", ".build/artifacts"]


def package_directories(root):
    # Deliberately shallow: never hash build products or downloaded packages.
    return [root, *sorted((root / "Examples").glob("*/Package.swift")),
            *sorted((root / "Tests/MacroCompileFailureFixtures").glob("*/Package.swift")),
            root / "Tools/openapi-to-innonetwork/Package.swift"]


def cache_spec(root, lane, context):
    if lane not in LANES:
        raise ValueError(f"unsupported consumer cache lane: {lane}")
    root = root.resolve()
    inputs = {}
    for entry in package_directories(root):
        directory = entry if entry == root else entry.parent
        if not (directory / "Package.swift").is_file():
            raise ValueError(f"missing package manifest: {directory}")
        for name in ("Package.swift", "Package.resolved"):
            path = directory / name
            inputs[str(path.relative_to(root))] = (
                hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "absent"
            )
    if lane == "examples":
        paths = [str(p.parent.relative_to(root) / ".build")
                 for p in sorted((root / "Examples").glob("*/Package.swift"))]
        if not paths:
            raise ValueError("no consumer examples discovered")
        paths += DEPENDENCY_PATHS
    elif lane == "openapi":
        paths = ["Tools/openapi-to-innonetwork/.build", *DEPENDENCY_PATHS]
    else:
        # Macro coverage and negative fixtures must start with fresh test outputs.
        # Do not restore profile data, logs, test results, or root compiled products.
        paths = list(DEPENDENCY_PATHS)
    payload = {"lane": lane, "context": context, "workspace": str(root),
               "inputs": inputs, "paths": paths, "configuration": "debug-default-traits"}
    # Changing cache/build policy invalidates old compiled entries as well.
    policy_paths = [".github/workflows/ci.yml", ".github/actions/consumer-cache/action.yml",
                    "Scripts/build_consumer_examples.sh", "Scripts/consumer_ci_cache.py"]
    payload["policy"] = {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                         if (root / name).is_file() else "absent" for name in policy_paths}
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
    return {"prefix": f"consumer-v1-{lane}-{digest}-", "paths": paths}


def toolchain_context():
    commands = {
        "xcode": ["xcodebuild", "-version"],
        "swift": ["xcrun", "swift", "--version"],
        "sdk": ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"],
        "arch": ["uname", "-m"],
        "os": ["sw_vers", "-buildVersion"],
    }
    result = {key: subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()
              for key, command in commands.items()}
    result["runner_image"] = os.environ.get("ImageVersion", "local")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane", choices=LANES)
    parser.add_argument("--github-output", action="store_true")
    args = parser.parse_args()
    context = toolchain_context()
    spec = cache_spec(Path(__file__).resolve().parent.parent, args.lane, context)
    print(json.dumps({**spec, "context": context}, indent=2))
    if args.github_output:
        # Only hashed keys and repository-controlled paths are action outputs.
        paths = spec["paths"]
        if any("\n" in p or "\r" in p for p in paths):
            raise ValueError("cache paths must be single-line")
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"prefix={spec['prefix']}\npaths<<CONSUMER_CACHE_PATHS\n")
            output.write("\n".join(paths) + "\nCONSUMER_CACHE_PATHS\n")


if __name__ == "__main__":
    main()
