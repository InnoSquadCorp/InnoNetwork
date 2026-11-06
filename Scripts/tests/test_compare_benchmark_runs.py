#!/usr/bin/env python3
"""Unit tests for median benchmark comparison."""

from __future__ import annotations

import sys
import copy
import json
import statistics
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



FIXTURES = Path(__file__).resolve().parent / "fixtures"
GUARD = ("core", "request")

# Every guard failure recorded by CI since the provenance manifest was added
# (2026-10-06 .. 2026-11-05) whose base and head had identical Sources/,
# Package.swift, Package.resolved and benchmark harness. Each is therefore a
# false failure. (run id, attempt, guard, primary paired deltas in percent)
IDENTICAL_SOURCE_FAILURES = [
    (37465674436, 1, "persistence/append-log-compaction", (-29.5851, -21.0568, 6.4584)),
    (37556028536, 1, "events/task-event-fanout-single", (-25.2633, -26.8351, 6.8382)),
    (37556028536, 1, "persistence/append-log-compaction", (-25.4343, -24.4462, 13.5276)),
    (37697061815, 1, "client/decoding-interceptor-chain-1", (-22.8151, -29.2516, 1.0605)),
    (37697061815, 1, "client/decoding-interceptor-chain-3", (-26.5686, -27.6010, -7.3598)),
    (37697061815, 1, "json/encode-mixed", (-20.2363, -23.1142, -10.4292)),
    (38194730770, 1, "persistence/append-log-compaction", (12.1569, -28.9637, -30.8255)),
    (39116547100, 1, "client/decoding-interceptor-chain-8", (-20.7089, -18.3223, -27.4662)),
    (40254056494, 1, "websocket/websocket-lifecycle-transition-table", (-22.0119, -27.7301, 13.5295)),
    (40254056494, 1, "client/request-pipeline", (-20.1535, -32.4946, 16.7097)),
    (40254056494, 1, "client/decoding-interceptor-chain-1", (-20.9654, -31.6264, 34.2242)),
    (40254056494, 2, "client/decoding-interceptor-chain-1", (1.9929, -22.3966, -25.8262)),
    (40254056494, 2, "client/decoding-interceptor-chain-8", (-0.9047, -24.0329, -22.8386)),
    (41605169312, 1, "events/task-event-fanout-single", (-21.2436, -37.0787, 40.7430)),
    (41957046184, 1, "client/request-pipeline", (-31.1556, -25.1757, 9.3558)),
    (41955813599, 1, "events/task-event-fanout-single", (-40.4806, -29.6088, -4.8908)),
]


def paired_reports(deltas, base_ops=1000.0):
    """One base/head report pair per delta, each pair measuring exactly that delta."""
    return (
        [report({"request": base_ops}) for _ in deltas],
        [report({"request": base_ops * (1 + delta / 100)}) for delta in deltas],
    )


def scaled(source, factors):
    """Copy a report and scale chosen benchmarks' throughput by a factor."""
    copied = copy.deepcopy(source)
    for row in copied["results"]:
        factor = factors.get(f"{row['group']}/{row['name']}", 1.0)
        row["operationsPerSecond"] *= factor
        row["elapsedSeconds"] = row["iterations"] / row["operationsPerSecond"]
    return copied


def load_fixture(name):
    fixture = json.loads((FIXTURES / name).read_text(encoding="utf-8"))
    guarded = {
        (row["group"], row["name"]) for row in fixture["base"][0]["results"]
    }
    return fixture, guarded


def confirmation(fixture, identifier, deltas):
    """Four fresh pairs whose head differs from base-1 only on one guard."""
    template = fixture["base"][0]
    return (
        [copy.deepcopy(template) for _ in deltas],
        [scaled(template, {identifier: 1 + delta / 100}) for delta in deltas],
    )


def delta_row(comparison, identifier):
    group, name = identifier.split("/")
    return next(
        item for item in comparison["baseline"]["deltas"]
        if item["group"] == group and item["name"] == name
    )


