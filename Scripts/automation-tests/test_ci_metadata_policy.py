"""Native metadata no-ops cannot replace, green, cancel or hide real CI evidence."""
import copy
from datetime import datetime, timedelta
import importlib.util
import itertools
import tempfile
from pathlib import Path
import unittest
from unittest import mock

import test_dependabot_merge_policy as bot
import test_dependabot_arm_policy as arm
import test_dependabot_ready_policy as ready
import test_main_ci_reuse_policy as reuse

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('metadata', ROOT / 'Scripts/ci-metadata-policy.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
META, SUITE, SOURCE = 9900, 9901, 'f' * 40
GATE_DONE = '2026-10-29T06:45:13Z'


def later(stamp, minutes):
    return (datetime.fromisoformat(stamp.replace('Z', '+00:00')) + timedelta(minutes=minutes)).isoformat().replace('+00:00', 'Z')


class MetadataAPI:
    def __init__(self, base, number, head, ancestor, current_source, *, expanded=False, inventory=None,
                 meta=META, suite=SUITE, run_number=99, offset=0, completed=GATE_DONE):
        self.base, self.head, self.current_source = base, head, current_source
        self.meta, self.suite = meta, suite
        repo = base.repo
        self.run = dict(id=meta, run_number=run_number, run_attempt=1, workflow_id=base.workflow['id'],
                        path=m.PATH, event='pull_request', head_sha=head, repository=repo, head_repository=repo,
                        pull_requests=[dict(number=number)],
                        status='completed', conclusion='success', check_suite_id=suite,
                        display_title=f'CI metadata-only v1 pr:{number} head:{head} base:{ancestor} action:labeled source:{SOURCE}')
        self.commit = dict(sha=SOURCE, parents=[dict(sha=ancestor), dict(sha=head)])
        self.blob = '9' * 40
        self.expected_blob = self.blob
        self.jobs, self.checks = [], []
        names = m.INVENTORIES[-1 if expanded else 0] if inventory is None else inventory
        for i, name in enumerate(sorted(names)):
            job = dict(id=20000+offset+i, name=name, run_id=meta, run_attempt=1, head_sha=head,
                       status='completed', conclusion='skipped', steps=[],
                       check_run_url=f'https://api.github.com/repos/{bot.p.REPOSITORY}/check-runs/{30000+offset+i}')
            self.jobs.append(job)
            self.checks.append(dict(id=30000+offset+i, name=name, app=dict(id=15368), check_suite=dict(id=suite),
                                    head_sha=head, status='completed', conclusion='skipped', completed_at=completed,
                                    details_url=f'https://github.com/{bot.p.REPOSITORY}/actions/runs/{meta}/job/{job["id"]}'))
        self.base.runs.append(self.run)
        self.jobs_by_attempt = {1: self.jobs}
        self.prove_gate()
        self.finish_mutation = None
        self.run_reads = 0

    def __getattr__(self, name):
        # Stacked metadata runs share one underlying CI transcript.
        base = self.__dict__.get('base')
        if base is None:
            raise AttributeError(name)
        return getattr(base, name)

    def transcript(self):
        return self.base.transcript() if isinstance(self.base, MetadataAPI) else self.base

    def get(self, route):
        if route.endswith(f'actions/runs/{self.meta}'):
            self.run_reads += 1
            result = copy.deepcopy(self.run)
            if self.run_reads % 2 == 0 and self.finish_mutation:
                self.finish_mutation(result)
            return result
        if route.endswith('git/commits/' + SOURCE):
            return copy.deepcopy(self.commit)
        if '/contents/' + m.PATH + '?ref=' in route:
            return dict(sha=self.blob if route.endswith(SOURCE) else self.expected_blob)
        if '/check-runs/' in route and '?' not in route:
            check_id = int(route.rsplit('/', 1)[1])
            found = [c for c in self.checks if c['id'] == check_id]
            if found:
                return copy.deepcopy(found[0])
            if isinstance(self.base, reuse.Transcript):  # The reuse transcript only lists suites.
                return copy.deepcopy(next(c for c in self.base.checks if c['id'] == check_id))
        return self.base.get(route)

    def pages(self, route, key=None):
        if f'check-suites/{self.suite}/' in route:
            return copy.deepcopy(self.checks)
        if f'actions/runs/{self.meta}/attempts/' in route and route.endswith('/jobs'):
            return copy.deepcopy(self.jobs_by_attempt[int(route.split('/')[-2])])
        result = self.base.pages(route, key)
        if f'commits/{self.head}/check-runs?' in route:
            result += copy.deepcopy(self.checks)
        return result

    def graphql(self, query, variables):
        return self.base.graphql(query, variables)

    def gate(self):
        job = next(j for j in self.jobs if j['name'] in m.GATES)
        return job, next(c for c in self.checks if c['id'] == int(job['check_run_url'].rsplit('/', 1)[1]))

    def prove_gate(self):
        job, check = self.gate()
        job.update(conclusion='success', steps=[
            dict(name=m.GATES[job['name']], conclusion='skipped', status='completed'),
            dict(name=m.VERIFY_STEP, conclusion='success', status='completed')])
        check['conclusion'] = self.run['conclusion'] = 'success'

    def end_gate(self, conclusion='failure', steps=None):
        """Model the one-shot gate exiting before validation finished or after its head moved."""
        job, check = self.gate()
        job.update(conclusion=conclusion, steps=steps if steps is not None else [
            dict(name='Checkout', conclusion='success', status='completed'),
            dict(name=m.GATES[job['name']], conclusion='skipped', status='completed'),
            dict(name=m.VERIFY_STEP, conclusion=conclusion, status='completed')])
        check['conclusion'] = self.run['conclusion'] = conclusion

    def force_cancel_gate(self):
        """The shape GitHub recorded for force-cancelled waiting observers on 2026-10-29."""
        self.end_gate('cancelled', [
            dict(name='Set up job', conclusion='success', status='completed'),
            dict(name='Checkout', conclusion='success', status='completed'),
            dict(name=m.GATES['CI Required'], conclusion='skipped', status='completed'),
            dict(name=m.VERIFY_STEP, conclusion=None, status='in_progress'),
            dict(name='Post Checkout', conclusion=None, status='pending')])

    def attempt_gate(self, attempt):
        job = next(j for j in self.jobs_by_attempt[attempt] if j['name'] in m.GATES)
        return job, next(c for c in self.checks if c['id'] == int(job['check_run_url'].rsplit('/', 1)[1]))

    def validation_required(self, check_id, completed):
        """Place the real validation's own CI Required at a native check order."""
        t = self.transcript()
        job = next(j for j in t.jobs if j['name'] == 'CI Required')
        check = next(c for c in t.checks if c['id'] == int(job['check_run_url'].rsplit('/', 1)[1]))
        job.update(run_id=t.run['id'], run_attempt=t.run['run_attempt'], head_sha=self.head,
                   check_run_url=job['check_run_url'].rsplit('/', 1)[0] + f'/{check_id}')
        check.update(id=check_id, completed_at=completed)

    def rerun(self):
        attempt = self.run['run_attempt'] + 1
        self.run['run_attempt'] = attempt
        self.jobs = copy.deepcopy(self.jobs)
        current_checks = []
        for job in self.jobs:
            check_id = int(job['check_run_url'].rsplit('/', 1)[1])
            check = copy.deepcopy(next(c for c in self.checks if c['id'] == check_id))
            job.update(id=job['id'] + 100000, run_attempt=attempt,
                       check_run_url=job['check_run_url'].rsplit('/', 1)[0] + '/' + str(check_id + 100000))
            check.update(id=check_id + 100000, completed_at=later(check['completed_at'], 90),
                         details_url=f'https://github.com/{bot.p.REPOSITORY}/actions/runs/{self.meta}/job/{job["id"]}')
            current_checks.append(check)
        self.checks.extend(current_checks)
        self.jobs_by_attempt[attempt] = self.jobs


def reuse_api(expanded=False, inventory=None):
    t = reuse.Transcript()
    return MetadataAPI(t, reuse.NUMBER, reuse.HEAD, reuse.BASE, reuse.MAIN, expanded=expanded, inventory=inventory)


def bot_api(base=None, **kwargs):
    return MetadataAPI(base or bot.Transcript(), bot.NUMBER, bot.HEAD, bot.BASE, bot.MERGE, **kwargs)


def consumers(configure):
    """Both latest-validation readers must agree on every metadata outcome."""
    a = reuse_api()
    configure(a)
    b = bot_api()
    configure(b)
    return [('main-reuse', lambda: reuse.p.prove(a, a.base.event, reuse.CONTEXT, now=a.base.now)['run'], reuse.RUN),
            ('coordinator', lambda: bot.p.proof(b, bot.NUMBER)['run'], bot.RUN)]


VALIDATION_DONE = later(GATE_DONE, 340)


class MetadataProofTests(unittest.TestCase):
    def test_skipped_inventories_match_actual_workflow_job_names(self):
        # Independently derive both native reusable-call representations from
        # the workflow files, so a new/renamed job cannot silently break proof.
        workflows = ROOT / '.github/workflows'
        direct, calls = set(), []
        for job in bot.workflow_jobs((workflows / 'ci.yml').read_text()).values():
            if job['uses']:
                children = bot.workflow_jobs((workflows / job['uses']).read_text()).values()
                calls.append(({job['name']}, {job['name'] + ' / ' + child['name'] for child in children}))
            else:
                name = job['name']
                if name.startswith('${{ '):
                    native_expression = name.removeprefix('${{ ').removesuffix(' }}')
                    if "'CI Metadata Only' || 'CI Required'" in name:
                        name = 'CI Metadata Only'
                    else:
                        self.assertIn("'Consumer Metadata Only' || 'Consumer Smoke'", name)
                        name = 'Consumer Metadata Only'
                    calls.append(({name}, {native_expression}))
                else:
                    direct.add(name)
        expected = {frozenset(direct.union(*children)) for children in itertools.product(*calls)}
        self.assertEqual({frozenset(names) for names in m.INVENTORIES}, expected)

    def test_latest_real_ci_is_preserved_for_main_reuse_and_bot_readiness(self):
        for inventory in m.INVENTORIES:
            api = reuse_api(inventory=inventory)
            proof = reuse.p.prove(api, api.base.event, reuse.CONTEXT, now=api.base.now)
            self.assertEqual(proof['run'], reuse.RUN)
            b = MetadataAPI(bot.Transcript(), bot.NUMBER, bot.HEAD, bot.BASE, bot.MERGE, inventory=inventory)
            self.assertEqual(bot.p.proof(b, bot.NUMBER)['run'], bot.RUN)
            self.assertEqual(b.base.mutations, [])

    def test_a_failed_pending_or_cancelled_real_run_cannot_be_hidden_by_metadata(self):
        for status, conclusion in [('completed', 'failure'), ('in_progress', None), ('completed', 'cancelled')]:
            api = reuse_api()
            api.base.run.update(status=status, conclusion=conclusion)
            with self.assertRaises(ValueError):
                reuse.p.prove(api, api.base.event, reuse.CONTEXT, now=api.base.now)
            b = MetadataAPI(bot.Transcript(), bot.NUMBER, bot.HEAD, bot.BASE, bot.MERGE)
            b.base.run.update(status=status, conclusion=conclusion)
            with self.assertRaises(ValueError):
                bot.p.proof(b, bot.NUMBER)

    def test_title_alone_or_incomplete_native_provenance_is_never_exempted(self):
        mutations = [
            lambda a: a.run.update(display_title=m.PREFIX + 'forged'),
            lambda a: a.run.update(workflow_id=999), lambda a: a.run.update(event='workflow_dispatch'),
            lambda a: a.run.update(head_sha='0' * 40), lambda a: a.run.update(repository={'id': 999}),
            lambda a: a.run.update(status='in_progress'), lambda a: a.run.update(conclusion='cancelled'),
            lambda a: a.run.update(check_suite_id=0), lambda a: a.run.update(run_attempt=0),
            lambda a: a.commit['parents'][0].update(sha='0' * 40),
            lambda a: setattr(a, 'blob', '0' * 40), lambda a: setattr(a, 'expected_blob', ''),
            lambda a: a.jobs.pop(), lambda a: a.jobs.append(copy.deepcopy(a.jobs[0])),
            lambda a: a.jobs[0].update(name='CI Required'),
            lambda a: a.jobs[0].update(name=m.METADATA_CONDITION + " && 'CI Metadata Only' || 'Forged Required'"),
            lambda a: a.jobs[0].update(conclusion='failure'),
            lambda a: a.jobs[0].update(steps=[{'name': 'executed'}]),
            lambda a: a.jobs[0].update(check_run_url='https://example.invalid/123'),
            lambda a: a.jobs[0].update(run_id=0), lambda a: a.jobs[0].update(run_attempt=2),
            lambda a: a.checks[0]['app'].update(id=999), lambda a: a.checks[0].update(head_sha='0'*40),
            lambda a: a.checks[0].update(conclusion='failure'), lambda a: a.checks[0].update(details_url='wrong'),
            lambda a: a.checks.append(copy.deepcopy(a.checks[0])),
            lambda a: setattr(a, 'finish_mutation', lambda r: r.update(run_attempt=2)),
        ]
        for index, mutate in enumerate(mutations):
            api = reuse_api()
            mutate(api)
            with self.subTest(index=index), self.assertRaises(ValueError):
                reuse.p.prove(api, api.base.event, reuse.CONTEXT, now=api.base.now)

    def test_metadata_alone_is_not_full_ci(self):
        api = reuse_api()
        api.base.runs = [api.run]
        with self.assertRaisesRegex(ValueError, 'missing exact-head CI'):
            reuse.p.prove(api, api.base.event, reuse.CONTEXT, now=api.base.now)

    def test_newer_real_validation_supersedes_obsolete_metadata_definition(self):
        api = reuse_api()
        api.run['run_number'] = 29
        api.blob = '0' * 40
        self.assertEqual(reuse.p.prove(api, api.base.event, reuse.CONTEXT, now=api.base.now)['run'], reuse.RUN)
        self.assertEqual(api.run_reads, 0)
        b = MetadataAPI(bot.Transcript(), bot.NUMBER, bot.HEAD, bot.BASE, bot.MERGE)
        b.run['run_number'] = 29
        b.blob = '0' * 40
        self.assertEqual(bot.p.proof(b, bot.NUMBER)['run'], bot.RUN)
        self.assertEqual(b.run_reads, 0)
        b.base.run.update(status='completed', conclusion='failure')
        with self.assertRaises(ValueError):
            bot.p.proof(b, bot.NUMBER)

    def test_pending_metadata_is_a_controlled_block_not_a_failed_coordinator(self):
        b = MetadataAPI(bot.Transcript(), bot.NUMBER, bot.HEAD, bot.BASE, bot.MERGE)
        b.run.update(status='in_progress', conclusion=None)
        with mock.patch.dict(bot.os.environ, bot.TRUSTED):
            result = bot.p.coordinate(b, bot.NUMBER, True, dict(id=bot.RUN, run_attempt=1))
        self.assertIn('blocked:', result)
        self.assertEqual(b.base.mutations, [])

    def test_metadata_completion_recovers_a_blocked_real_ci_notification(self):
        for already_armed in (False, True):
            with self.subTest(already_armed=already_armed), tempfile.TemporaryDirectory() as directory:
                b = MetadataAPI(arm.ArmTranscript(), bot.NUMBER, bot.HEAD, bot.BASE, bot.MERGE)
                if already_armed:
                    b.base.pr['auto_merge'] = dict(enabled_by=dict(bot.p.BOT))
                b.run.update(status='in_progress', conclusion=None)
                output = Path(directory) / 'output'
                with mock.patch.dict(bot.os.environ, dict(bot.TRUSTED, GITHUB_OUTPUT=str(output)), clear=True):
                    blocked = bot.p.coordinate(b, bot.NUMBER, True, dict(id=bot.RUN, run_attempt=1))
                    self.assertIn('blocked:', blocked)
                    self.assertFalse(b.base.pr.get('auto_merge'))
                    b.run.update(status='completed', conclusion='success')
                    # A failed unarmed reporter stays false until the verified
                    # metadata wake arms behind it and publishes its receipt.
                    self.assertIsNone(ready.n.refresh_plan(b, bot.p, bot.NUMBER, True))
                    notification = dict(id=META, run_attempt=1)
                    self.assertIn('read-only Ready receipt refresh', bot.p.coordinate(b, bot.NUMBER, True, notification))
                    receipt = dict(line.split('=', 1) for line in output.read_text().splitlines())['arm_receipt']
                    b.base.publish_receipt(receipt)
                    self.assertIsNotNone(ready.n.refresh_plan(b, bot.p, bot.NUMBER, True))
                    self.assertIn('armed', bot.p.coordinate(b, bot.NUMBER, True, notification))
                enables = [m for m in b.base.mutations if 'enablePullRequestAutoMerge' in m[1]]
                self.assertEqual(len(enables), 1)
                self.assertEqual(enables[0][2]['head'], bot.HEAD)

    def test_metadata_completion_requires_current_full_ci_and_native_ready(self):
        for state in ('failure', 'cancelled', 'in_progress', 'missing', 'ready-pending', 'standby'):
            with self.subTest(state=state):
                b = MetadataAPI(bot.Transcript(), bot.NUMBER, bot.HEAD, bot.BASE, bot.MERGE)
                if state == 'missing':
                    b.base.runs = [b.run]
                elif state == 'ready-pending':
                    b.base.native_run.update(status='in_progress', conclusion=None)
                elif state != 'standby':
                    b.base.run.update(status='in_progress' if state == 'in_progress' else 'completed',
                                      conclusion=None if state == 'in_progress' else state)
                with mock.patch.dict(bot.os.environ, bot.TRUSTED, clear=True):
                    result = bot.p.coordinate(b, bot.NUMBER, state != 'standby', dict(id=META, run_attempt=1))
                self.assertIn('blocked:', result)
                self.assertFalse(b.base.mutations)

    def test_stale_foreign_unlisted_or_unverified_metadata_notification_cannot_arm(self):
        for change in (
                lambda b: b.run.update(head_sha='0' * 40),
                lambda b: b.run.update(run_attempt=2),
                lambda b: b.base.runs.remove(b.run),
                lambda b: b.run.update(display_title=m.PREFIX + 'forged'),
                lambda b: setattr(b, 'blob', '0' * 40),
                lambda b: b.jobs[0].update(steps=[dict(name='executed')]),
                lambda b: setattr(b, 'finish_mutation', lambda r: r.update(run_attempt=2))):
            b = MetadataAPI(bot.Transcript(), bot.NUMBER, bot.HEAD, bot.BASE, bot.MERGE)
            change(b)
            with mock.patch.dict(bot.os.environ, bot.TRUSTED, clear=True):
                result = bot.p.coordinate(b, bot.NUMBER, True, dict(id=META, run_attempt=1))
            self.assertNotIn('armed', result)
            self.assertFalse(b.base.mutations)

    def test_metadata_rerun_requires_the_current_attempt_and_rechecks_real_ci(self):
        b = MetadataAPI(bot.Transcript(), bot.NUMBER, bot.HEAD, bot.BASE, bot.MERGE)
        bot.failed_native(b.base)
        b.rerun()
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.dict(bot.os.environ, dict(bot.TRUSTED, GITHUB_OUTPUT=str(Path(directory) / 'output')), clear=True):
            self.assertIn('obsolete', bot.p.coordinate(b, bot.NUMBER, True, dict(id=META, run_attempt=1)))
            self.assertFalse(b.base.mutations)
            self.assertIn('read-only Ready receipt refresh', bot.p.coordinate(b, bot.NUMBER, True, dict(id=META, run_attempt=2)))
            b.base.run.update(conclusion='failure')
            self.assertIn('blocked:', bot.p.coordinate(b, bot.NUMBER, True, dict(id=META, run_attempt=2)))
        self.assertEqual(len(b.base.mutations), 2)
        self.assertIn('enablePullRequestAutoMerge', b.base.mutations[0][1])
        self.assertIn('disablePullRequestAutoMerge', b.base.mutations[1][1])



class OneShotGateTests(unittest.TestCase):
    """A metadata gate runs once; only a newer suite that proves validation replaces its non-success."""

    def assert_proven(self, configure):
        for name, prove, expected in consumers(configure):
            with self.subTest(consumer=name):
                self.assertEqual(prove(), expected)

    def assert_blocked(self, configure, pattern=''):
        for name, prove, _ in consumers(configure):
            with self.subTest(consumer=name), self.assertRaisesRegex(ValueError, pattern):
                prove()

    def test_unproven_gate_blocks_even_when_an_older_suite_reports_later(self):
        # PR #142 first dropped CI Required from metadata runs and the required
        # check stayed Expected: GitHub may judge the newest suite, not the newest
        # check. A later aggregate from the older validation suite is not enough.
        for end in (lambda a: a.end_gate('failure'), lambda a: a.end_gate('cancelled'), MetadataAPI.force_cancel_gate):
            self.assert_blocked(lambda a: (end(a), a.validation_required(40000, VALIDATION_DONE)),
                                'still the newest CI Required')

    def test_gate_that_ran_before_validation_was_created_is_historical(self):
        # A metadata event can win admission before its validation exists. Its
        # suite is older than that validation's, so it is ordinary history.
        for end in (lambda a: a.end_gate('failure'), MetadataAPI.force_cancel_gate):
            self.assert_proven(lambda a: (end(a), a.run.update(run_number=29)))

    def test_failed_or_force_cancelled_first_attempt_recovers_after_rerun(self):
        # #161, #163 and #170 stayed blocked because attempt 1 timed out even
        # after a successful rerun. Only the latest attempt is the native verdict.
        for end in (lambda a: a.end_gate('failure'), lambda a: a.end_gate('cancelled'), MetadataAPI.force_cancel_gate):
            self.assert_proven(lambda a: (end(a), a.rerun(), a.prove_gate()))
        b = bot_api()
        bot.failed_native(b.base)
        b.end_gate()
        b.rerun()
        b.prove_gate()
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.dict(bot.os.environ, dict(bot.TRUSTED, GITHUB_OUTPUT=str(Path(directory) / 'output')), clear=True):
            self.assertIn('obsolete', bot.p.coordinate(b, bot.NUMBER, True, dict(id=META, run_attempt=1)))
            self.assertIn('read-only Ready receipt refresh', bot.p.coordinate(b, bot.NUMBER, True, dict(id=META, run_attempt=2)))

    def test_superseded_attempt_never_hides_validation_work_or_unknown_outcomes(self):
        def first(change):
            def configure(a):
                a.end_gate()
                a.rerun()
                a.prove_gate()
                change(a, *a.attempt_gate(1))
            return configure
        attempt_mutations = [
            lambda a, job, check: job.update(steps=[dict(name=m.GATES['CI Required'], conclusion='success', status='completed')]),
            lambda a, job, check: job.update(steps=[dict(name=m.GATES['CI Required'], conclusion='failure', status='completed')]),
            lambda a, job, check: (job.update(conclusion='skipped'), check.update(conclusion='skipped')),
            lambda a, job, check: (job.update(conclusion='timed_out'), check.update(conclusion='timed_out')),
            lambda a, job, check: (job.update(conclusion='neutral'), check.update(conclusion='neutral')),
            lambda a, job, check: check.update(conclusion='success'),
            lambda a, job, check: a.jobs_by_attempt[1][0].update(steps=[dict(name='executed')]),
            lambda a, job, check: check.pop('completed_at'),
            lambda a, job, check: check.update(completed_at='not-a-time'),
            lambda a, job, check: check.update(completed_at=later(GATE_DONE, 600)),
        ]
        for index, mutate in enumerate(attempt_mutations):
            with self.subTest(attempt_mutation=index):
                self.assert_blocked(first(mutate))
        for index, mutate in enumerate([lambda a: a.run.update(conclusion='failure'),
                                        lambda a: (a.end_gate(), a.run.update(conclusion='success')),
                                        lambda a: a.run.update(status='in_progress', conclusion=None)]):
            with self.subTest(latest_mutation=index):
                self.assert_blocked(mutate)

    def test_only_a_newer_proven_metadata_run_supersedes_an_unproven_gate(self):
        unproven = bot_api()
        unproven.end_gate()
        with self.assertRaisesRegex(ValueError, 'still the newest CI Required'):
            bot.p.proof(unproven, bot.NUMBER)
        newer = bot_api(unproven, meta=9910, suite=9911, run_number=100, offset=500, completed=later(GATE_DONE, 30))
        self.assertEqual(bot.p.proof(newer, bot.NUMBER)['run'], bot.RUN)
        # A proven gate from an older suite cannot replace a newer suite's failure,
        # even when its check was created and completed later (for example a rerun).
        unproven = bot_api()
        unproven.end_gate()
        older = bot_api(unproven, meta=9910, suite=9911, run_number=98, offset=500, completed=later(GATE_DONE, 30))
        with self.assertRaisesRegex(ValueError, 'still the newest CI Required'):
            bot.p.proof(older, bot.NUMBER)
        first = bot_api()
        failed_later = bot_api(first, meta=9910, suite=9911, run_number=100, offset=500, completed=later(GATE_DONE, 30))
        failed_later.end_gate()
        with self.assertRaisesRegex(ValueError, 'still the newest CI Required'):
            bot.p.proof(failed_later, bot.NUMBER)

    def test_queued_metadata_run_proves_validation_after_it_finishes(self):
        # Dependabot and CodeRabbit edit the body right after a push. The metadata
        # run waits in the shared admission group, then proves the finished run.
        b = bot_api()
        bot.failed_native(b.base)
        t = b.transcript()
        t.run.update(status='in_progress', conclusion=None)
        b.run.update(status='queued', conclusion=None)
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.dict(bot.os.environ, dict(bot.TRUSTED, GITHUB_OUTPUT=str(Path(directory) / 'output')), clear=True):
            self.assertIn('blocked:', bot.p.coordinate(b, bot.NUMBER, True, dict(id=META, run_attempt=1)))
            self.assertFalse(b.base.mutations)
            t.run.update(status='completed', conclusion='success')
            b.run['status'] = 'completed'
            b.prove_gate()
            self.assertIn('read-only Ready receipt refresh', bot.p.coordinate(b, bot.NUMBER, True, dict(id=META, run_attempt=1)))
        self.assertEqual(len(b.base.mutations), 1)
        self.assertIn('enablePullRequestAutoMerge', b.base.mutations[0][1])
