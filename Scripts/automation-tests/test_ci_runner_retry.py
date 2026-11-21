"""Rerun only PR CI runs whose real failures all lost their runner, and the gate that judged them too early."""
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

# PR #199 on 2026-11-19: validation 1186 lost its watchOS runner, the metadata
# gate queued behind it failed at 18:14, and the retried validation passed at 18:22.
# Its last job finished at 18:22:11 and the run completed at 18:22:15.
RUN, GATE = 44557129210, 44557300966
PR, HEAD = 199, '73b348e99628f77526f04fe8189ebd8fdf601f30'
BASE, SOURCE = '69ce733bfa70a7f728a46ee7ee513d79f12ce12b', '83d793175225dc736f0e11c5c09bb33538a84e17'
LOST = 'The job was not acquired by Runner of type hosted even after multiple attempts'
WATCHOS = 'Release Candidate / Validate watchOS Build'
LAST_JOB, COMPLETED = '2026-11-19T18:22:11Z', '2026-11-19T18:22:15Z'
TOO_EARLY, AFTERWARDS = '2026-11-19T18:14:07Z', '2026-11-19T18:22:19Z'


def validation(pr=PR, head=HEAD):
    return f'CI validation v2 pr:{pr} head:{head} base:{BASE} source:{SOURCE} release:false asan:false concurrency:false'


def metadata(pr=PR, head=HEAD):
    return f'{r.metadata.PREFIX}pr:{pr} head:{head} base:{BASE} action:edited source:{SOURCE}'


def gate_steps(aggregate='skipped'):
    return [dict(name='Checkout', conclusion='success'), dict(name=r.metadata.GATES['CI Required'], conclusion=aggregate),
            dict(name=r.metadata.VERIFY_STEP, conclusion='failure')]


class FakeAPI:
    def __init__(self):
        self.runs, self.jobs, self.notes, self.fresh, self.posts, self.reads = {}, {}, {}, {}, [], []
        self.run = self.add(RUN, 1186, validation())

    def add(self, run_id, number, title, **fields):
        self.jobs[run_id] = []
        self.runs[run_id] = dict(dict(id=run_id, run_number=number, display_title=title, path='.github/workflows/ci.yml',
                                      repository=dict(full_name=p.REPOSITORY), event='pull_request', head_sha=HEAD,
                                      status='completed', conclusion='failure', run_attempt=1,
                                      pull_requests=[dict(number=PR, head=dict(sha=HEAD))]), **fields)
        return self.runs[run_id]

    def job(self, name, conclusion, runner='GitHub Actions 1', steps=1, note=None, run=RUN, started=None, completed=None):
        job_id = 1000 + len(self.notes)
        self.jobs[run].append(dict(id=job_id, name=name, conclusion=conclusion, runner_name=runner, started_at=started,
                                   completed_at=completed, steps=[dict(name='step')] * steps if type(steps) is int else steps))
        self.notes[job_id] = [] if note is None else [dict(annotation_level='failure', message=note)]

    def lost(self, name):
        self.job(name, 'cancelled', runner='', steps=0, note=LOST)

    def now(self, run_id):
        # The listing and a later read of one run may disagree.
        return dict(self.runs[run_id], **self.fresh.get(run_id, {}))

    def get(self, path):
        self.reads.append(path)
        if path.startswith(p.route('actions/runs/')):
            return self.now(int(path.rsplit('/', 1)[1]))
        job_id = int(path.rsplit('/', 2)[1])
        assert path == p.route(f'check-runs/{job_id}/annotations'), path
        return list(self.notes[job_id])

    def pages(self, path, key=None):
        self.reads.append(path)
        if key == 'workflow_runs':
            head = path.rsplit('=', 1)[1]
            assert path == p.route(f'actions/workflows/ci.yml/runs?head_sha={head}'), path
            return [dict(run) for run in self.runs.values() if run['head_sha'] == head]
        run_id = int(path.split('/runs/', 1)[1].split('/', 1)[0])
        assert path == p.route(f"actions/runs/{run_id}/attempts/{self.now(run_id)['run_attempt']}/jobs") and key == 'jobs', path
        return list(self.jobs[run_id])

    def mutate(self, method, path, payload):
        self.posts.append((method, path, payload))


def rerun(run_id):
    return ('POST', p.route(f'actions/runs/{run_id}/rerun-failed-jobs'), {})


class RunnerRetryTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        self.api.job('Lint (swift-format)', 'success')
        self.api.job('Consumer Examples', 'skipped', runner='', steps=0)

    def assertRerun(self):
        self.assertEqual(self.api.posts, [rerun(RUN)])

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

    def test_the_third_attempt_is_the_last(self):
        self.assertEqual(r.MAX_ATTEMPT, 3)

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

    def test_workflow_wakes_for_failures_and_for_successful_validations_only(self):
        workflow = (ROOT / '.github/workflows/ci-runner-retry.yml').read_text()
        self.assertIn('on:\n  workflow_run:\n    workflows: [CI]\n    types: [completed]\n', workflow)
        self.assertEqual(workflow.count('\n    if: '), 1)
        self.assertIn("\n    if: github.event.workflow_run.event == 'pull_request' && "
                      "(github.event.workflow_run.conclusion == 'failure' || "
                      "(github.event.workflow_run.conclusion == 'success' && "
                      f"!startsWith(github.event.workflow_run.display_title, '{r.metadata.PREFIX}'))) && "
                      f"github.repository == '{p.REPOSITORY}' && github.workflow_ref == '{r.WORKFLOW_REF}'\n", workflow)
        self.assertIn('          RUN_ID: ${{ github.event.workflow_run.id }}\n'
                      '        run: python3 -B Scripts/ci-runner-retry.py run\n', workflow)
        self.assertEqual(workflow.count('Scripts/ci-runner-retry.py'), 1)


class StaleGateTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        self.succeed()
        self.gate = self.metadata_run(GATE, 1187)

    def succeed(self, attempt=2):
        # A completed run was last updated when it completed.
        self.api.run.update(conclusion='success', run_attempt=attempt, updated_at=COMPLETED)
        self.api.jobs[RUN] = []
        self.api.job('Lint (swift-format)', 'success', started='2026-11-19T18:03:42Z', completed='2026-11-19T18:03:59Z')
        # GitHub reports a skipped job as started after it completed.
        self.api.job('Consumer Examples', 'skipped', runner='', steps=0,
                     started='2026-11-19T18:14:10Z', completed='2026-11-19T18:14:04Z')
        self.api.job(WATCHOS, 'success', started='2026-11-19T18:17:04Z', completed='2026-11-19T18:21:52Z')
        self.api.job('CI Required', 'success', started='2026-11-19T18:21:56Z', completed=LAST_JOB)

    def metadata_run(self, run_id, number, started=TOO_EARLY, title=None, **fields):
        # The gate's own completion is not the validation's.
        fields.setdefault('updated_at', '2026-11-19T18:14:20Z')
        run = self.api.add(run_id, number, title or metadata(), **fields)
        self.api.job('CI Plan', 'skipped', runner='', steps=0, run=run_id)
        self.api.job('Lint (swift-format)', 'skipped', runner='', steps=0, run=run_id)
        self.api.job('CI Required', run['conclusion'] or 'failure', run=run_id, started=started, steps=gate_steps())
        return run

    def assertNothing(self, reason, run_id=RUN):
        self.assertIn(reason, r.run(self.api, run_id))
        self.assertEqual(self.api.posts, [])

    def test_gate_that_failed_behind_a_lost_runner_is_rerun_after_the_retry_succeeds(self):
        # 18:14:04, the first validation attempt ends without its watchOS runner.
        self.api.run.update(conclusion='failure', run_attempt=1)
        self.api.jobs[RUN] = []
        self.api.job('Lint (swift-format)', 'success')
        self.api.lost(WATCHOS)
        self.api.job('CI Required', 'failure')
        self.assertIn(WATCHOS, r.run(self.api, RUN))
        self.assertEqual(self.api.posts, [rerun(RUN)])
        # 18:14:20, the gate admitted by that failure rejects it; no runner was lost.
        self.assertEqual(r.run(self.api, GATE), 'no job lost its runner')
        self.assertEqual(self.api.posts, [rerun(RUN)])
        # 18:22:15, the retried validation succeeds and the gate is asked again.
        self.succeed()
        self.assertEqual(r.run(self.api, RUN), f'rerun metadata gate {GATE}: it failed before validation {RUN} succeeded')
        self.assertEqual(self.api.posts, [rerun(RUN), rerun(GATE)])

    def test_a_real_validation_failure_reruns_nothing(self):
        self.api.run.update(conclusion='failure', run_attempt=1)
        self.api.jobs[RUN] = []
        self.api.lost(WATCHOS)
        self.api.job('Lint (swift-format)', 'failure')
        self.api.job('CI Required', 'failure')
        self.assertNothing('real failures, not retried: Lint (swift-format)')
        self.assertNothing('no job lost its runner', GATE)

    def test_a_gate_that_keeps_failing_is_not_rerun_again(self):
        self.assertEqual(r.run(self.api, RUN), f'rerun metadata gate {GATE}: it failed before validation {RUN} succeeded')
        # The rerun starts after the success and fails for a reason of its own.
        self.gate.update(run_attempt=2)
        self.api.jobs[GATE][-1].update(started_at=AFTERWARDS)
        self.assertEqual(r.run(self.api, GATE), 'no job lost its runner')
        self.assertIn('already judged this successful validation', r.run(self.api, RUN))
        self.assertEqual(self.api.posts, [rerun(GATE)])

    def test_gate_started_no_earlier_than_the_validation_run_completed_is_left_alone(self):
        for started in (COMPLETED, AFTERWARDS):
            with self.subTest(started=started):
                self.api.jobs[GATE][-1].update(started_at=started)
                self.assertNothing('already judged this successful validation')

    def test_gate_started_before_the_validation_run_completed_is_rerun(self):
        # The gate rejects a run that is not completed, even after its last job finished.
        for started in ('2026-11-19T18:22:00Z', LAST_JOB, '2026-11-19T18:22:13Z'):
            with self.subTest(started=started):
                self.setUp()
                self.api.jobs[GATE][-1].update(started_at=started)
                r.run(self.api, RUN)
                self.assertEqual(self.api.posts, [rerun(GATE)])

    def test_the_attempt_cap_bounds_gate_reruns(self):
        self.gate.update(run_attempt=r.MAX_ATTEMPT)
        self.assertNothing(f'metadata gate attempt {r.MAX_ATTEMPT} still failed; leaving it to a human')
        self.gate.update(run_attempt=r.MAX_ATTEMPT - 1)
        r.run(self.api, RUN)
        self.assertEqual(self.api.posts, [rerun(GATE)])

    def test_a_first_attempt_success_also_reruns_a_gate_admitted_before_it(self):
        self.succeed(attempt=1)
        r.run(self.api, RUN)
        self.assertEqual(self.api.posts, [rerun(GATE)])

    def test_plan_names_the_gate_without_requesting_anything(self):
        self.assertEqual(r.plan(self.api, RUN)[0], GATE)
        self.assertEqual(self.api.posts, [])

    def test_only_the_newest_gate_after_the_validation_counts(self):
        # A gate older than the validation is history: the validation's own suite is newer.
        self.gate.update(run_number=1185)
        self.assertNothing('no metadata gate ran after this validation')
        self.setUp()
        self.metadata_run(GATE + 1, 1188, conclusion='success')
        self.assertNothing('the newest metadata gate did not fail')
        self.setUp()
        self.metadata_run(GATE + 1, 1188)
        r.run(self.api, RUN)
        self.assertEqual(self.api.posts, [rerun(GATE + 1)])

    def test_unfinished_or_cancelled_newest_gate_is_left_alone(self):
        for change, reason in [(dict(status='queued', conclusion=None), 'has not finished'),
                               (dict(status='in_progress', conclusion=None), 'has not finished'),
                               (dict(conclusion='cancelled'), 'did not fail'),
                               (dict(conclusion='success'), 'did not fail')]:
            with self.subTest(change=change):
                self.setUp()
                self.gate.update(change)
                self.assertNothing(reason)

    def test_gate_rerun_by_someone_else_since_the_listing_is_left_alone(self):
        self.api.fresh[GATE] = dict(status='queued', conclusion=None, run_attempt=2)
        self.assertNothing('no longer failed')
        # A rerun that already failed again counts with its own attempt.
        self.api.fresh[GATE] = dict(run_attempt=r.MAX_ATTEMPT)
        self.assertNothing(f'metadata gate attempt {r.MAX_ATTEMPT} still failed')

    def test_a_newer_validation_of_the_same_pull_request_decides(self):
        for state in (dict(status='in_progress', conclusion=None), dict(conclusion='success'), dict(conclusion='failure')):
            with self.subTest(state=state):
                self.setUp()
                self.api.add(RUN + 9, 1188, validation(), **state)
                self.assertNothing('a newer validation of this head decides')
        # The gate ignores a run GitHub binds to another PR of the same head.
        self.setUp()
        self.api.add(RUN + 9, 1188, validation(pr=PR + 1), pull_requests=[dict(number=PR + 1)])
        r.run(self.api, RUN)
        self.assertEqual(self.api.posts, [rerun(GATE)])

    def test_gates_of_another_pull_request_or_head_are_ignored(self):
        for title in (metadata(pr=PR + 1), metadata(head='0' * 40), metadata().replace('action:edited', 'action:opened'),
                      metadata() + ' extra'):
            with self.subTest(title=title):
                self.setUp()
                self.gate.update(display_title=title)
                self.assertNothing('no metadata gate ran after this validation')

    def test_only_a_run_that_failed_in_its_gate_alone_is_rerun(self):
        def ran_validation(jobs): jobs[0].update(conclusion='failure', steps=[dict(name='step')])
        def skipped_with_steps(jobs): jobs[0].update(steps=[dict(name='step')])
        def failed_without_steps(jobs): jobs[0].update(conclusion='failure')
        def lost_its_runner(jobs): jobs[0].update(conclusion='cancelled')
        def aggregate_failed(jobs): jobs[-1].update(steps=gate_steps(aggregate='failure'))
        def aggregate_passed(jobs): jobs[-1].update(steps=gate_steps(aggregate='success'))
        def gate_passed(jobs): jobs[-1].update(conclusion='success')
        def no_gate(jobs): jobs.pop()
        def two_gates(jobs): jobs.append(dict(jobs[-1]))
        for change in (ran_validation, skipped_with_steps, failed_without_steps, lost_its_runner, aggregate_failed,
                       aggregate_passed, gate_passed, no_gate, two_gates):
            with self.subTest(change=change.__name__):
                self.setUp()
                change(self.api.jobs[GATE])
                self.assertNothing('not a failed gate alone')

    def test_validation_bound_to_nothing_reads_no_other_run(self):
        for change in (dict(display_title=metadata()), dict(display_title='CI validation / push / refs/heads/main'),
                       dict(display_title=validation() + ' extra'), dict(display_title=validation(head='0' * 40)),
                       # Without a PR listing, as for a fork, the title must still name the run's head.
                       dict(display_title=validation(head='0' * 40), pull_requests=[]),
                       dict(pull_requests=[dict(number=PR + 1)]),
                       # GitHub lists the PR at its current head, so this validation is of an older one.
                       dict(pull_requests=[dict(number=PR, head=dict(sha='0' * 40))])):
            with self.subTest(change=change):
                self.setUp()
                self.api.run.update(change)
                r.run(self.api, RUN)
                self.assertEqual(self.api.reads, [p.route(f'actions/runs/{RUN}')])
                self.assertEqual(self.api.posts, [])

    def test_only_this_pull_request_listed_at_another_head_counts_as_moved(self):
        # A fork PR has no listing; the gate itself rejects a head that moved.
        # GitHub may also list another PR that shares the branch name.
        for listing in ([], None, [dict(number=PR)], [dict(number=PR, head=None)], ['unreadable'],
                        [dict(number=PR, head=dict(sha=HEAD)), dict(number=PR + 1, head=dict(sha='0' * 40))]):
            with self.subTest(listing=listing):
                self.setUp()
                self.api.run.update(pull_requests=listing)
                r.run(self.api, RUN)
                self.assertEqual(self.api.posts, [rerun(GATE)])

    def test_a_success_without_a_later_gate_costs_two_reads(self):
        del self.api.runs[GATE]
        self.assertNothing('no metadata gate ran after this validation')
        self.assertEqual(self.api.reads, [p.route(f'actions/runs/{RUN}'),
                                          p.route(f'actions/workflows/ci.yml/runs?head_sha={HEAD}')])

    def test_malformed_evidence_is_rejected_before_any_request(self):
        def unordered(api): api.runs[GATE].update(run_number='1187')
        def foreign_gate(api): api.fresh[GATE] = dict(head_sha='0' * 40)
        def retitled_gate(api): api.fresh[GATE] = dict(display_title=metadata(pr=PR + 1))
        def another_run(api): api.fresh[GATE] = dict(id=GATE + 1)
        def another_workflow(api): api.fresh[GATE] = dict(path='.github/workflows/benchmarks.yml')
        def another_repository(api): api.fresh[GATE] = dict(repository=dict(full_name='fork/InnoNetwork'))
        def another_event(api): api.fresh[GATE] = dict(event='push')
        def no_start(api): api.jobs[GATE][-1].update(started_at=None)
        def naive_start(api): api.jobs[GATE][-1].update(started_at='2026-11-19T18:14:07')
        def no_completion(api): api.run.update(updated_at=None)
        def naive_completion(api): api.run.update(updated_at='2026-11-19T18:22:15')
        for change in (unordered, foreign_gate, retitled_gate, another_run, another_workflow, another_repository,
                       another_event, no_start, naive_start, no_completion, naive_completion):
            with self.subTest(change=change.__name__):
                self.setUp()
                change(self.api)
                with self.assertRaises(p.Rejected):
                    r.run(self.api, RUN)
                self.assertEqual(self.api.posts, [])


if __name__ == '__main__':
    unittest.main()