class GuardVerdictTests(unittest.TestCase):
    def compare(self, primary, confirmation_deltas=None):
        deltas = list(primary) + list(confirmation_deltas or [])
        base, head = paired_reports(deltas)
        return build_comparison_report(base, head, {GUARD}, 20, primary_pairs=len(primary))

    def test_low_spread_real_regression_fails_without_confirmation(self):
        comparison = self.compare((-24.0, -26.0, -25.0))
        baseline = comparison["baseline"]
        self.assertEqual(len(baseline["guardFailures"]), 1)
        self.assertAlmostEqual(baseline["guardFailures"][0]["deltaPercent"], -25.0)
        self.assertEqual(baseline["inconclusiveGuards"], [])
        self.assertEqual(baseline["deltas"][0]["guardVerdict"], "regression")
        self.assertEqual(comparator.verdict_exit_code(baseline), 1)
        # Extra pairs can never be used to argue a conclusive regression away.
        with self.assertRaisesRegex(ValueError, "require an inconclusive primary guard"):
            self.compare((-24.0, -26.0, -25.0), (0.0, 0.0, 0.0, 0.0))

    def test_every_pair_just_over_the_limit_is_a_conclusive_regression(self):
        comparison = self.compare((-20.01, -20.01, -20.01))
        self.assertEqual(comparison["baseline"]["deltas"][0]["guardVerdict"], "regression")
        self.assertEqual(comparator.verdict_exit_code(comparison["baseline"]), 1)

    def test_disagreeing_pairs_are_inconclusive_not_a_failure(self):
        comparison = self.compare((-40.0, -30.0, -5.0))
        baseline = comparison["baseline"]
        self.assertEqual(baseline["guardFailures"], [])
        self.assertEqual(len(baseline["inconclusiveGuards"]), 1)
        self.assertAlmostEqual(baseline["inconclusiveGuards"][0]["primaryDeltaPercent"], -30.0)
        self.assertEqual(baseline["deltas"][0]["guardVerdict"], "inconclusive")
        self.assertEqual(comparator.verdict_exit_code(baseline), comparator.EXIT_INCONCLUSIVE)

    def test_confirmation_clears_noise_and_keeps_high_spread_real_regressions(self):
        cases = [
            # (primary, confirmation, verdict, all-pair median)
            ((-40.0, -30.0, -5.0), (2.0, -6.0, 1.0, -12.0), "pass", -6.0),
            ((-45.0, -30.0, -5.0), (-28.0, -35.0, -22.0, -40.0), "regression", -30.0),
            # Two more pairs past the limit are enough to reproduce it.
            ((-40.0, -30.0, -5.0), (-25.0, -22.0, 1.0, -3.0), "regression", -22.0),
        ]
        for primary, extra, verdict, median in cases:
            with self.subTest(primary=primary, confirmation=extra):
                comparison = self.compare(primary, extra)
                baseline = comparison["baseline"]
                row = baseline["deltas"][0]
                self.assertEqual(baseline["pairCount"], 7)
                self.assertEqual(baseline["inconclusiveGuards"], [])
                self.assertEqual(row["primaryGuardVerdict"], "inconclusive")
                self.assertEqual(row["guardVerdict"], verdict)
                self.assertAlmostEqual(row["deltaPercent"], median)
                self.assertAlmostEqual(row["primaryDeltaPercent"], -30.0)
                self.assertEqual(len(baseline["guardFailures"]), int(verdict == "regression"))
                self.assertEqual(baseline["confirmedGuards"][0]["guardVerdict"], verdict)
                self.assertIn("4 confirmation pairs", baseline["baselinePath"])

    def test_confirmation_does_not_rejudge_conclusive_primary_guards(self):
        names = {"regressed": (-25.0, -24.0, -26.0), "noisy": (-40.0, -30.0, -5.0),
                 "steady": (1.0, 0.0, -1.0)}
        extra = {"regressed": (0.0, 0.0, 0.0, 0.0), "noisy": (0.0, 0.0, 0.0, 0.0),
                 "steady": (-50.0, -50.0, -50.0, -50.0)}
        deltas = {name: names[name] + extra[name] for name in names}
        base = [report({name: 1000.0 for name in names}) for _ in range(7)]
        head = [report({name: 1000.0 * (1 + deltas[name][index] / 100) for name in names})
                for index in range(7)]
        comparison = build_comparison_report(
            base, head, {("core", name) for name in names}, 20, primary_pairs=3)
        verdicts = {row["name"]: row["guardVerdict"] for row in comparison["baseline"]["deltas"]}
        self.assertEqual(verdicts, {"regressed": "regression", "noisy": "pass", "steady": "pass"})
        self.assertEqual(
            [failure["identifier"]["name"] for failure in comparison["baseline"]["guardFailures"]],
            ["regressed"],
        )

    def test_confirmation_size_and_primary_schedule_are_fixed(self):
        for primary, extra in [((-40.0, -30.0, -5.0), (0.0, 0.0)),
                               ((-40.0, -30.0, -5.0), (0.0,) * 6)]:
            with self.subTest(pairs=len(primary) + len(extra)), \
                    self.assertRaisesRegex(ValueError, "exactly 4 pairs"):
                self.compare(primary, extra)
        base, head = paired_reports((-40.0, -30.0, -5.0, 0.0, 0.0, 0.0, 0.0))
        for primary_pairs in (2, 4, True):
            with self.subTest(primary_pairs=primary_pairs), \
                    self.assertRaisesRegex(ValueError, "primary pair count"):
                build_comparison_report(base, head, {GUARD}, 20, primary_pairs=primary_pairs)

    def test_identical_source_ci_failures_are_all_inconclusive(self):
        for run, attempt, identifier, primary in IDENTICAL_SOURCE_FAILURES:
            with self.subTest(run=run, attempt=attempt, guard=identifier):
                self.assertLess(statistics.median(primary), -20)  # failed the old gate
                comparison = self.compare(primary)
                self.assertEqual(comparison["baseline"]["guardFailures"], [])
                self.assertEqual(comparison["baseline"]["deltas"][0]["guardVerdict"], "inconclusive")


