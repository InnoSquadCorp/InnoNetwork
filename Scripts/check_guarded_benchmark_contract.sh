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

runner_contracts = {
    ".github/workflows/benchmarks.yml": 2,
    ".github/workflows/release.yml": 1,
    "Scripts/run_local_release_preflight.sh": 1,
    "docs/CI_DoC.md": 1,
}
runner_pattern = re.compile(
    r"python3\s+Scripts/run_with_guarded_benchmarks\.py\s+--"
)
direct_declaration_pattern = re.compile(r"--guard-benchmark\s+[^\s\\]+")

for relative_path, expected_invocations in runner_contracts.items():
    source_path = repo_root / relative_path
    source = source_path.read_text(encoding="utf-8")
    actual_invocations = len(runner_pattern.findall(source))
    if actual_invocations != expected_invocations:
        fail(
            f"{relative_path} must invoke the guarded benchmark runner "
            f"{expected_invocations} time(s); found {actual_invocations}"
        )
    if direct_declaration_pattern.search(source):
        fail(
            f"{relative_path} bypasses the guarded benchmark runner with "
            "a direct --guard-benchmark declaration"
        )

print(
    "guarded-benchmark-contract: OK "
    f"({len(raw_lines)} guards across {len(runner_contracts)} consumers)"
)
PY
