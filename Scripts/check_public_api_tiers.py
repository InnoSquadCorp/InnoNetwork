#!/usr/bin/env python3
"""Validate the Stable / Provisionally Stable / SPI public API budgets."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path


Row = tuple[str, str, str]


@dataclass(frozen=True)
class Rule:
    mode: str
    module: str
    path: str

    def matches(self, row: Row) -> bool:
        module, _, symbol_path = row
        if module != self.module:
            return False
        if self.mode == "exact":
            return symbol_path == self.path
        return symbol_path == self.path or symbol_path.startswith(f"{self.path}.")


def fail(message: str) -> None:
    raise SystemExit(f"public-api-tiers: {message}")


def load_rows(paths: list[Path]) -> set[Row]:
    rows: set[Row] = set()
    for path in paths:
        for line_number, raw_line in enumerate(path.read_text().splitlines(), start=1):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            parts = tuple(line.split("\t"))
            if len(parts) != 3:
                fail(f"{path}:{line_number} must contain module, kind, and path")
            rows.add(parts)  # type: ignore[arg-type]
    return rows


def load_rules(path: Path) -> list[Rule]:
    rules: list[Rule] = []
    for line_number, raw_line in enumerate(path.read_text().splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3 or parts[0] not in {"exact", "prefix"}:
            fail(f"{path}:{line_number} must contain exact|prefix, module, and path")
        rules.append(Rule(*parts))
    return rules


def load_budgets(path: Path) -> dict[str, int]:
    budgets: dict[str, int] = {}
    for line_number, raw_line in enumerate(path.read_text().splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 2 or not parts[1].isdigit():
            fail(f"{path}:{line_number} must contain tier and non-negative budget")
        budgets[parts[0]] = int(parts[1])
    expected = {"STABLE_CONSUMER", "PROVISIONAL", "SPI", "TOTAL"}
    if set(budgets) != expected:
        fail(f"{path} must define exactly {', '.join(sorted(expected))}")
    return budgets


def validate_documented_counts(repo_root: Path, counts: dict[str, int]) -> None:
    api_stability = repo_root / "API_STABILITY.md"
    symbols_readme = repo_root / "Scripts" / "symbols" / "README.md"
    for path in (api_stability, symbols_readme):
        if not path.is_file():
            fail(f"required public API contract document is missing: {path}")

    stable = counts["STABLE_CONSUMER"]
    provisional = counts["PROVISIONAL"]
    spi = counts["SPI"]
    total = counts["TOTAL"]

    expected_ledger = (
        f"The machine-checked snapshot currently partitions all {total:,} declarations into\n"
        f"{stable:,} Stable consumer declarations, {provisional:,} Provisionally Stable consumer\n"
        f"declarations, and {spi:,} opt-in SPI declarations."
    )
    if expected_ledger not in api_stability.read_text():
        fail(
            "API_STABILITY.md public declaration ledger does not match the "
            f"machine inventory ({total:,} = {stable:,} stable + "
            f"{provisional:,} provisional + {spi:,} SPI)"
        )

    symbols_snapshot = symbols_readme.read_text()
    expected_rows = (
        f"| Stable consumer API | {stable:,} |",
        f"| Provisionally Stable consumer API | {provisional:,} |",
        f"| `@_spi(GeneratedClientSupport)` | {spi:,} |",
        f"| **Total** | **{total:,}** |",
    )
    for row in expected_rows:
        if row not in symbols_snapshot:
            fail(f"Scripts/symbols/README.md is missing current tier row: {row}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "repo_root", nargs="?", type=Path, default=Path(__file__).resolve().parent.parent
    )
    args = parser.parse_args()
    repo_root = args.repo_root.resolve()
    symbols_dir = repo_root / "Scripts" / "symbols"

    allowlists = sorted(symbols_dir.glob("*.allowlist"))
    if not allowlists:
        fail(f"no product allowlists found in {symbols_dir}")
    all_rows = load_rows(allowlists)
    spi_rows = load_rows([symbols_dir / "spi-symbols.tsv"])
    unknown_spi = spi_rows - all_rows
    if unknown_spi:
        fail(f"SPI inventory contains {len(unknown_spi)} rows absent from product allowlists")

    consumer_rows = all_rows - spi_rows
    stable_rules = load_rules(symbols_dir / "stable-rules.tsv")
    stable_rows: set[Row] = set()
    for rule in stable_rules:
        matches = {row for row in consumer_rows if rule.matches(row)}
        if not matches:
            fail(f"stable rule matches no consumer symbol: {rule.module} {rule.path}")
        stable_rows.update(matches)

    provisional_rows = consumer_rows - stable_rows
    counts = {
        "STABLE_CONSUMER": len(stable_rows),
        "PROVISIONAL": len(provisional_rows),
        "SPI": len(spi_rows),
        "TOTAL": len(all_rows),
    }
    if sum(counts[tier] for tier in ("STABLE_CONSUMER", "PROVISIONAL", "SPI")) != counts["TOTAL"]:
        fail("tier sets are not a disjoint, exhaustive partition")

    budgets = load_budgets(symbols_dir / "tier-budgets.tsv")
    for tier, actual in counts.items():
        if actual > budgets[tier]:
            fail(f"{tier} exports {actual} declarations (budget: {budgets[tier]})")

    validate_documented_counts(repo_root, counts)

    print(
        "public-api-tiers: OK "
        f"(stable consumer {counts['STABLE_CONSUMER']}/{budgets['STABLE_CONSUMER']}, "
        f"provisional {counts['PROVISIONAL']}/{budgets['PROVISIONAL']}, "
        f"SPI {counts['SPI']}/{budgets['SPI']}, total {counts['TOTAL']}/{budgets['TOTAL']})"
    )


if __name__ == "__main__":
    main()
