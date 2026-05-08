#!/usr/bin/env python3
"""Append one benchmark report to a JSONL trend log with run metadata."""

from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import json  # noqa: E402  imported after sys.path tweak so JSON helpers stay visible
from _benchmark_report import baseline_section, load_report, parse_two_paths


def main() -> int:
    report_path, trend_path = parse_two_paths(
        sys.argv,
        usage="Usage: append_benchmark_trend.py [results.json] [trend.jsonl]",
    )
    report = load_report(report_path)
    baseline = baseline_section(report)
    record = {
        "recordedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "repository": os.environ.get("GITHUB_REPOSITORY"),
        "workflow": os.environ.get("GITHUB_WORKFLOW"),
        "runId": os.environ.get("GITHUB_RUN_ID"),
        "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "sha": os.environ.get("GITHUB_SHA"),
        "ref": os.environ.get("GITHUB_REF"),
        "eventName": os.environ.get("GITHUB_EVENT_NAME"),
        "regressionReason": baseline.get("regressionReason")
        or os.environ.get("INNO_BENCHMARK_REGRESSION_REASON"),
        "report": report,
    }

    trend_path.parent.mkdir(parents=True, exist_ok=True)
    with trend_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")))
        handle.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
