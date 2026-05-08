"""Shared helpers for InnoNetwork benchmark CLI scripts.

Both ``append_benchmark_trend.py`` and ``render_benchmark_comment.py`` consume
the same JSON report shape produced by ``InnoNetworkBenchmarks --json-path``.
This module centralises argv parsing, report loading, and the
``baseline`` subsection accessor so the call sites stay focused on their
specific output (JSONL trend log vs. PR comment markdown).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def parse_two_paths(argv: list[str], usage: str) -> tuple[Path, Path]:
    """Return the two positional path arguments, or print ``usage`` and exit 2.

    Mirrors the ``argv != 3`` check both scripts already had inline so the
    callers can still take exactly the same usage string they always did.
    """
    if len(argv) != 3:
        print(usage, file=sys.stderr)
        raise SystemExit(2)
    return Path(argv[1]), Path(argv[2])


def load_report(path: Path) -> dict:
    """Load an InnoNetwork benchmark JSON report from ``path``."""
    return json.loads(path.read_text(encoding="utf-8"))


def baseline_section(report: dict) -> dict:
    """Return the ``baseline`` subsection of ``report``, defaulting to ``{}``.

    The benchmark runner omits the section when no baseline file was loaded;
    the empty dict keeps existing ``.get(...)`` chains working without
    additional ``None`` guards.
    """
    return report.get("baseline") or {}
