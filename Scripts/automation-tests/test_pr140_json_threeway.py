"""Small deterministic negative tests; no compiler or benchmark process runs."""
from copy import deepcopy
from pathlib import Path
import sys
from unittest.mock import patch
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run_pr140_json_threeway as diagnostic
from compare_benchmark_runs import build_comparison_report
from guarded_benchmarks import load_guarded_benchmarks

ROOT = Path(__file__).resolve().parents[2]
GUARDS = load_guarded_benchmarks(ROOT, "json")


def sample(ops=100):
    return {"version": 2, "results": [
        {"group": guard.split('/')[0], "name": guard.split('/')[1], "iterations": 20_000,
         "elapsedSeconds": 20_000 / ops, "operationsPerSecond": ops}
        for guard in GUARDS]}


class ThreewayTests(unittest.TestCase):
    def test_exact_schedule_and_source_identity(self):
        planned = diagnostic.schedule()
        self.assertEqual(len(planned), 36)
        for kind in diagnostic.KINDS:
            rows = [row for row in planned if row['kind'] == kind]
            self.assertEqual([row['side'] for row in rows], ['base', 'head', 'head', 'base', 'base', 'head'])
            self.assertEqual([row['pair'] for row in rows], [1, 1, 2, 2, 3, 3])
            for row in rows:
                self.assertEqual(row['revision_label'], kind[row['side'] == 'head'])
        self.assertEqual([row['kind'] for row in planned[::2]], [
            'AA', 'AB', 'BB', 'BC', 'CC', 'AC',
            'BB', 'BC', 'CC', 'AC', 'AA', 'AB',
            'CC', 'AC', 'AA', 'AB', 'BB', 'BC'])
        for kind in diagnostic.KINDS:
            slots = [index % 6 // 2 for index, row in enumerate(planned[::2]) if row['kind'] == kind]
            self.assertEqual(sorted(slots), [0, 1, 2])

    def test_same_binary_controls_do_not_substitute_another_revision(self):
        for row in diagnostic.schedule():
            if row['kind'] in ('AA', 'BB', 'CC'):
                self.assertEqual(row['revision_label'], row['kind'][0])
        self.assertEqual(len(set(diagnostic.REVISIONS.values())), 3)

    def test_controls_check_both_directions_and_both_spreads(self):
        report = build_comparison_report([sample()] * 3, [sample()] * 3,
                                        {tuple(g.split('/')) for g in GUARDS}, 20)
        self.assertEqual(diagnostic.control_failures(report), [])
        for key, value in [('deltaPercent', 20.01), ('deltaPercent', -20.01),
                           ('baselineRelativeSpreadPercent', 20.01), ('currentRelativeSpreadPercent', 20.01)]:
            changed = deepcopy(report)
            changed['baseline']['deltas'][4][key] = value
            self.assertEqual(len(diagnostic.control_failures(changed)), 1)
        for row in report['baseline']['deltas']:
            row.update(deltaPercent=-20, baselineRelativeSpreadPercent=20, currentRelativeSpreadPercent=20)
        self.assertEqual(diagnostic.control_failures(report), [])

    def test_every_guard_and_unchanged_workload_required(self):
        diagnostic.validate_json_report(sample(), GUARDS)
        missing = sample()
        missing['results'].pop()
        wrong_iterations = sample()
        wrong_iterations['results'][0]['iterations'] = 100
        wrong_iterations['results'][0]['elapsedSeconds'] = 1
        for report in (missing, wrong_iterations):
            with self.assertRaises(ValueError):
                diagnostic.validate_json_report(report, GUARDS)

    def test_remaining_budget_includes_builds_and_reserve(self):
        self.assertEqual(diagnostic.remaining_budget(10, 60, now=20), 60)
        self.assertEqual(diagnostic.remaining_budget(10, 1200, now=2390), 10)
        for now in (2400, 2500):
            with self.assertRaises(TimeoutError):
                diagnostic.remaining_budget(10, 60, now=now)

    def test_first_failed_sample_stops_the_fixed_collection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(diagnostic.protocol, 'sample', return_value=2) as run:
                with self.assertRaises(ValueError):
                    diagnostic.collect_samples(dict.fromkeys(diagnostic.KINDS, {}), root, root,
                                               GUARDS, {'samples': []}, root / 'experiment.json', lambda limit: limit)
                self.assertEqual(run.call_count, 1)

    def test_valid_comparison_failure_retained_and_remaining_comparisons_continue(self):
        report = build_comparison_report([sample()] * 3, [sample()] * 3,
                                        {tuple(g.split('/')) for g in GUARDS}, 20)
        with patch.object(diagnostic.protocol, 'execute', side_effect=[0, 1, 0, 0, 0, 0]) as run, \
             patch.object(diagnostic.protocol, 'verify_comparison') as verify, \
             patch.object(diagnostic, 'load_report', return_value=report):
            outcomes, unstable = diagnostic.compare_samples(ROOT, ROOT, lambda limit: limit)
        self.assertEqual(run.call_count, 6)
        self.assertEqual(verify.call_count, 6)
        self.assertEqual(outcomes['AB']['guard_exit'], 1)
        self.assertEqual(unstable, {})
        for call, kind in zip(verify.call_args_list, diagnostic.KINDS):
            self.assertEqual(call.args[2], diagnostic.REVISIONS[kind[1]])

    def test_invalid_comparison_stops_instead_of_becoming_a_regression(self):
        def verify(directory, invocation, source_head, exit_code):
            diagnostic.protocol.require(exit_code in (0, 1), 'invalid comparator execution')
        with patch.object(diagnostic.protocol, 'execute', return_value=2) as run, \
             patch.object(diagnostic.protocol, 'verify_comparison', side_effect=verify):
            with self.assertRaises(ValueError):
                diagnostic.compare_samples(ROOT, ROOT, lambda limit: limit)
            self.assertEqual(run.call_count, 1)

    def test_experiment_cannot_change_required_gates_or_revisions(self):
        text = (ROOT / 'Scripts/run_pr140_json_threeway.py').read_text()
        for forbidden in ('--regression-reason', 'append_benchmark_trend', 'git push', 'continue-on-error'):
            self.assertNotIn(forbidden, text)
        self.assertEqual(diagnostic.THRESHOLD, 20)
        self.assertEqual(diagnostic.BUDGET_SECONDS, 2400)
        self.assertEqual(diagnostic.SAMPLE_SECONDS, 60)
        self.assertEqual(diagnostic.REVISIONS['C'], '955841b398b96b1bf012c9c06c815e10d345109d')
        self.assertIn('signal.setitimer(signal.ITIMER_REAL, BUDGET_SECONDS)', text)
        self.assertIn('protocol.verify_comparison(pair_dir, invocation, REVISIONS[kind[1]], code)', text)


if __name__ == '__main__':
    unittest.main()
