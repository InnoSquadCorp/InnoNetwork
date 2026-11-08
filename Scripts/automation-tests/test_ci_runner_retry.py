"""Rerun only PR CI runs whose real failures all lost their runner."""
import importlib.util
import os
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('runner_retry', ROOT / 'Scripts/ci-runner-retry.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
p = r.p

RUN = 42242911394
LOST = 'The job was not acquired by Runner of type hosted even after multiple attempts'


class FakeAPI:
    def __init__(self):
        self.run = dict(id=RUN, path='.github/workflows/ci.yml', repository=dict(full_name=p.REPOSITORY),
                        event='pull_request', status='completed', conclusion='failure', run_attempt=1)
        self.jobs, self.notes, self.posts = [], {}, []

    def job(self, name, conclusion, runner='GitHub Actions 1', steps=1, note=None):
        job_id = 1000 + len(self.jobs)
        self.jobs.append(dict(id=job_id, name=name, conclusion=conclusion, runner_name=runner,
                              steps=[dict(name='step')] * steps))
        self.notes[job_id] = [] if note is None else [dict(annotation_level='failure', message=note)]

    def lost(self, name):
        self.job(name, 'cancelled', runner='', steps=0, note=LOST)

    def get(self, path):
        if path == p.route(f'actions/runs/{RUN}'):
            return dict(self.run)
        job_id = int(path.rsplit('/', 2)[1])
        assert path == p.route(f'check-runs/{job_id}/annotations'), path
        return list(self.notes[job_id])

    def pages(self, path, key=None):
        assert path == p.route(f"actions/runs/{RUN}/attempts/{self.run['run_attempt']}/jobs") and key == 'jobs', path
        return list(self.jobs)

    def mutate(self, method, path, payload):
        self.posts.append((method, path, payload))


class RunnerRetryTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        self.api.job('Lint (swift-format)', 'success')
        self.api.job('Consumer Examples', 'skipped', runner='', steps=0)

    def assertRerun(self):
        self.assertEqual(self.api.posts, [('POST', p.route(f'actions/runs/{RUN}/rerun-failed-jobs'), {})])

    def test_lost_runners_and_their_aggregate_gates_are_rerun(self):
        self.api.lost('Build and Test (SwiftPM) — Xcode 26.0.1')
        self.api.lost('Consumer Macros')
        self.api.job('Consumer Smoke', 'failure')
        self.api.job('CI Required', 'failure')
        self.assertIn('Build and Test', r.run(self.api, RUN))
        self.assertRerun()

    def test_a_real_failure_is_never_retried(self):
        self.api.lost('Build and Test (SwiftPM) — Xcode 26.0.1')
        self.api.job('CI and public operations policy', 'failure')
        self.api.job('CI Required', 'failure')
        self.assertIn('CI and public operations policy', r.run(self.api, RUN))
        self.assertEqual(self.api.posts, [])

    def test_only_annotated_runnerless_cancellations_count_as_lost(self):
        for job in [dict(runner='', steps=0, note=None),
                    dict(runner='', steps=0, note='The operation was canceled.'),
                    dict(runner='GitHub Actions 7', steps=0, note=LOST),
                    dict(runner='', steps=3, note=LOST)]:
            with self.subTest(job=job):
                self.setUp()
                self.api.job('Build and Test (SwiftPM) — Xcode 26.0.1', 'cancelled', **job)
                self.api.job('CI Required', 'failure')
                r.run(self.api, RUN)
                self.assertEqual(self.api.posts, [])

    def test_only_failed_pull_request_runs_below_the_attempt_cap_are_retried(self):
        for change in [dict(event='push'), dict(conclusion='success'), dict(conclusion='cancelled'),
                       dict(status='in_progress'), dict(run_attempt=r.MAX_ATTEMPT)]:
            with self.subTest(change=change):
                self.setUp()
                self.api.lost('Build and Test (SwiftPM) — Xcode 26.0.1')
                self.api.run.update(change)
                r.run(self.api, RUN)
                self.assertEqual(self.api.posts, [])
        self.setUp()
        self.api.lost('Build and Test (SwiftPM) — Xcode 26.0.1')
        self.api.run.update(run_attempt=r.MAX_ATTEMPT - 1)
        r.run(self.api, RUN)
        self.assertRerun()

    def test_foreign_runs_are_rejected(self):
        for change in [dict(path='.github/workflows/benchmarks.yml'), dict(repository=dict(full_name='fork/InnoNetwork')),
                       dict(id=RUN + 1)]:
            with self.subTest(change=change):
                self.setUp()
                self.api.run.update(change)
                with self.assertRaises(p.Rejected):
                    r.run(self.api, RUN)
                self.assertEqual(self.api.posts, [])

    def test_entrypoint_requires_the_trusted_default_main_workflow(self):
        environment = dict(GITHUB_REPOSITORY=p.REPOSITORY, RUN_ID=str(RUN), GH_TOKEN='token',
                           GITHUB_WORKFLOW_REF=r.WORKFLOW_REF.replace('refs/heads/main', 'refs/heads/feature'))
        with mock.patch.dict(os.environ, environment, clear=True), mock.patch('sys.argv', ['ci-runner-retry.py', 'run']), \
                mock.patch.object(p, 'GitHub') as github:
            self.assertEqual(r.main(), 1)
            github.assert_not_called()

    def test_workflow_keeps_a_read_only_checkout_and_no_secrets(self):
        workflow = (ROOT / '.github/workflows/ci-runner-retry.yml').read_text()
        self.assertIn('workflows: [CI]', workflow)
        self.assertNotIn('secrets.', workflow)
        self.assertNotIn('pull_request_target', workflow)
        self.assertEqual(workflow.count('ref: ${{ github.workflow_sha }}'), 1)
        self.assertEqual(workflow.count('persist-credentials: false'), 1)
        self.assertEqual(workflow.count('sparse-checkout: Scripts'), 1)
        self.assertIn(f"github.workflow_ref == '{r.WORKFLOW_REF}'", workflow)
        self.assertEqual(workflow.count(': write'), 1)
        self.assertIn('      actions: write', workflow)


if __name__ == '__main__':
    unittest.main()
