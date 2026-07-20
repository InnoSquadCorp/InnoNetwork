#!/usr/bin/env bash
set -euo pipefail

repo_root="${INNO_GUARDED_BENCHMARK_CONTRACT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

python3 - "$repo_root" <<'PY'
import pathlib
import re
import sys


sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "Scripts"))
from guarded_benchmarks import (  # noqa: E402
    GuardedBenchmarkContractError,
    load_guarded_benchmarks,
)

repo_root = pathlib.Path(sys.argv[1])


def fail(message: str) -> None:
    print(f"guarded-benchmark-contract: {message}", file=sys.stderr)
    raise SystemExit(1)


try:
    raw_lines = load_guarded_benchmarks(repo_root)
except GuardedBenchmarkContractError as error:
    fail(str(error))

runner_path = "Scripts/run_same_runner_benchmarks.sh"
wrapper_pattern = re.compile(
    r"python3\s+Scripts/run_with_guarded_benchmarks\.py\s+--"
)
consumer_contracts = {
    ".github/workflows/benchmarks.yml": 1,
    ".github/workflows/release.yml": 1,
    "Scripts/run_local_release_preflight.sh": 1,
    "docs/CI_DoC.md": 1,
}
consumer_pattern = re.compile(
    r"^\s*(?:bash\s+)?Scripts/run_same_runner_benchmarks\.sh",
    re.MULTILINE,
)
direct_declaration_pattern = re.compile(r"--guard-benchmark\s+[^\s\\]+")

runner_source = (repo_root / runner_path).read_text(encoding="utf-8")
wrapper_invocations = len(wrapper_pattern.findall(runner_source))
if wrapper_invocations != 1:
    fail(
        f"{runner_path} must invoke the guarded benchmark runner once; "
        f"found {wrapper_invocations}"
    )
if direct_declaration_pattern.search(runner_source):
    fail(f"{runner_path} bypasses the guard source of truth")
if runner_source.count(
    '"$repo_root/Benchmarks/InnoNetworkBenchmarks/main.swift"'
) != 1:
    fail(f"{runner_path} must apply the candidate benchmark harness to the base revision")
if runner_source.count("--disable-default-traits") != 2:
    fail(f"{runner_path} must build and resolve the runtime benchmark without macro traits")

for relative_path, expected_invocations in consumer_contracts.items():
    source_path = repo_root / relative_path
    source = source_path.read_text(encoding="utf-8")
    actual_invocations = len(consumer_pattern.findall(source))
    if actual_invocations != expected_invocations:
        fail(
            f"{relative_path} must invoke the same-runner benchmark entry point "
            f"{expected_invocations} time(s); found {actual_invocations}"
        )
    if direct_declaration_pattern.search(source):
        fail(
            f"{relative_path} bypasses the guarded benchmark runner with "
            "a direct --guard-benchmark declaration"
        )

source_revision_path = repo_root / "Benchmarks/Baselines/source-revision.txt"
if not source_revision_path.is_file():
    fail(f"baseline source revision is missing: {source_revision_path}")
source_revision = source_revision_path.read_text(encoding="utf-8")
if re.fullmatch(r"[0-9a-f]{40}\n?", source_revision) is None:
    fail("baseline source revision must be one lowercase 40-character SHA")

print(
    "guarded-benchmark-contract: OK "
    f"({len(raw_lines)} guards across {len(consumer_contracts)} consumers)"
)
PY
