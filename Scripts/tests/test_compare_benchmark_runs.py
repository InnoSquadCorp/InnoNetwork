#!/usr/bin/env python3
"""Unit tests for median benchmark comparison."""

from __future__ import annotations

import sys
import copy
import json
import tempfile
import subprocess
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare_benchmark_runs import build_comparison_report, load_report  # noqa: E402
import compare_benchmark_runs as comparator


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

    def test_uses_paired_deltas_to_cancel_runner_phase_drift(self) -> None:
        comparison = build_comparison_report(
            [report({"request": value}) for value in (100, 300, 500)],
            [report({"request": value}) for value in (105, 220, 510)],
            {("core", "request")},
            20,
        )

        delta = comparison["baseline"]["deltas"][0]
        self.assertAlmostEqual(delta["deltaPercent"], 2)
        self.assertAlmostEqual(delta["unpairedMedianDeltaPercent"], -26.6666666667)
        self.assertEqual(comparison["baseline"]["guardFailures"], [])

    def test_reports_sustained_paired_regression_despite_phase_drift(self) -> None:
        comparison = build_comparison_report(
            [report({"request": value}) for value in (100, 300, 500)],
            [report({"request": value}) for value in (70, 210, 350)],
            {("core", "request")},
            20,
        )

        failure = comparison["baseline"]["guardFailures"][0]
        self.assertAlmostEqual(failure["deltaPercent"], -30)

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

    def test_budget_still_rejects_20_point_01_percent_regression(self):
        value = build_comparison_report([report({"request":100}) for _ in range(3)],
            [report({"request":79.99}) for _ in range(3)], {("core","request")}, 20)
        self.assertEqual(len(value["baseline"]["guardFailures"]), 1)
        self.assertAlmostEqual(value["baseline"]["deltas"][0]["deltaPercent"], -20.01)

    def test_rejects_different_base_head_workload_counts(self):
        with self.assertRaisesRegex(ValueError, "different iteration counts"):
            build_comparison_report([report({"request":100},100) for _ in range(3)],
                [report({"request":100},1000) for _ in range(3)], {("core","request")}, 20)

    def test_rejects_nonfinite_nonpositive_boolean_and_inconsistent_metrics(self):
        for key, values in [("operationsPerSecond", [float('nan'), float('inf'), -1, 0, True, "100"]),
                            ("elapsedSeconds", [float('nan'), float('inf'), -1, 0, True, "1"]),
                            ("iterations", [0, -1, True, 100.5, "100"])]:
            for value in values:
                bad = report({"request":100})
                bad['results'][0][key] = value
                with self.subTest(key=key,value=value), self.assertRaises(ValueError):
                    build_comparison_report([report({"request":100}) for _ in range(3)],
                        [copy.deepcopy(bad) for _ in range(3)], {("core","request")}, 20)
        bad = report({"request":100});bad['results'][0]['elapsedSeconds'] = 10
        with self.assertRaisesRegex(ValueError, "throughput disagrees"):
            build_comparison_report([bad]*3, [report({"request":100})]*3, {("core","request")}, 20)
        for value in (float('nan'), float('inf'), -1, True):
            with self.assertRaises(ValueError):
                build_comparison_report([report({"request":100})]*3, [report({"request":100})]*3, set(), value)

    def test_rejects_duplicate_benchmark_and_json_field(self):
        bad = report({"request":100});bad['results'].append(copy.deepcopy(bad['results'][0]))
        with self.assertRaisesRegex(ValueError, "duplicate benchmark"):
            build_comparison_report([bad]*3, [report({"request":100})]*3, set(), 20)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'report.json';path.write_text('{"version":2,"version":2,"results":[]}')
            with self.assertRaisesRegex(ValueError, "duplicate JSON field"):
                load_report(path)

    def test_rejects_even_sample_count(self) -> None:
        with self.assertRaisesRegex(ValueError, "odd sample count"):
            build_comparison_report(
                [report({"request": 100}) for _ in range(2)],
                [report({"request": 100}) for _ in range(2)],
                {("core", "request")},
                20,
            )

    def test_nonfinite_derived_spread_is_rejected_before_serialization(self):
        values=[report({'request':x},1) for x in (1,1,1e308)]
        with self.assertRaisesRegex(ValueError,'non-finite report number'):
            build_comparison_report(values,values,{('core','request')},20)

    def test_cli_invalid_math_and_output_failures_are_exit_two_without_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);output=root/'results.json';receipt=root/'receipt.json'
            args=['--output',str(output),'--receipt',str(receipt),'--invocation-id','fixture',
                  '--source-head','a'*40,'--max-regression-percent','20']
            for side in ('base','head'):
                for index,ops in enumerate((1,1,1e308)):
                    path=root/f'{side}-{index}.json';path.write_text(json.dumps(report({'request':ops},1)))
                    args+=['--'+side,str(path)]
            output.write_text('stale');receipt.write_text('stale')
            result=subprocess.run([sys.executable,str(Path(comparator.__file__)),*args],capture_output=True,text=True)
            self.assertEqual(result.returncode,2,result.stderr)
            self.assertFalse(output.exists());self.assertFalse(receipt.exists())
            self.assertNotIn('Traceback',result.stderr)
            output.mkdir()
            result=subprocess.run([sys.executable,str(Path(comparator.__file__)),*args],capture_output=True,text=True)
            self.assertEqual(result.returncode,2,result.stderr)
            self.assertFalse(receipt.exists())
            output.rmdir()
            with mock.patch.object(sys,'argv',['compare',*args]), \
                    mock.patch.object(comparator,'build_comparison_report',return_value={'invalid':float('inf')}):
                self.assertEqual(comparator.main(),2)
            self.assertFalse(receipt.exists())


if __name__ == "__main__":
    unittest.main()
