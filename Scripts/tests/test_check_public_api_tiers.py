#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER = REPO_ROOT / "Scripts" / "check_public_api_tiers.py"


def write_fixture(root: Path) -> None:
    symbols = root / "Scripts" / "symbols"
    symbols.mkdir(parents=True)
    (symbols / "core.allowlist").write_text(
        "Module\tswift.struct\tStable\n"
        "Module\tswift.struct\tPreview\n"
        "Module\tswift.protocol\tSPIHook\n"
    )
    (symbols / "stable-rules.tsv").write_text("prefix\tModule\tStable\n")
    (symbols / "spi-symbols.tsv").write_text("Module\tswift.protocol\tSPIHook\n")
    (symbols / "tier-budgets.tsv").write_text(
        "STABLE_CONSUMER\t1\nPROVISIONAL\t1\nSPI\t1\nTOTAL\t3\n"
    )
    (root / "API_STABILITY.md").write_text(
        "The machine-checked snapshot currently partitions all 3 declarations into\n"
        "1 Stable consumer declarations, 1 Provisionally Stable consumer\n"
        "declarations, and 1 opt-in SPI declarations.\n"
    )
    (symbols / "README.md").write_text(
        "| Stable consumer API | 1 |\n"
        "| Provisionally Stable consumer API | 1 |\n"
        "| `@_spi(GeneratedClientSupport)` | 1 |\n"
        "| **Total** | **3** |\n"
    )


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(CHECKER), str(root)],
        check=False,
        capture_output=True,
        text=True,
    )


with tempfile.TemporaryDirectory() as temporary_directory:
    fixture = Path(temporary_directory)
    write_fixture(fixture)
    result = run(fixture)
    assert result.returncode == 0, result.stderr
    assert "stable consumer 1/1, provisional 1/1, SPI 1/1, total 3/3" in result.stdout

with tempfile.TemporaryDirectory() as temporary_directory:
    fixture = Path(temporary_directory)
    write_fixture(fixture)
    (fixture / "Scripts" / "symbols" / "spi-symbols.tsv").write_text(
        "Module\tswift.protocol\tMissingSPI\n"
    )
    result = run(fixture)
    assert result.returncode != 0
    assert "absent from product allowlists" in result.stderr

with tempfile.TemporaryDirectory() as temporary_directory:
    fixture = Path(temporary_directory)
    write_fixture(fixture)
    (fixture / "Scripts" / "symbols" / "stable-rules.tsv").write_text(
        "prefix\tModule\tMissingStableRoot\n"
    )
    result = run(fixture)
    assert result.returncode != 0
    assert "stable rule matches no consumer symbol" in result.stderr

with tempfile.TemporaryDirectory() as temporary_directory:
    fixture = Path(temporary_directory)
    write_fixture(fixture)
    (fixture / "Scripts" / "symbols" / "tier-budgets.tsv").write_text(
        "STABLE_CONSUMER\t1\nPROVISIONAL\t0\nSPI\t1\nTOTAL\t3\n"
    )
    result = run(fixture)
    assert result.returncode != 0
    assert "PROVISIONAL exports 1 declarations" in result.stderr

with tempfile.TemporaryDirectory() as temporary_directory:
    fixture = Path(temporary_directory)
    write_fixture(fixture)
    (fixture / "API_STABILITY.md").write_text(
        "The machine-checked snapshot currently partitions all 4 declarations into\n"
        "1 Stable consumer declarations, 2 Provisionally Stable consumer\n"
        "declarations, and 1 opt-in SPI declarations.\n"
    )
    result = run(fixture)
    assert result.returncode != 0
    assert "public declaration ledger does not match" in result.stderr

with tempfile.TemporaryDirectory() as temporary_directory:
    fixture = Path(temporary_directory)
    write_fixture(fixture)
    (fixture / "Scripts" / "symbols" / "README.md").write_text(
        "| Stable consumer API | 1 |\n"
        "| Provisionally Stable consumer API | 2 |\n"
        "| `@_spi(GeneratedClientSupport)` | 1 |\n"
        "| **Total** | **4** |\n"
    )
    result = run(fixture)
    assert result.returncode != 0
    assert "missing current tier row" in result.stderr

print("public-api-tier fixtures: OK")
