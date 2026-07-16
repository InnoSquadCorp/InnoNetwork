#!/usr/bin/env python3
"""Compare median benchmark results from interleaved base and head samples."""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _benchmark_report import load_report  # noqa: E402

Identifier = tuple[str, str]


def identifier(result: dict) -> Identifier:
    return str(result["group"]), str(result["name"])


def identifier_text(value: Identifier) -> str:
    return f"{value[0]}/{value[1]}"


def parse_identifier(raw: str) -> Identifier:
    group, separator, name = raw.partition("/")
    if not separator or not group or not name:
        raise argparse.ArgumentTypeError(
            f"invalid benchmark identifier '{raw}'; expected group/name"
        )
    return group, name


def result_map(report: dict, label: str) -> tuple[list[Identifier], dict[Identifier, dict]]:
    results = report.get("results")
    if not isinstance(results, list) or not results:
        raise ValueError(f"{label} has no benchmark results")

    order: list[Identifier] = []
    mapped: dict[Identifier, dict] = {}
    for result in results:
        value = identifier(result)
        if value in mapped:
            raise ValueError(f"{label} contains duplicate benchmark {identifier_text(value)}")
        order.append(value)
        mapped[value] = result
    return order, mapped


def median_optional_int(results: list[dict], key: str) -> int | None:
    values = [result[key] for result in results if result.get(key) is not None]
    if not values:
        return None
    return int(statistics.median(values))


def aggregate_reports(reports: list[dict], label: str) -> dict:
    if len(reports) < 3 or len(reports) % 2 == 0:
        raise ValueError(f"{label} requires an odd sample count of at least 3")

    versions = {report.get("version") for report in reports}
    if len(versions) != 1:
        raise ValueError(f"{label} reports use different schema versions")

    order, first = result_map(reports[0], f"{label} sample 1")
    maps = [first]
    for index, report in enumerate(reports[1:], start=2):
        _, mapped = result_map(report, f"{label} sample {index}")
        if set(mapped) != set(first):
            raise ValueError(f"{label} sample {index} has a different benchmark set")
        maps.append(mapped)

    aggregated: list[dict] = []
    for value in order:
        samples = [mapped[value] for mapped in maps]
        iterations = {int(sample["iterations"]) for sample in samples}
        if len(iterations) != 1:
            raise ValueError(
                f"{label} samples use different iteration counts for {identifier_text(value)}"
            )
        operations_per_second = float(
            statistics.median(float(sample["operationsPerSecond"]) for sample in samples)
        )
        iteration_count = iterations.pop()
        aggregated.append(
            {
                "name": value[1],
                "group": value[0],
                "iterations": iteration_count,
                "elapsedSeconds": iteration_count / max(operations_per_second, 0.000_001),
                "operationsPerSecond": operations_per_second,
                "peakResidentBytes": median_optional_int(samples, "peakResidentBytes"),
                "residentDeltaBytes": median_optional_int(samples, "residentDeltaBytes"),
            }
        )

    return {
        "version": reports[0].get("version"),
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "results": aggregated,
    }


def build_comparison_report(
    base_reports: list[dict],
    head_reports: list[dict],
    guarded: set[Identifier],
    max_regression_percent: float,
    regression_reason: str | None = None,
) -> dict:
    if len(base_reports) != len(head_reports):
        raise ValueError("base and head require the same sample count")

    base = aggregate_reports(base_reports, "base")
    head = aggregate_reports(head_reports, "head")
    if base["version"] != head["version"]:
        raise ValueError("base and head reports use different schema versions")

    _, base_map = result_map(base, "aggregated base")
    _, head_map = result_map(head, "aggregated head")
    missing_guarded = guarded - (set(base_map) & set(head_map))
    if missing_guarded:
        missing = ", ".join(sorted(identifier_text(value) for value in missing_guarded))
        raise ValueError(f"guarded benchmark missing from base or head: {missing}")

    deltas: list[dict] = []
    failures: list[dict] = []
    for result in head["results"]:
        value = identifier(result)
        baseline = base_map.get(value)
        if baseline is None:
            continue
        baseline_ops = float(baseline["operationsPerSecond"])
        current_ops = float(result["operationsPerSecond"])
        delta = ((current_ops - baseline_ops) / max(baseline_ops, 0.000_001)) * 100.0
        is_guarded = value in guarded
        deltas.append(
            {
                "group": value[0],
                "name": value[1],
                "baselineOperationsPerSecond": baseline_ops,
                "currentOperationsPerSecond": current_ops,
                "deltaPercent": delta,
                "isGuarded": is_guarded,
                "maxRegressionPercent": max_regression_percent if is_guarded else None,
            }
        )
        if is_guarded and delta < -max_regression_percent:
            failures.append(
                {
                    "identifier": {"group": value[0], "name": value[1]},
                    "deltaPercent": delta,
                    "maxRegressionPercent": max_regression_percent,
                    "regressionReason": regression_reason,
                }
            )

    head["baseline"] = {
        "baselinePath": f"same-runner median ({len(base_reports)} base samples)",
        "enforceBaseline": True,
        "maxRegressionPercent": max_regression_percent,
        "guardThresholds": [],
        "regressionReason": regression_reason,
        "deltas": deltas,
        "guardFailures": failures,
    }
    return head


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", action="append", required=True, type=Path)
    parser.add_argument("--head", action="append", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--guard-benchmark", action="append", default=[], type=parse_identifier)
    parser.add_argument("--max-regression-percent", required=True, type=float)
    parser.add_argument(
        "--regression-reason",
        default=os.environ.get("INNO_BENCHMARK_REGRESSION_REASON"),
    )
    arguments = parser.parse_args()
    if arguments.max_regression_percent < 0:
        parser.error("--max-regression-percent must be non-negative")
    return arguments


def main() -> int:
    arguments = parse_arguments()
    try:
        report = build_comparison_report(
            [load_report(path) for path in arguments.base],
            [load_report(path) for path in arguments.head],
            set(arguments.guard_benchmark),
            arguments.max_regression_percent,
            arguments.regression_reason,
        )
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"benchmark comparison failed: {error}", file=sys.stderr)
        return 2

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    failures = report["baseline"]["guardFailures"]
    if failures:
        for failure in failures:
            value = failure["identifier"]
            print(
                f"{value['group']}/{value['name']} regressed by "
                f"{abs(failure['deltaPercent']):.2f}% "
                f"(limit {failure['maxRegressionPercent']:.2f}%)",
                file=sys.stderr,
            )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
