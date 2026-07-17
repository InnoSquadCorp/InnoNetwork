#!/usr/bin/env bash
set -euo pipefail

repo_root="${INNO_GUARDED_BENCHMARK_CONTRACT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

python3 - "$repo_root" <<'PY'
import collections
import json
import pathlib
import re
import sys


repo_root = pathlib.Path(sys.argv[1])
contract_path = repo_root / "Benchmarks/guarded-benchmarks.txt"
baseline_path = repo_root / "Benchmarks/Baselines/default.json"


def fail(message: str) -> None:
    print(f"guarded-benchmark-contract: {message}", file=sys.stderr)
    raise SystemExit(1)


raw_lines = contract_path.read_text(encoding="utf-8").splitlines()
if not raw_lines:
    fail(f"guard set is empty: {contract_path}")
if any(not line or line != line.strip() for line in raw_lines):
    fail("guard entries must be nonempty lines without surrounding whitespace")

identifier_pattern = re.compile(r"[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*")
invalid = [entry for entry in raw_lines if identifier_pattern.fullmatch(entry) is None]
if invalid:
    fail(f"invalid group/name identifier(s): {', '.join(invalid)}")

duplicates = [
    entry
    for entry, count in collections.Counter(raw_lines).items()
    if count > 1
]
if duplicates:
    fail(f"duplicate guard identifier(s): {', '.join(sorted(duplicates))}")

with baseline_path.open(encoding="utf-8") as source:
    baseline = json.load(source)
baseline_identifiers = {
    f"{result['group']}/{result['name']}"
    for result in baseline.get("results", [])
    if isinstance(result, dict) and "group" in result and "name" in result
}
missing_from_baseline = sorted(set(raw_lines) - baseline_identifiers)
if missing_from_baseline:
    fail(
        "guard identifier(s) missing from the default baseline: "
        + ", ".join(missing_from_baseline)
    )

declaration_contracts = {
    ".github/workflows/benchmarks.yml": 2,
    ".github/workflows/release.yml": 1,
    "Scripts/run_local_release_preflight.sh": 1,
    "docs/CI_DoC.md": 1,
}
declaration_pattern = re.compile(r"--guard-benchmark\s+([^\s\\]+)")
expected_once = collections.Counter(raw_lines)

for relative_path, copies in declaration_contracts.items():
    source_path = repo_root / relative_path
    declared = declaration_pattern.findall(source_path.read_text(encoding="utf-8"))
    actual = collections.Counter(declared)
    expected = collections.Counter(
        {
            identifier: count * copies
            for identifier, count in expected_once.items()
        }
    )
    if actual == expected:
        continue

    missing = list((expected - actual).elements())
    unexpected = list((actual - expected).elements())
    details = []
    if missing:
        details.append("missing " + ", ".join(sorted(missing)))
    if unexpected:
        details.append("unexpected " + ", ".join(sorted(unexpected)))
    fail(f"{relative_path} does not match the guard set ({'; '.join(details)})")

print(
    "guarded-benchmark-contract: OK "
    f"({len(raw_lines)} guards across {len(declaration_contracts)} consumers)"
)
PY