class RecordedNoiseFixtureTests(unittest.TestCase):
    CASES = [
        ("benchmark-noise-pr177-run41955813599.json", "events/task-event-fanout-single", -29.61, 35.59),
        ("benchmark-noise-pr179-run41957046184.json", "client/request-pipeline", -25.18, 40.51),
    ]

    def test_recorded_noise_is_inconclusive_instead_of_failing(self):
        for name, identifier, delta, spread in self.CASES:
            with self.subTest(fixture=name):
                fixture, guarded = load_fixture(name)
                comparison = build_comparison_report(fixture["base"], fixture["head"], guarded, 20)
                baseline = comparison["baseline"]
                row = delta_row(comparison, identifier)
                self.assertAlmostEqual(row["deltaPercent"], delta, places=2)
                self.assertAlmostEqual(row["pairedDeltaSpreadPercent"], spread, places=2)
                self.assertEqual(baseline["guardFailures"], [])
                self.assertEqual(
                    [f"{item['identifier']['group']}/{item['identifier']['name']}"
                     for item in baseline["inconclusiveGuards"]],
                    [identifier],
                )
                self.assertEqual(comparator.verdict_exit_code(baseline), comparator.EXIT_INCONCLUSIVE)

    def test_recorded_noise_passes_unless_confirmation_reproduces_it(self):
        for name, identifier, _, _ in self.CASES:
            fixture, guarded = load_fixture(name)
            for extra, verdict in [((3.0, -6.0, 1.0, -12.0), "pass"),
                                   ((-24.0, -31.0, -22.0, -27.0), "regression")]:
                with self.subTest(fixture=name, confirmation=extra):
                    base, head = confirmation(fixture, identifier, extra)
                    comparison = build_comparison_report(
                        fixture["base"] + base, fixture["head"] + head, guarded, 20, primary_pairs=3)
                    baseline = comparison["baseline"]
                    self.assertEqual(delta_row(comparison, identifier)["guardVerdict"], verdict)
                    self.assertEqual(
                        [f"{item['identifier']['group']}/{item['identifier']['name']}"
                         for item in baseline["guardFailures"]],
                        [identifier] if verdict == "regression" else [],
                    )
                    self.assertEqual(comparator.verdict_exit_code(baseline), int(verdict == "regression"))

    def test_cli_defers_inconclusive_verdict_and_binds_confirmation_inputs(self):
        name, identifier, _, _ = self.CASES[0]
        fixture, _ = load_fixture(name)
        extra_base, extra_head = confirmation(fixture, identifier, (3.0, -6.0, 1.0, -12.0))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output, receipt = root / "results.json", root / "receipt.json"
            paths = {"base": [], "head": []}
            for side, reports in (("base", fixture["base"] + extra_base),
                                  ("head", fixture["head"] + extra_head)):
                for index, value in enumerate(reports, start=1):
                    path = root / f"{side}-{index}.json"
                    path.write_text(json.dumps(value))
                    paths[side].append(path)
            guards = []
            for value in sorted({f"{row['group']}/{row['name']}" for row in fixture["base"][0]["results"]}):
                guards += ["--guard-benchmark", value]

            def run(pairs):
                arguments = [sys.executable, str(Path(comparator.__file__)), "--primary-pairs", "3",
                             "--output", str(output), "--receipt", str(receipt),
                             "--invocation-id", "fixture", "--source-head", "a" * 40,
                             "--max-regression-percent", "20", *guards]
                for index in range(pairs):
                    arguments += ["--base", str(paths["base"][index]), "--head", str(paths["head"][index])]
                return subprocess.run(arguments, capture_output=True, text=True)

            primary = run(3)
            self.assertEqual(primary.returncode, comparator.EXIT_INCONCLUSIVE, primary.stderr)
            self.assertIn(f"{identifier} is inconclusive", primary.stderr)
            self.assertEqual(json.loads(receipt.read_text())["exit_code"], comparator.EXIT_INCONCLUSIVE)
            self.assertEqual(len(json.loads(receipt.read_text())["base"]), 3)

            confirmed = run(7)
            self.assertEqual(confirmed.returncode, 0, confirmed.stderr)
            self.assertIn(f"{identifier} re-judged on 7 pairs", confirmed.stderr)
            bound = json.loads(receipt.read_text())
            self.assertEqual(bound["exit_code"], 0)
            self.assertEqual([item["path"] for item in bound["head"]],
                             [str(path.resolve()) for path in paths["head"]])


if __name__ == "__main__":
    unittest.main()
