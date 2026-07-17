from __future__ import annotations

import collections
import json
import pathlib
import re
from typing import List


class GuardedBenchmarkContractError(ValueError):
    """Raised when the guarded benchmark source of truth is invalid."""


_IDENTIFIER_PATTERN = re.compile(
    r"[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*"
)


def load_guarded_benchmarks(repo_root: pathlib.Path) -> List[str]:
    contract_path = repo_root / "Benchmarks/guarded-benchmarks.txt"
    baseline_path = repo_root / "Benchmarks/Baselines/default.json"

    if not contract_path.is_file():
        raise GuardedBenchmarkContractError(
            f"guard set is missing: {contract_path}"
        )

    raw_lines = contract_path.read_text(encoding="utf-8").splitlines()
    if not raw_lines:
        raise GuardedBenchmarkContractError(
            f"guard set is empty: {contract_path}"
        )
    if any(not line or line != line.strip() for line in raw_lines):
        raise GuardedBenchmarkContractError(
            "guard entries must be nonempty lines without surrounding whitespace"
        )

    invalid = [
        entry
        for entry in raw_lines
        if _IDENTIFIER_PATTERN.fullmatch(entry) is None
    ]
    if invalid:
        raise GuardedBenchmarkContractError(
            f"invalid group/name identifier(s): {', '.join(invalid)}"
        )

    duplicates = [
        entry
        for entry, count in collections.Counter(raw_lines).items()
        if count > 1
    ]
    if duplicates:
        raise GuardedBenchmarkContractError(
            "duplicate guard identifier(s): " + ", ".join(sorted(duplicates))
        )

    if not baseline_path.is_file():
        raise GuardedBenchmarkContractError(
            f"default baseline is missing: {baseline_path}"
        )
    try:
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GuardedBenchmarkContractError(
            f"default baseline is unreadable: {error}"
        ) from error

    results = baseline.get("results") if isinstance(baseline, dict) else None
    if not isinstance(results, list):
        raise GuardedBenchmarkContractError(
            "default baseline must contain a results array"
        )

    baseline_identifiers = {
        f"{result['group']}/{result['name']}"
        for result in results
        if isinstance(result, dict)
        and isinstance(result.get("group"), str)
        and isinstance(result.get("name"), str)
    }
    missing_from_baseline = sorted(set(raw_lines) - baseline_identifiers)
    if missing_from_baseline:
        raise GuardedBenchmarkContractError(
            "guard identifier(s) missing from the default baseline: "
            + ", ".join(missing_from_baseline)
        )

    return raw_lines
