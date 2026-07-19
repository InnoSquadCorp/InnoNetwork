#!/usr/bin/env python3
"""Unit tests for median benchmark comparison."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare_benchmark_runs import build_comparison_report  # noqa: E402


def report(values: dict[str, float], iterations: int = 100) -> dict:
    return {
        "version": 2,
        "generatedAt": "2026-01-01T00:00:00Z",
        "results": [
            {
                "group": "core",
                "name": name,
                "iterations": iterations,
                "elapsedSeconds": iterations / value,
                "operationsPerSecond": value,
                "peakResidentBytes": 1024,
                "residentDeltaBytes": 0,
            }
            for name, value in values.items()
        ],
    }


class CompareBenchmarkRunsTests(unittest.TestCase):
    def test_uses_median_instead_of_outlier(self) -> None:
        comparison = build_comparison_report(
            [report({"request": value}) for value in (100, 200, 300)],
            [report({"request": value}) for value in (80, 210, 400)],
            {("core", "request")},
            20,
        )

        self.assertEqual(comparison["results"][0]["operationsPerSecond"], 210)
        self.assertAlmostEqual(
            comparison["baseline"]["deltas"][0]["deltaPercent"],
            5,
        )
        self.assertEqual(comparison["baseline"]["guardFailures"], [])

    def test_reports_relative_spread_across_samples(self) -> None:
        comparison = build_comparison_report(
            [report({"request": value}) for value in (100, 200, 300)],
            [report({"request": value}) for value in (190, 200, 210)],
            {("core", "request")},
            20,
        )

        # base spread: (300 - 100) / 200 = 100%; head: (210 - 190) / 200 = 10%
        self.assertAlmostEqual(comparison["results"][0]["relativeSpreadPercent"], 10)
        delta = comparison["baseline"]["deltas"][0]
        self.assertAlmostEqual(delta["baselineRelativeSpreadPercent"], 100)
        self.assertAlmostEqual(delta["currentRelativeSpreadPercent"], 10)

    def test_reports_guarded_median_regression(self) -> None:
        comparison = build_comparison_report(
            [report({"request": value}) for value in (99, 100, 101)],
            [report({"request": value}) for value in (78, 79, 80)],
            {("core", "request")},
            20,
            "intentional test",
        )

        failure = comparison["baseline"]["guardFailures"][0]
        self.assertAlmostEqual(failure["deltaPercent"], -21)
        self.assertEqual(failure["regressionReason"], "intentional test")

    def test_rejects_mismatched_sample_sets(self) -> None:
        with self.assertRaisesRegex(ValueError, "different benchmark set"):
            build_comparison_report(
                [
                    report({"request": 100}),
                    report({"request": 101}),
                    report({"other": 102}),
                ],
                [report({"request": 100}) for _ in range(3)],
                {("core", "request")},
                20,
            )

    def test_rejects_even_sample_count(self) -> None:
        with self.assertRaisesRegex(ValueError, "odd sample count"):
            build_comparison_report(
                [report({"request": 100}) for _ in range(2)],
                [report({"request": 100}) for _ in range(2)],
                {("core", "request")},
                20,
            )


if __name__ == "__main__":
    unittest.main()
