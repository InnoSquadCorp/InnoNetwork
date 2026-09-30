"""Fail-closed changed-path planner, real git deletes/renames and aggregate controls."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ci_policy', ROOT / 'Scripts/ci-policy.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def event(author='contributor', labels=(), action='opened'):
    return {'action': action, 'pull_request': {'user': {'login': author}, 'labels': [{'name': x} for x in labels]}}


def results(plan):
    return {'ci-plan': {'result': 'success'}, **{j: {'result': 'success' if v else 'skipped'} for j, v in plan['jobs'].items()}}


class PlannerTests(unittest.TestCase):
    def test_source_test_example_paths_keep_every_gate(self):
        for path in ['Sources/InnoNetwork/RequestExecutor.swift', 'Sources/README.md', 'Tests/README.md',
                     'Examples/CoreSmoke/Package.swift', 'SmokeTests/README.md', 'Benchmarks/README.md',
                     'Tools/openapi-to-innonetwork/Package.swift', 'Package.swift', 'Package.resolved',
                     'Scripts/format.sh', 'unknown.file', 'docs/public-docc-products.txt']:
            plan = p.make_plan('pull_request', event(), [path])
            self.assertTrue(all(plan['jobs'].values()), path)
            p.evaluate(plan, results(plan))
            for name in p.JOBS:
                broken = copy.deepcopy(plan)
                broken['jobs'][name] = False
                with self.assertRaises(ValueError): p.evaluate(broken, results(broken))

    def test_selective_docs_and_individual_workflows(self):
        cases = {'README.md': {'documentation', 'docs-contract-sync'},
                 '.spi.yml': {'documentation', 'docs-contract-sync'},
                 '.github/workflows/codeql.yml': {'codeql'},
                 '.github/workflows/tsan.yml': {'thread-sanitizer'},
                 '.github/workflows/benchmarks.yml': {'benchmarks', 'benchmark-smoke'},
                 '.github/workflows/dependabot-auto-merge.yml': set(),
                 '.github/dependabot.yml': set()}
        for path, expected in cases.items():
            plan = p.make_plan('pull_request', event(), [path])
            self.assertEqual({j for j, v in plan['jobs'].items() if v}, expected | {'policy'})
            p.evaluate(plan, results(plan))

    def test_all_bot_majors_toolchains_and_labels_require_full(self):
        for action in p.PR_ACTIONS:
            for author, labels in [('dependabot[bot]', []), ('contributor', ['release-validation'])]:
                plan = p.make_plan('pull_request', event(author, labels, action), ['.github/dependabot.yml'])
                self.assertTrue(all(plan['jobs'].values()))
                self.assertEqual(plan['lane'], 'release-validation')
        plan = p.make_plan('pull_request', event(labels=['concurrency-review']), ['LICENSE'])
        self.assertTrue(plan['jobs']['thread-sanitizer'])
        self.assertFalse(plan['jobs']['lint'])

    def test_main_dispatch_queue_full_except_pr_only_dependency_review(self):
        for name, data in [('push', {'ref': 'refs/heads/main'}), ('workflow_dispatch', {}),
                           ('merge_group', {'action': 'checks_requested'})]:
            plan = p.make_plan(name, data, [])
            self.assertEqual({j for j, v in plan['jobs'].items() if not v}, {'dependency-review'})
            p.evaluate(plan, results(plan))
        self.assertTrue(all(p.make_plan('pull_request', event(), [])['jobs'].values()))

    def test_selected_failures_and_unselected_success_are_not_accepted(self):
        plan = p.make_plan('pull_request', event(), ['README.md'])
        for job in ['ci-plan'] + list(p.JOBS):
            for value in ['failure', 'cancelled', 'neutral', None, 'skipped', 'success']:
                needs = results(plan)
                original = needs[job]['result']
                needs[job]['result'] = value
                if value != original:
                    with self.assertRaises(ValueError): p.evaluate(plan, needs)
        for job in results(plan):
            needs = results(plan); needs.pop(job)
            with self.assertRaises(ValueError): p.evaluate(plan, needs)
        with self.assertRaises(ValueError): p.evaluate(plan, dict(results(plan), surprise={'result': 'success'}))

    def test_malformed_policy_and_event_fail_closed(self):
        for path in ['', '/root', '../README.md', 'a/../b', 'a//b', 'a\\b', 'a\nb']:
            with self.assertRaises(ValueError): p.path_impact(path)
        for name, data in [('pull_request', {}), ('push', {'ref': 'refs/heads/topic'}),
                           ('merge_group', {'action': 'closed'}), ('unknown', {})]:
            with self.assertRaises(ValueError): p.make_plan(name, data, ['README.md'])
        with self.assertRaises(ValueError): p.load_json('{"a": 1, "a": 2}')
        for key, value in [('jobs', {}), ('schema', True), ('lane', 'fake'), ('event', 'fake')]:
            plan = p.make_plan('pull_request', event(), ['README.md']); plan[key] = value
            with self.assertRaises(ValueError): p.evaluate(plan, {})

    def test_git_stream_malformed_or_failed_is_rejected(self):
        for data in [b'M\0README.md', b'R100\0old.md\0', b'U\0README.md\0', b'R200\0a\0b\0', b'M\0\xff\0']:
            with mock.patch.object(p.subprocess, 'check_output', return_value=data):
                with self.assertRaises((ValueError, UnicodeError)): p.changed_paths(ROOT, 'a'*40, 'b'*40)
        with self.assertRaises(ValueError): p.changed_paths(ROOT, 'main', 'b'*40)

    def test_real_git_deletion_and_both_rename_sides_force_full(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(['git', '-C', tmp, *args], text=True).strip()
            git('init', '-q'); git('config', 'user.email', 'test@example.invalid'); git('config', 'user.name', 'Test')
            (root/'old.md').write_text('old\n'); (root/'delete.md').write_text('gone\n')
            git('add', '.'); git('commit', '-qm', 'base'); base = git('rev-parse', 'HEAD')
            git('mv', 'old.md', 'renamed.md'); (root/'delete.md').unlink()
            git('add', '-u'); git('commit', '-qm', 'rename and delete'); head = git('rev-parse', 'HEAD')
            paths = p.changed_paths(root, base, head)
            self.assertTrue({'old.md', 'renamed.md', 'delete.md'} <= set(paths))
            self.assertTrue(all(p.make_plan('pull_request', event(), paths)['jobs'].values()))


if __name__ == '__main__': unittest.main()
