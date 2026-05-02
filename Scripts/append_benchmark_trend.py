#!/usr/bin/env python3
"""Append one benchmark report to a JSONL trend log with run metadata."""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "Usage: append_benchmark_trend.py [results.json] [trend.jsonl]",
            file=sys.stderr,
        )
        return 2

    report_path = Path(sys.argv[1])
    trend_path = Path(sys.argv[2])
    report = json.loads(report_path.read_text(encoding="utf-8"))
    record = {
        "recordedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "repository": os.environ.get("GITHUB_REPOSITORY"),
        "workflow": os.environ.get("GITHUB_WORKFLOW"),
        "runId": os.environ.get("GITHUB_RUN_ID"),
        "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "sha": os.environ.get("GITHUB_SHA"),
        "ref": os.environ.get("GITHUB_REF"),
        "eventName": os.environ.get("GITHUB_EVENT_NAME"),
        "report": report,
    }

    trend_path.parent.mkdir(parents=True, exist_ok=True)
    with trend_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")))
        handle.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
