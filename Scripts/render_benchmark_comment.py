#!/usr/bin/env python3
"""Render an InnoNetwork benchmark JSON report as a compact PR comment."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _benchmark_report import baseline_section, load_report, parse_two_paths  # noqa: E402


def main() -> int:
    report_path, output_path = parse_two_paths(
        sys.argv,
        usage="Usage: render_benchmark_comment.py [results.json] [comment.md]",
    )
    report = load_report(report_path)
    baseline = baseline_section(report)
    deltas = baseline.get("deltas") or []
    failures = baseline.get("guardFailures") or []
    inconclusive = baseline.get("inconclusiveGuards") or []
    confirmed = baseline.get("confirmedGuards") or []
    regression_reason = baseline.get("regressionReason")

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
        if baseline.get("confirmationPairCount"):
            lines.append(
                f"- Confirmation: `{len(confirmed)}` inconclusive guard(s) re-judged on "
                f"`{baseline.get('pairCount')}` pairs"
            )
        if regression_reason:
            lines.append(f"- Regression reason: {regression_reason}")
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
                "| Benchmark | Paired median delta | Pair spread | Spread (head/base) | Threshold | Verdict | Current ops/s | Baseline ops/s |",
                "|---|---:|---:|---:|---:|---|---:|---:|",
            ]
        )
        for item in ordered[:12]:
            group = item.get("group", "?")
            bench_name = item.get("name", "?")
            name = f"{group}/{bench_name}"
            delta = item.get("deltaPercent", 0.0)
            current = item.get("currentOperationsPerSecond", 0.0)
            baseline_ops = item.get("baselineOperationsPerSecond", 0.0)
            threshold = item.get("maxRegressionPercent")
            threshold_text = f"{threshold:.2f}%" if threshold is not None else "-"
            paired_spread = item.get("pairedDeltaSpreadPercent")
            paired_spread_text = (
                f"{paired_spread:.1f}%" if paired_spread is not None else "-"
            )
            head_spread = item.get("currentRelativeSpreadPercent")
            base_spread = item.get("baselineRelativeSpreadPercent")
            spread_text = (
                f"{head_spread:.1f}%/{base_spread:.1f}%"
                if head_spread is not None and base_spread is not None
                else "-"
            )
            guard = " (guard)" if item.get("isGuarded") else ""
            verdict = item.get("guardVerdict") or "-"
            if item.get("primaryGuardVerdict") == "inconclusive" and verdict != "inconclusive":
                verdict += " (confirmed)"
            lines.append(
                f"| `{name}`{guard} | {delta:+.2f}% | {paired_spread_text} | {spread_text} | {threshold_text} "
                f"| {verdict} | {current:.2f} | {baseline_ops:.2f} |"
            )

    if confirmed:
        lines.extend(["", "### Confirmed inconclusive guards"])
        for item in confirmed:
            identifier = item.get("identifier") or {}
            name = f"{identifier.get('group', '?')}/{identifier.get('name', '?')}"
            lines.append(
                f"- `{name}`: primary median {item.get('primaryDeltaPercent', 0.0):+.2f}% with "
                f"disagreeing pairs; {item.get('pairCount')}-pair median "
                f"{item.get('deltaPercent', 0.0):+.2f}% -> {item.get('guardVerdict')}."
            )

    if inconclusive and not failures:
        lines.extend(["", "### Inconclusive guards"])
        for item in inconclusive:
            identifier = item.get("identifier") or {}
            name = f"{identifier.get('group', '?')}/{identifier.get('name', '?')}"
            pairs = ", ".join(f"{delta:+.2f}%" for delta in item.get("pairedDeltasPercent") or [])
            lines.append(
                f"- `{name}`: median {item.get('primaryDeltaPercent', 0.0):+.2f}% but pairs disagree "
                f"({pairs}); confirmation pairs are required."
            )

    if failures:
        lines.extend(["", "### Regression guard failures"])
        for failure in failures:
            identifier = failure.get("identifier") or {}
            group = identifier.get("group", "?")
            bench_name = identifier.get("name", "?")
            name = f"{group}/{bench_name}"
            delta = abs(failure.get("deltaPercent", 0.0))
            limit = failure.get("maxRegressionPercent", 0.0)
            reason = failure.get("regressionReason") or regression_reason
            reason_text = f" Reason: {reason}" if reason else ""
            lines.append(
                f"- `{name}` regressed by {delta:.2f}% "
                f"(limit {limit:.2f}%).{reason_text}"
            )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
