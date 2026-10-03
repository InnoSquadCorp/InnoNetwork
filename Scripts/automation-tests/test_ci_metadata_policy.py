"""Native metadata no-ops cannot replace, green, cancel or hide real CI evidence."""
import copy
import importlib.util
import itertools
from pathlib import Path
import unittest
from unittest import mock

import test_dependabot_merge_policy as bot
import test_dependabot_ready_policy as ready
import test_main_ci_reuse_policy as reuse

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('metadata', ROOT / 'Scripts/ci-metadata-policy.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
META, SUITE, SOURCE = 9900, 9901, 'f' * 40


class MetadataAPI:
    def __init__(self, base, number, head, ancestor, current_source, *, expanded=False, inventory=None):
        self.base, self.head, self.current_source = base, head, current_source
        repo = base.repo
        self.run = dict(id=META, run_number=99, run_attempt=1, workflow_id=base.workflow['id'],
                        path=m.PATH, event='pull_request', head_sha=head, repository=repo, head_repository=repo,
                        pull_requests=[dict(number=number)],
                        status='completed', conclusion='success', check_suite_id=SUITE,
                        display_title=f'CI metadata-only v1 pr:{number} head:{head} base:{ancestor} action:labeled source:{SOURCE}')
        self.commit = dict(sha=SOURCE, parents=[dict(sha=ancestor), dict(sha=head)])
        self.blob = '9' * 40
        self.expected_blob = self.blob
        self.jobs, self.checks = [], []
        names = m.INVENTORIES[-1 if expanded else 0] if inventory is None else inventory
        for i, name in enumerate(sorted(names)):
            job = dict(id=20000+i, name=name, run_id=META, run_attempt=1, head_sha=head,
                       status='completed', conclusion='skipped', steps=[],
                       check_run_url=f'https://api.github.com/repos/{bot.p.REPOSITORY}/check-runs/{30000+i}')
            self.jobs.append(job)
            self.checks.append(dict(id=30000+i, name=name, app=dict(id=15368), check_suite=dict(id=SUITE),
                                    head_sha=head, status='completed', conclusion='skipped',
                                    details_url=f'https://github.com/{bot.p.REPOSITORY}/actions/runs/{META}/job/{job["id"]}'))
        for job, check in zip(self.jobs, self.checks):
            if job['name'] in m.GATES:
                job.update(conclusion='success', steps=[
                    dict(name=m.GATES[job['name']], conclusion='skipped', status='completed'),
                    dict(name='Verify prior validation for metadata', conclusion='success', status='completed')])
                check['conclusion'] = 'success'
        self.base.runs.append(self.run)
        self.jobs_by_attempt = {1: self.jobs}
        self.finish_mutation = None
        self.run_reads = 0

    def get(self, route):
        if route.endswith(f'actions/runs/{META}'):
            self.run_reads += 1
            result = copy.deepcopy(self.run)
            if self.run_reads % 2 == 0 and self.finish_mutation:
                self.finish_mutation(result)
            return result
        if route.endswith('git/commits/' + SOURCE):
            return copy.deepcopy(self.commit)
        if '/contents/' + m.PATH + '?ref=' in route:
            return dict(sha=self.blob if route.endswith(SOURCE) else self.expected_blob)
        return self.base.get(route)

    def pages(self, route, key=None):
        if f'check-suites/{SUITE}/' in route:
            return copy.deepcopy(self.checks)
        if f'actions/runs/{META}/attempts/' in route and route.endswith('/jobs'):
            return copy.deepcopy(self.jobs_by_attempt[int(route.split('/')[-2])])
        result = self.base.pages(route, key)
        if f'commits/{self.head}/check-runs?' in route:
            result += copy.deepcopy(self.checks)
        return result

    def graphql(self, query, variables):
        return self.base.graphql(query, variables)

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
            check.update(id=check_id + 100000,
                         details_url=f'https://github.com/{bot.p.REPOSITORY}/actions/runs/{META}/job/{job["id"]}')
            current_checks.append(check)
        self.checks.extend(current_checks)
        self.jobs_by_attempt[attempt] = self.jobs


def reuse_api(expanded=False, inventory=None):
    t = reuse.Transcript()
    return MetadataAPI(t, reuse.NUMBER, reuse.HEAD, reuse.BASE, reuse.MAIN, expanded=expanded, inventory=inventory)


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
            with self.subTest(already_armed=already_armed):
                b = MetadataAPI(bot.Transcript(), bot.NUMBER, bot.HEAD, bot.BASE, bot.MERGE)
                if already_armed:
                    b.base.pr['auto_merge'] = dict(enabled_by=dict(bot.p.BOT))
                b.run.update(status='in_progress', conclusion=None)
                with mock.patch.dict(bot.os.environ, bot.TRUSTED, clear=True):
                    blocked = bot.p.coordinate(b, bot.NUMBER, True, dict(id=bot.RUN, run_attempt=1))
                    self.assertIn('blocked:', blocked)
                    self.assertFalse(b.base.pr.get('auto_merge'))
                    b.run.update(status='completed', conclusion='success')
                    # A still-green reporter produces no refresh/completion
                    # event to rescue a discarded metadata wake-up.
                    self.assertIsNone(ready.n.refresh_plan(b, bot.p, bot.NUMBER, True))
                    notification = dict(id=META, run_attempt=1)
                    self.assertIn('armed', bot.p.coordinate(b, bot.NUMBER, True, notification))
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
        b.rerun()
        with mock.patch.dict(bot.os.environ, bot.TRUSTED, clear=True):
            self.assertIn('obsolete', bot.p.coordinate(b, bot.NUMBER, True, dict(id=META, run_attempt=1)))
            self.assertFalse(b.base.mutations)
            self.assertIn('armed', bot.p.coordinate(b, bot.NUMBER, True, dict(id=META, run_attempt=2)))
            b.base.run.update(conclusion='failure')
            self.assertIn('blocked:', bot.p.coordinate(b, bot.NUMBER, True, dict(id=META, run_attempt=2)))
        self.assertEqual(len(b.base.mutations), 2)
        self.assertIn('enablePullRequestAutoMerge', b.base.mutations[0][1])
        self.assertIn('disablePullRequestAutoMerge', b.base.mutations[1][1])
