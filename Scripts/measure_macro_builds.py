#!/usr/bin/env python3
"""Measure clean and incremental consumer builds with and without macros."""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class Measurement:
    profile: str
    driver: str
    endpoint_count: int
    phase: str
    samples_seconds: list[float]
    median_seconds: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--driver", choices=("swiftpm", "xcode"), default="swiftpm")
    parser.add_argument("--repeat", type=int, default=5)
    parser.add_argument("--endpoint-counts", default="0,10,50,200")
    parser.add_argument("--json-path")
    return parser.parse_args()


def package_manifest(repository: Path, macros_enabled: bool) -> str:
    traits = "" if macros_enabled else ", traits: []"
    return f'''// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacroBuildHost",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "InnoNetwork", path: "{repository}"{traits})
    ],
    targets: [
        .executableTarget(
            name: "MacroBuildHost",
            dependencies: [.product(name: "InnoNetwork", package: "InnoNetwork")]
        )
    ],
    swiftLanguageModes: [.v6]
)
'''


def source(endpoint_count: int, edited: bool) -> str:
    declarations: list[str] = []
    for index in range(endpoint_count):
        version = "/v2" if edited and index == endpoint_count - 1 else ""
        declarations.append(
            f'''@APIDefinition(
    method: HTTPMethod.get,
    path: "/benchmark{version}/items/{index}/{{id}}",
    auth: SessionAuthentication.anonymous
)
struct BenchmarkEndpoint{index} {{
    typealias APIResponse = BenchmarkResponse
    let id: Int
}}
'''
        )
    return f'''import InnoNetwork

struct BenchmarkResponse: Decodable, Sendable {{}}

{chr(10).join(declarations)}
print("MacroBuildHost")
'''


def run_build(root: Path, driver: str) -> float:
    if driver == "swiftpm":
        command = [
            "swift",
            "build",
            "--package-path",
            str(root),
            "--scratch-path",
            str(root / ".build"),
        ]
    else:
        command = [
            "xcodebuild",
            "-scheme",
            "MacroBuildHost",
            "-destination",
            "platform=macOS",
            "-derivedDataPath",
            str(root / "DerivedData"),
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ]
    started = time.monotonic()
    completed = subprocess.run(
        command,
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    elapsed = time.monotonic() - started
    if completed.returncode != 0:
        raise SystemExit(completed.stderr)
    return elapsed


def measure_profile(
    repository: Path,
    driver: str,
    endpoint_count: int,
    repeat: int,
) -> list[Measurement]:
    phase_samples: dict[str, list[float]] = {
        "clean": [],
        "noop-incremental": [],
        "endpoint-edit": [],
    }
    macros_enabled = endpoint_count >= 0
    profile = f"macros-{endpoint_count}"
    if endpoint_count == -1:
        endpoint_count = 0
        macros_enabled = False
        profile = "core-only"

    for _ in range(repeat):
        with tempfile.TemporaryDirectory(prefix="innonetwork-macro-build-") as directory:
            root = Path(directory)
            source_directory = root / "Sources" / "MacroBuildHost"
            source_directory.mkdir(parents=True)
            (root / "Package.swift").write_text(
                package_manifest(repository, macros_enabled), encoding="utf-8"
            )
            main = source_directory / "main.swift"
            main.write_text(source(endpoint_count, edited=False), encoding="utf-8")

            phase_samples["clean"].append(run_build(root, driver))
            phase_samples["noop-incremental"].append(run_build(root, driver))
            if endpoint_count > 0:
                main.write_text(source(endpoint_count, edited=True), encoding="utf-8")
                phase_samples["endpoint-edit"].append(run_build(root, driver))

    return [
        Measurement(
            profile=profile,
            driver=driver,
            endpoint_count=endpoint_count,
            phase=phase,
            samples_seconds=samples,
            median_seconds=statistics.median(samples),
        )
        for phase, samples in phase_samples.items()
        if samples
    ]


def main() -> None:
    args = parse_args()
    if args.repeat < 1:
        raise SystemExit("--repeat must be at least 1")
    counts = [int(value) for value in args.endpoint_counts.split(",") if value]
    repository = Path(__file__).resolve().parent.parent
    results: list[Measurement] = []
    for endpoint_count in [-1, *counts]:
        results.extend(
            measure_profile(repository, args.driver, endpoint_count, args.repeat)
        )

    payload = {
        "schemaVersion": 1,
        "driver": args.driver,
        "repeat": args.repeat,
        "results": [asdict(result) for result in results],
    }
    encoded = json.dumps(payload, indent=2, sort_keys=True)
    print(encoded)
    if args.json_path:
        output = Path(args.json_path)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(encoded + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
