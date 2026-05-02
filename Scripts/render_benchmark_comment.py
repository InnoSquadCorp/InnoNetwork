#!/usr/bin/env python3
"""Render an InnoNetwork benchmark JSON report as a compact PR comment."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "Usage: render_benchmark_comment.py [results.json] [comment.md]",
            file=sys.stderr,
        )
        return 2

    report_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    report = json.loads(report_path.read_text(encoding="utf-8"))
    baseline = report.get("baseline") or {}
    deltas = baseline.get("deltas") or []
    failures = baseline.get("guardFailures") or []

    lines: list[str] = [
        "## InnoNetwork benchmark summary",
        "",
        f"- Generated: `{report.get('generatedAt', 'unknown')}`",
        f"- Results: `{len(report.get('results') or [])}` benchmarks",
    ]
    if baseline:
        lines.append(f"- Baseline: `{baseline.get('baselinePath', 'unknown')}`")
        lines.append(
            f"- Guard failures: `{len(failures)}`"
        )
    else:
        lines.append("- Baseline: not loaded")

    if deltas:
        guarded = [item for item in deltas if item.get("isGuarded")]
        ordered = sorted(
            guarded or deltas,
            key=lambda item: item.get("deltaPercent", 0.0),
        )
        lines.extend(
            [
                "",
                "| Benchmark | Delta | Current ops/s | Baseline ops/s |",
                "|---|---:|---:|---:|",
            ]
        )
        for item in ordered[:12]:
            name = f"{item['group']}/{item['name']}"
            delta = item.get("deltaPercent", 0.0)
            current = item.get("currentOperationsPerSecond", 0.0)
            baseline_ops = item.get("baselineOperationsPerSecond", 0.0)
            guard = " (guard)" if item.get("isGuarded") else ""
            lines.append(
                f"| `{name}`{guard} | {delta:+.2f}% | {current:.2f} | {baseline_ops:.2f} |"
            )

    if failures:
        lines.extend(["", "### Regression guard failures"])
        for failure in failures:
            identifier = failure["identifier"]
            name = f"{identifier['group']}/{identifier['name']}"
            lines.append(
                f"- `{name}` regressed by {abs(failure['deltaPercent']):.2f}% "
                f"(limit {failure['maxRegressionPercent']:.2f}%)."
            )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
