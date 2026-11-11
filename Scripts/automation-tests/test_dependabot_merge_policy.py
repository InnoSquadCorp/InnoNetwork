"""Adversarial metadata transcripts for the privileged coordinator; no network."""
import copy
from datetime import datetime, timezone
import importlib.util
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('dependabot_policy', ROOT / 'Scripts/dependabot-merge-policy.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
HEAD, BASE, MERGE = 'a' * 40, 'b' * 40, 'c' * 40
NUMBER, RUN = 45, 900
READY_RUN = 950
NATIVE_RUN = 960
TRUSTED = dict(PATH=os.environ["PATH"], GITHUB_REPOSITORY=p.REPOSITORY, GITHUB_REF="refs/heads/main",
               GITHUB_WORKFLOW_REF=p.REPOSITORY + "/.github/workflows/dependabot-auto-merge.yml@refs/heads/main",
               GITHUB_EVENT_NAME="pull_request_target", GITHUB_RUN_ID=str(READY_RUN), GITHUB_RUN_ATTEMPT="1",
               GITHUB_JOB="bot-ready", GITHUB_WORKFLOW_SHA=BASE)
INVENTORY = json.loads((Path(__file__).parent / 'fixtures/dependabot-full-ci.json').read_text())['jobs']


class Transcript:
    def __init__(self):
        self.repo = dict(id=100, full_name=p.REPOSITORY, default_branch='main', allow_auto_merge=True, allow_squash_merge=True)
        self.pr = dict(number=NUMBER, node_id='PR_node', user=dict(p.BOT), state='open', merged=False, merged_at=None, draft=False,
                       mergeable=True, merge_commit_sha=MERGE, auto_merge=None, requested_reviewers=[], requested_teams=[],
                       base=dict(ref='main', sha=BASE, repo=self.repo), head=dict(ref="dependabot/test", sha=HEAD, repo=self.repo))
        self.base = BASE
        self.rules = [dict(type='required_status_checks', ruleset_source_type='Repository', ruleset_source=p.REPOSITORY,
                           ruleset_id=123, parameters=dict(strict_required_status_checks_policy=True,
                           required_status_checks=[dict(context=n, integration_id=p.APP) for n in ['CI Required', p.READY]]))]
        self.rules.append(dict(type='pull_request', ruleset_source_type='Repository', ruleset_source=p.REPOSITORY,
            ruleset_id=124, parameters=dict(required_review_thread_resolution=True, required_approving_review_count=0)))
        self.ruleset = dict(enforcement='active', bypass_actors=[], current_user_can_bypass='never')
        self.review_ruleset = copy.deepcopy(self.ruleset)
        self.workflow = dict(id=10, path=p.CI_PATH, state='active')
        self.run = dict(id=RUN, run_number=30, run_attempt=1, workflow_id=10, path=p.CI_PATH, check_suite_id=400,
                        event='pull_request', head_sha=HEAD, head_repository=self.repo, repository=self.repo,
                        status='completed', conclusion='success', pull_requests=[dict(number=NUMBER, head=dict(sha=HEAD), base=dict(sha=BASE))])
        self.runs = [self.run]
        self.ready_workflow = dict(id=11, path=p.COORDINATOR_PATH, state='active')
        self.ready_run = dict(id=READY_RUN, run_number=40, run_attempt=1, workflow_id=11,
                              path=p.COORDINATOR_PATH, check_suite_id=800, event='pull_request_target',
                              head_sha=HEAD, head_branch='dependabot/test', repository=self.repo, head_repository=self.repo,
                              status='in_progress', conclusion=None,
                              pull_requests=[dict(number=NUMBER, head=dict(sha=HEAD), base=dict(ref='main', repo=self.repo))])
        self.ready_runs = [self.ready_run]
        self.ready_jobs = {}
        self.jobs, self.checks = [], []
        for index, (name, steps) in enumerate(INVENTORY.items()):
            check_id, job_id = 1000 + index, 2000 + index
            result = 'skipped' if name in p.FULL_SKIPPED else 'success'
            self.jobs.append(dict(id=job_id, name=name, status='completed', conclusion=result,
                                 check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/{check_id}',
                                 steps=[dict(s, status='completed') for s in steps]))
            self.checks.append(dict(id=check_id, name=name, status='completed', conclusion=result,
                                   app=dict(id=p.APP), head_sha=HEAD, check_suite=dict(id=400),
                                   details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{RUN}/job/{job_id}'))
        self.merge_checks, self.statuses, self.review_list, self.threads = [], [], [], []
        self.graph_head, self.review_decision = HEAD, None
        self.mutations, self.reads = [], []
        self.old_jobs, self.post_runs, self.snapshot_runs = [], [], []
        self.graph_fail = False
        self.arm = None
        self.arm_event = None
        self.native_workflow = dict(id=12, path='.github/workflows/dependabot-ready.yml', state='active')
        self.native_run = dict(self.ready_run, id=NATIVE_RUN, workflow_id=12, path=self.native_workflow['path'],
                               check_suite_id=900, status='completed', conclusion='success',
                               created_at=datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'))
        self.native_runs = [self.native_run]
        self.ready_run['created_at'] = self.native_run['created_at']
        self.native_job = dict(id=9001, name=p.READY, status='completed', conclusion='success',
            check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/9000',
            steps=[dict(name=name, status='completed', conclusion='success') for name in
                   ['Checkout immutable trusted reporter source', 'Evaluate Ready snapshot from ' + BASE, 'Enforce Ready snapshot']])
        self.native_jobs = {(NATIVE_RUN, 1): [self.native_job]}
        self.native_check = dict(id=9000, name=p.READY, status='completed', conclusion='success',
            app=dict(id=p.APP), head_sha=HEAD, check_suite=dict(id=900),
            details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{NATIVE_RUN}/job/9001')
        self.checks.append(self.native_check)
        self.source_blobs = {}
        self.refresh_writers = []
        # Android/Web lane evidence; set by platform().
        self.files, self.compare_status = None, 'ahead'
        self.cross_workflow, self.cross_runs, self.cross_jobs = None, [], {}

    def get(self, route):
        self.reads.append(route)
        suffix = route.removeprefix(f'repos/{p.REPOSITORY}').lstrip('/')
        if not suffix: value = self.repo
        elif suffix == f'pulls/{NUMBER}': value = self.pr
        elif suffix == 'git/ref/heads/main': value = dict(object=dict(sha=self.base))
        elif suffix == f'git/commits/{MERGE}': value = dict(parents=[dict(sha=BASE), dict(sha=HEAD)])
        elif suffix == 'rulesets/123': value = self.ruleset
        elif suffix == 'rulesets/124': value = self.review_ruleset
        elif suffix == 'actions/workflows/ci.yml': value = self.workflow
        elif suffix == 'actions/workflows/dependabot-auto-merge.yml': value = self.ready_workflow
        elif suffix == 'actions/workflows/dependabot-ready.yml': value = self.native_workflow
        elif suffix == 'actions/workflows/cross-platform.yml' and self.cross_workflow: value = self.cross_workflow
        elif suffix == f'compare/{self.base}...{HEAD}' and self.files is not None:
            value = dict(status=self.compare_status, merge_base_commit=dict(sha=BASE), files=self.files)
        elif suffix.startswith('actions/runs/') and suffix.count('/') == 2 and int(suffix.rsplit('/', 1)[1]) in {r['id'] for r in self.cross_runs}:
            value = next(r for r in self.cross_runs if r['id'] == int(suffix.rsplit('/', 1)[1]))
        elif suffix.startswith('compare/'):
            value = dict(status='identical' if self.base == BASE else 'ahead', merge_base_commit=dict(sha=BASE))
        elif suffix.startswith('contents/'):
            value = dict(sha=self.source_blobs.get(suffix, 'd' * 40))
        elif suffix.startswith('actions/runs/') and suffix.count('/') == 2 and int(suffix.rsplit('/', 1)[1]) in {r['id'] for r in self.native_runs}:
            value = next(r for r in self.native_runs if r['id'] == int(suffix.rsplit('/', 1)[1]))
        elif suffix.startswith('actions/runs/') and suffix.count('/') == 2 and int(suffix.rsplit('/', 1)[1]) != RUN:
            value = next(r for r in self.ready_runs if r['id'] == int(suffix.rsplit('/', 1)[1]))
        elif suffix == f'actions/runs/{RUN}': value = self.run
        elif suffix.startswith('check-runs/'): value = next(c for c in self.checks if c['id'] == int(suffix.rsplit('/', 1)[1]))
        else: raise AssertionError('Unexpected read: ' + route)
        return copy.deepcopy(value)

    def pages(self, route, key=None):
        self.reads.append(route)
        suffix = route.removeprefix(f'repos/{p.REPOSITORY}/')
        if suffix == 'rules/branches/main': value = self.rules
        elif suffix == f'pulls/{NUMBER}/reviews': value = self.review_list
        elif suffix.startswith('actions/workflows/ci.yml/runs?event='): value = self.runs
        elif suffix.startswith('actions/workflows/dependabot-ready.yml/runs?event='): value = self.native_runs
        elif suffix.startswith('actions/workflows/dependabot-auto-merge.yml/runs?event='): value = self.ready_runs
        elif suffix.startswith('actions/workflows/dependabot-auto-merge.yml/runs?created='): value = self.refresh_writers
        elif suffix.startswith('actions/workflows/cross-platform.yml/runs?event='): value = self.cross_runs
        elif suffix.startswith('actions/runs/') and '/attempts/' in suffix and int(suffix.split('/')[2]) in {r['id'] for r in self.cross_runs}:
            value = self.cross_jobs.get((int(suffix.split('/')[2]), int(suffix.split('/')[4])), [])
        elif suffix.startswith('actions/runs/') and '/attempts/' in suffix and int(suffix.split('/')[2]) in {r['id'] for r in self.native_runs}:
            value = self.native_jobs.get((int(suffix.split('/')[2]), int(suffix.split('/')[4])), [])
        elif suffix.startswith('actions/runs/') and '/attempts/' in suffix and int(suffix.split('/')[2]) != RUN:
            value = self.ready_jobs.get((int(suffix.split('/')[2]), int(suffix.split('/')[4])), [])
        elif suffix.startswith('actions/workflows/ci.yml/runs?branch='): value = self.post_runs
        elif suffix.startswith('actions/workflows/dependency-submission.yml/runs?branch='): value = self.snapshot_runs
        elif suffix == f'actions/runs/{RUN}/attempts/{self.run["run_attempt"]}/jobs': value = self.jobs
        elif suffix.startswith(f'actions/runs/{RUN}/attempts/'): value = self.old_jobs
        elif suffix == f'commits/{HEAD}/check-runs?filter=all': value = self.checks
        elif suffix == f'commits/{MERGE}/check-runs?filter=all': value = self.merge_checks
        elif suffix.endswith('/statuses'): value = self.statuses
        elif suffix == f'commits/{self.base}/pulls': value = [self.pr]
        elif suffix in ('pulls?state=open&base=main', 'pulls?state=open'): value = [self.pr]
        else: raise AssertionError('Unexpected pages: ' + route)
        return copy.deepcopy(value)

    def graphql(self, query, variables):
        if query.startswith('mutation'):
            self.mutations.append(('graphql', query, copy.deepcopy(variables)))
            if self.graph_fail: raise PermissionError('403 denied')
            if 'disablePullRequestAutoMerge' in query:
                self.pr['auto_merge'] = None
                self.arm = None
            else:
                self.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
                actor = dict(login='github-actions', databaseId=41898282, __typename='Bot')
                created = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
                self.arm = dict(enabledAt=created, mergeMethod='SQUASH', enabledBy=actor)
                self.arm_event = dict(id='ARM_event', __typename='AutoSquashEnabledEvent', createdAt=created, actor=actor)
            return {}
        if 'timelineItems' in query:
            return dict(repository=dict(nameWithOwner=p.REPOSITORY, pullRequest=dict(id='PR_node', headRefOid=self.graph_head,
                autoMergeRequest=copy.deepcopy(self.arm), timelineItems=dict(nodes=[copy.deepcopy(self.arm_event)] if self.arm_event else []))))
        return dict(repository=dict(pullRequest=dict(id='PR_node', headRefOid=self.graph_head,
                    reviewDecision=self.review_decision, reviewThreads=dict(nodes=copy.deepcopy(self.threads),
                    pageInfo=dict(hasNextPage=False, endCursor=None)))))

    def mutate(self, method, route, payload):
        self.mutations.append((method, route, copy.deepcopy(payload)))
        if route.endswith('/check-runs'):
            check = dict(payload, id=8000 + len(self.checks), app=dict(id=p.APP), check_suite=dict(id=self.ready_run["check_suite_id"]))
            self.checks.append(check)
            return copy.deepcopy(check)
        if '/check-runs/' in route:
            check = next(c for c in self.checks if c['id'] == int(route.rsplit('/', 1)[1]))
            check.update(payload)
            return copy.deepcopy(check)
        if route.endswith('/dispatches'): return None
        raise AssertionError('Unexpected mutation: ' + route)


CROSS_RUN = 970
NPM_FILES = [dict(filename=directory + '/' + name, status='modified') for directory in (
    'Platforms/Web', 'SmokeTests/WebConsumer', 'SmokeTests/WebTarballConsumer', 'SmokeTests/ReactConsumer')
    for name in ('package.json', 'package-lock.json')]


def platform(api, call=0, smoke=0):
    """Rewrite the full transcript as a Dependabot npm run of the Android/Web CI lane."""
    inventory = p.platform_inventories()
    calls = [{'Release Candidate'}, {'Release Candidate / Validate ${{ matrix.runtime }} Build', 'Release Candidate / Validate Release'}]
    smokes = sorted({name for names in inventory for name in names if 'Consumer' in name and 'Smoke' in name})
    names = list(p.PLATFORM_CORE) + sorted(p.PLATFORM_SKIPPED) + sorted(calls[call]) + [smokes[smoke]]
    assert set(names) in inventory
    ran = {job['name']: job for job in api.jobs}
    api.checks = [c for c in api.checks if c['check_suite']['id'] != 400]
    api.jobs = []
    for index, name in enumerate(names):
        check_id, job_id = 3000 + index, 4000 + index
        result = 'success' if name in p.PLATFORM_CORE else 'skipped'
        api.jobs.append(dict(id=job_id, name=name, status='completed', conclusion=result,
                             check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/{check_id}',
                             steps=ran[name]['steps'] if result == 'success' else []))
        api.checks.append(dict(id=check_id, name=name, status='completed', conclusion=result,
                               app=dict(id=p.APP), head_sha=HEAD, check_suite=dict(id=400),
                               details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{RUN}/job/{job_id}'))
    api.pr['labels'] = [dict(name='dependencies'), dict(name='web')]
    api.files = copy.deepcopy(NPM_FILES)
    api.cross_workflow = dict(id=13, path=p.CROSS_PLATFORM_PATH, state='active')
    api.cross_run = dict(id=CROSS_RUN, run_number=31, run_attempt=1, workflow_id=13, path=p.CROSS_PLATFORM_PATH,
                         check_suite_id=410, event='pull_request', head_sha=HEAD, head_repository=api.repo,
                         repository=api.repo, status='completed', conclusion='success',
                         pull_requests=[dict(number=NUMBER, head=dict(sha=HEAD), base=dict(sha=BASE))])
    api.cross_runs = [api.cross_run]
    jobs = []
    for index, (name, steps) in enumerate(p.CROSS_PLATFORM.items()):
        check_id, job_id = 5000 + index, 6000 + index
        node_24_only = name.startswith('Web') and name != p.NODE_24
        steps = [dict(name=step, status='completed',
                      conclusion='skipped' if node_24_only and step in p.NODE_24_STEPS else 'success') for step in steps]
        jobs.append(dict(id=job_id, name=name, status='completed', conclusion='success',
                         check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/{check_id}',
                         steps=[dict(name='Set up job', status='completed', conclusion='success'), *steps,
                                dict(name='Complete job', status='completed', conclusion='success')]))
        api.checks.append(dict(id=check_id, name=name, status='completed', conclusion='success',
                               app=dict(id=p.APP), head_sha=HEAD, check_suite=dict(id=410),
                               details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{CROSS_RUN}/job/{job_id}'))
    api.cross_jobs = {(CROSS_RUN, 1): jobs}
    return api


def cross_job(api, name):
    return next(j for j in api.cross_jobs[(CROSS_RUN, 1)] if j['name'] == name)


def failed_native(api):
    for value in (api.native_run, api.native_job, api.native_check):
        value.update(status='completed', conclusion='failure')
    api.native_job['steps'][-1]['conclusion'] = 'failure'


class DependabotPolicyTests(unittest.TestCase):
    def setUp(self):
        self.api = Transcript()
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.output = Path(directory.name) / 'outputs'
        self.environment = mock.patch.dict(os.environ, dict(TRUSTED, GITHUB_OUTPUT=str(self.output)), clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def reject(self, alter):
        api = Transcript()
        alter(api)
        with self.assertRaises((p.Rejected, KeyError, TypeError, ValueError)):
            p.proof(api, NUMBER)
        self.assertFalse(api.mutations)

    def test_complete_full_transcript_allows_major_and_toolchain(self):
        for title in ['chore(deps): bump swift-syntax to 604.0.0', 'chore(ci): major action v8', 'arbitrary title']:
            self.api.pr['title'] = title
            proof = p.proof(self.api, NUMBER)
            self.assertEqual((proof['head'], proof['base'], proof['run']), (HEAD, BASE, RUN))
        self.assertFalse(self.api.mutations)


    def test_author_repository_and_pr_state_controls(self):
        changes = [lambda a: a.pr['user'].update(login='human', type='User'),
                   lambda a: a.pr['user'].update(id=123), lambda a: a.pr['user'].update(type='User'),
                   lambda a: a.pr['head'].update(repo=dict(id=101, full_name=p.REPOSITORY)),
                   lambda a: a.pr['base'].update(ref='develop'), lambda a: a.pr.update(draft=True),
                   lambda a: a.pr.update(mergeable=False), lambda a: a.pr.update(mergeable=None),
                   lambda a: a.pr.update(state='closed'), lambda a: a.pr['head'].update(sha='bad'),
                   lambda a: a.repo.update(default_branch='develop')]
        for change in changes:
            with self.subTest(change=change): self.reject(change)

    def test_native_guard_controls(self):
        changes = [lambda a: a.repo.update(allow_auto_merge=False), lambda a: a.repo.update(allow_squash_merge=False),
                   lambda a: a.rules.clear(), lambda a: a.ruleset.update(enforcement='evaluate'),
                   lambda a: a.ruleset.update(bypass_actors=[dict(actor_id=p.APP, actor_type='Integration')]),
                   lambda a: a.ruleset.update(current_user_can_bypass='always'),
                   lambda a: a.rules[0]['parameters'].pop('strict_required_status_checks_policy'),
                   lambda a: a.rules[0]['parameters']['required_status_checks'].pop(),
                   lambda a: a.rules[0]['parameters']['required_status_checks'][0].update(integration_id=None)]
        for change in changes:
            with self.subTest(change=change): self.reject(change)

    def test_readonly_merge_settings_use_identity_bound_query_only(self):
        for missing in [('allow_auto_merge',), ('allow_squash_merge',),
                        ('allow_auto_merge', 'allow_squash_merge')]:
            repo = copy.deepcopy(self.api.repo)
            for key in missing: repo.pop(key)
            result = dict(repository=dict(databaseId=100, nameWithOwner=p.REPOSITORY,
                                          autoMergeAllowed=True, squashMergeAllowed=True))
            with mock.patch.object(self.api, 'graphql', return_value=result) as query:
                p.native_merge_settings(self.api, repo)
            self.assertEqual(query.call_count, 1)
            self.assertTrue(query.call_args.args[0].startswith('query('))
            self.assertEqual(query.call_args.args[1], dict(owner='InnoSquadCorp', name='InnoNetwork'))
        with mock.patch.object(self.api, 'graphql') as query:
            p.native_merge_settings(self.api, self.api.repo)
            query.assert_not_called()
        self.assertFalse(self.api.mutations)

    def test_merge_settings_never_promote_false_malformed_or_unknown_evidence(self):
        for value in [False, None, 'true', 1, 0]:
            for field in ['allow_auto_merge', 'allow_squash_merge']:
                repo = dict(self.api.repo, **{field: value})
                repo.pop('allow_squash_merge' if field == 'allow_auto_merge' else 'allow_auto_merge')
                with mock.patch.object(self.api, 'graphql') as query:
                    with self.subTest(field=field, value=value), self.assertRaises(p.Rejected):
                        p.native_merge_settings(self.api, repo)
                    query.assert_not_called()
        repo = dict(self.api.repo)
        repo.pop('allow_auto_merge')
        good = dict(databaseId=100, nameWithOwner=p.REPOSITORY, autoMergeAllowed=True, squashMergeAllowed=True)
        cases = [None, {}, dict(good, databaseId=True), dict(good, databaseId=101),
                 dict(good, nameWithOwner='other/repo')]
        for field in ['autoMergeAllowed', 'squashMergeAllowed']:
            cases.extend(dict(good, **{field: value}) for value in [None, False, 'true', 1])
            cases.append({k: v for k, v in good.items() if k != field})
        for settings in cases:
            with mock.patch.object(self.api, 'graphql', return_value=dict(repository=settings)):
                with self.subTest(settings=settings), self.assertRaises(p.Rejected):
                    p.native_merge_settings(self.api, repo)
        with mock.patch.object(self.api, 'graphql', side_effect=PermissionError('unavailable')):
            with self.assertRaisesRegex(p.Rejected, 'GraphQL unavailable'):
                p.native_merge_settings(self.api, repo)
        self.assertFalse(self.api.mutations)

    def test_readonly_fallback_keeps_explicit_native_profile_and_full_proof(self):
        self.api.repo.pop('allow_auto_merge')
        self.api.rules[0]['parameters']['strict_required_status_checks_policy'] = False
        settings = dict(repository=dict(databaseId=100, nameWithOwner=p.REPOSITORY,
                                        autoMergeAllowed=True, squashMergeAllowed=True))
        with mock.patch.object(self.api, 'graphql', return_value=settings):
            p.native_rules(self.api, self.api.repo)
        self.assertFalse(self.api.mutations)

    def test_native_review_barrier_and_runtime_no_bypass_visibility_are_required(self):
        for mutate in [lambda a: a.rules.pop(),
                       lambda a: a.rules[-1]['parameters'].update(required_review_thread_resolution=False),
                       lambda a: a.rules[-1]['parameters'].pop('required_review_thread_resolution'),
                       lambda a: a.rules[-1]['parameters'].update(required_approving_review_count=True),
                       lambda a: a.rules[-1]['parameters'].update(required_approving_review_count=-1),
                       lambda a: a.rules[-1].update(ruleset_source_type='Organization'),
                       lambda a: a.rules[-1].update(ruleset_source='foreign/repo'),
                       lambda a: a.ruleset.pop('current_user_can_bypass'),
                       lambda a: a.ruleset.update(current_user_can_bypass='always'),
                       lambda a: a.ruleset.update(current_user_can_bypass='pull_requests_only')]:
            self.reject(mutate)
        api = Transcript()
        api.ruleset.pop('bypass_actors')
        api.ruleset.pop('current_user_can_bypass')
        with self.assertRaisesRegex(p.Rejected, 'no-bypass'): p.proof(api, NUMBER)
        api = Transcript()
        api.ruleset.pop('bypass_actors')  # Explicit runtime never still proves this token cannot bypass.
        p.proof(api, NUMBER)
        api.rules[-1]['parameters']['required_approving_review_count'] = 0
        p.proof(api, NUMBER)
        self.assertFalse(api.mutations)

    def test_base_retarget_cannot_reuse_previous_base_ci_at_same_head(self):
        previous_base = 'd' * 40
        self.api.run['pull_requests'][0]['base']['sha'] = previous_base
        with self.assertRaisesRegex(p.Rejected, 'obsolete head/base'):
            p.proof(self.api, NUMBER)
        self.assertFalse(self.api.mutations)

    def test_wrong_or_stale_run_connections(self):
        changes = [lambda a: a.run.update(path='.github/workflows/release.yml'),
                   lambda a: a.run.update(event='push'), lambda a: a.run.update(workflow_id=11),
                   lambda a: a.run.update(head_sha='d' * 40), lambda a: a.run.update(pull_requests=[]),
                   lambda a: a.run['pull_requests'][0]['base'].update(sha='d' * 40),
                   lambda a: a.run['pull_requests'][0]['head'].update(sha='d' * 40),
                   lambda a: a.pr['base'].update(sha='d' * 40), lambda a: a.run.update(status='in_progress'),
                   lambda a: a.run.update(conclusion='failure'), lambda a: a.runs.clear(),
                   lambda a: a.run.update(head_repository=dict(id=101))]
        for change in changes:
            with self.subTest(change=change): self.reject(change)

    def test_all_matrix_jobs_steps_and_attributed_checks_required(self):
        changes = [lambda a: a.jobs.pop(4), lambda a: a.jobs.append(copy.deepcopy(a.jobs[0])),
                   lambda a: a.jobs[4].update(conclusion='skipped'), lambda a: a.jobs[5].update(conclusion='cancelled'),
                   lambda a: a.jobs[0].update(steps=[]), lambda a: next(s for s in a.jobs[0]['steps'] if s['name'] == 'Plan exact changed paths').update(conclusion='skipped'),
                   lambda a: a.checks.pop(4), lambda a: a.checks[4]['app'].update(id=123),
                   lambda a: a.checks[4]['check_suite'].update(id=123), lambda a: a.checks[4].update(head_sha=BASE),
                   lambda a: a.checks[4].update(details_url='https://evil.test'), lambda a: a.checks[4].update(conclusion='failure'),
                   lambda a: a.jobs[4].update(check_run_url='https://evil.test/123'),
                   lambda a: a.checks.append(dict(a.checks[4], id=7777))]
        for change in changes:
            with self.subTest(change=change): self.reject(change)

    def test_only_predefined_non_target_skips(self):
        p.proof(self.api, NUMBER)  # Pages, main-tip-only and origin guard are PR non-targets.
        for name in ['CI Required', 'Build and Test (SwiftPM) — Xcode 26.0.1', 'Build DocC Site']:
            self.reject(lambda a: next(j for j in a.jobs if j['name'] == name).update(conclusion='skipped'))

    def reject_platform(self, alter):
        api = platform(Transcript())
        alter(api)
        with self.assertRaises((p.Rejected, KeyError, TypeError, ValueError)):
            p.proof(api, NUMBER)
        self.assertFalse(api.mutations)

    def test_dependabot_android_web_lane_accepts_exact_cross_platform_success(self):
        for call in (0, 1):
            for smoke in (0, 1):
                with self.subTest(call=call, smoke=smoke):
                    api = platform(Transcript(), call, smoke)
                    first, second = p.proof(api, NUMBER), p.proof(api, NUMBER)
                    p.same(first, second)
                    self.assertEqual((first['lane'], first['platform'], first['run']),
                                     ('platform', dict(run=CROSS_RUN, attempt=1), RUN))
                    self.assertFalse(api.mutations)
        # The full lane stays acceptable and reads no diff or Cross-platform evidence.
        self.assertEqual(p.proof(self.api, NUMBER)['lane'], 'full')
        self.assertFalse([r for r in self.api.reads if f'...{HEAD}' in r or 'cross-platform' in r])
        # The advisory npm audit may fail; Node 22/26 skip the Node 24-only steps.
        api = platform(Transcript())
        next(s for s in cross_job(api, p.NODE_24)['steps'] if s['name'] == p.ADVISORY_STEP)['conclusion'] = 'failure'
        p.proof(api, NUMBER)
        api = platform(Transcript())
        api.files = api.files[:1] + [dict(filename='SmokeTests/ReactConsumer/package-lock.json', status='added')]
        p.proof(api, NUMBER)

    def test_android_web_lane_requires_the_planner_rule_on_api_evidence(self):
        changes = [lambda a: a.pr['labels'].append(dict(name='release-validation')),
                   lambda a: a.pr['labels'].append(dict(name='Concurrency-Review')),
                   lambda a: a.pr.pop('labels'), lambda a: a.pr.update(labels=[dict(name=1)]),
                   lambda a: a.files.append(dict(filename='Package.resolved', status='modified')),
                   lambda a: a.files.append(dict(filename='Platforms/Web/README.md', status='modified')),
                   lambda a: a.files.append(dict(filename='.github/workflows/cross-platform.yml', status='modified')),
                   lambda a: a.files.append(dict(filename='Scripts/ci-policy.py', status='modified')),
                   lambda a: a.files[0].update(status='removed'),
                   lambda a: a.files[0].update(status='renamed', previous_filename='Sources/A.swift'),
                   lambda a: a.files[0].update(status='changed'), lambda a: a.files[0].update(status='copied'),
                   lambda a: a.files[0].update(filename='../Platforms/Web/package.json'),
                   lambda a: a.files[0].pop('filename'), lambda a: a.files.clear(),
                   lambda a: a.files.extend(dict(filename=f'Platforms/Web/f{i}.json', status='added') for i in range(300)),
                   lambda a: setattr(a, 'compare_status', 'identical'), lambda a: setattr(a, 'compare_status', 'behind'),
                   lambda a: setattr(a, 'files', 'Platforms/Web/package.json')]
        for change in changes:
            with self.subTest(change=change): self.reject_platform(change)

    def test_android_web_lane_ci_inventory_is_exact(self):
        def job(name):
            return lambda a: next(j for j in a.jobs if j['name'] == name)
        def drop(name):
            # Job and native check vanish together, so only the inventory notices.
            def change(a):
                a.jobs.remove(job(name)(a))
                a.checks.remove(next(c for c in a.checks if c['name'] == name))
            return change
        def add(name):
            def change(a):
                a.jobs.append(dict(job('Run Benchmarks')(a), id=4999, name=name,
                                   check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/3999'))
                a.checks.append(dict(next(c for c in a.checks if c['name'] == 'Run Benchmarks'), id=3999, name=name,
                                     details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{RUN}/job/4999'))
            return change
        changes = [drop('CodeQL / java-kotlin'), drop('Run Benchmarks'), drop('CI Required'), add('Unreviewed Job'),
                   add('Release Candidate / Validate Release'), add('Build and Test (SwiftPM) — Xcode 26.0.1'),
                   lambda a: job('CodeQL / Swift (swift)')(a).update(conclusion='skipped'),
                   lambda a: job('Dependency Review')(a).update(conclusion='skipped', steps=[]),
                   lambda a: job('CI Required')(a).update(steps=[]),
                   lambda a: job('Run Benchmarks')(a).update(conclusion='success'),
                   lambda a: job('Run Benchmarks')(a).update(steps=[dict(name='Run', status='completed', conclusion='skipped')]),
                   lambda a: job('Run Benchmarks')(a).update(name='Run Benchmarks (macOS)'),
                   lambda a: a.jobs.remove(job('Run Benchmarks')(a)),
                   lambda a: a.jobs.remove(job('CodeQL / java-kotlin')(a)),
                   lambda a: a.jobs.append(dict(job('Release Candidate')(a), id=4999, name='Release Candidate / Validate Release')),
                   lambda a: a.jobs.append(copy.deepcopy(a.jobs[-1])),
                   lambda a: next(c for c in a.checks if c['name'] == 'Run Benchmarks').update(conclusion='success'),
                   lambda a: next(c for c in a.checks if c['name'] == 'Build DocC Site').update(check_suite=dict(id=999))]
        for change in changes:
            with self.subTest(change=change): self.reject_platform(change)

    def test_android_web_lane_requires_exact_head_cross_platform_success(self):
        def check(name):
            return lambda a: next(c for c in a.checks if c['name'] == name)
        def step(job, name):
            return lambda a: next(s for s in cross_job(a, job)['steps'] if s['name'] == name)
        changes = [lambda a: a.cross_runs.clear(), lambda a: a.cross_workflow.update(state='disabled_manually'),
                   lambda a: a.cross_workflow.update(path=p.CI_PATH), lambda a: a.cross_run.update(conclusion='failure'),
                   lambda a: a.cross_run.update(status='in_progress', conclusion=None),
                   lambda a: a.cross_run.update(event='push'), lambda a: a.cross_run.update(head_sha='d' * 40),
                   lambda a: a.cross_run.update(workflow_id=10), lambda a: a.cross_run.update(path=p.CI_PATH),
                   lambda a: a.cross_run.update(pull_requests=[]), lambda a: a.cross_run.update(head_repository=dict(id=101)),
                   lambda a: a.cross_run['pull_requests'][0]['base'].update(sha='d' * 40),
                   lambda a: a.cross_run['pull_requests'][0]['head'].update(sha='d' * 40),
                   lambda a: a.cross_runs.append(dict(a.cross_run, id=CROSS_RUN + 1, run_number=32,
                                                      status='in_progress', conclusion=None)),
                   lambda a: a.cross_jobs[(CROSS_RUN, 1)].pop(),
                   lambda a: a.cross_jobs[(CROSS_RUN, 1)].append(copy.deepcopy(a.cross_jobs[(CROSS_RUN, 1)][0])),
                   lambda a: cross_job(a, 'Android 1.0 / JDK 17').update(conclusion='skipped'),
                   lambda a: cross_job(a, 'Web 1.0 / Node 22').update(check_run_url='https://evil.test/1'),
                   lambda a: check('Web 1.0 / Node 26')(a).update(check_suite=dict(id=999)),
                   lambda a: check('Web 1.0 / Node 26')(a).update(app=dict(id=123)),
                   lambda a: check('Web 1.0 / Node 26')(a).update(head_sha=BASE),
                   lambda a: check('Web 1.0 / Node 26')(a).update(details_url='https://evil.test'),
                   lambda a: cross_job(a, 'Android 1.0 / JDK 21')['steps'].remove(step('Android 1.0 / JDK 21', 'Verify Android public API')(a)),
                   lambda a: step('Android 1.0 / JDK 21', 'Set up JDK')(a).update(conclusion='skipped'),
                   lambda a: step(p.NODE_24, 'Verify Chromium, Firefox, and WebKit runtimes')(a).update(conclusion='skipped'),
                   lambda a: step('Web 1.0 / Node 22', p.ADVISORY_STEP)(a).update(conclusion='failure'),
                   lambda a: step('Web 1.0 / Node 22', 'Test and build Web package')(a).update(conclusion='skipped'),
                   lambda a: step(p.NODE_24, 'Test and build Web package')(a).update(status='in_progress', conclusion=None)]
        for change in changes:
            with self.subTest(change=change): self.reject_platform(change)

    def test_android_web_lane_arms_natively_and_detects_cross_platform_races(self):
        api = platform(Transcript())
        failed_native(api)
        self.assertIn('read-only Ready receipt refresh', p.coordinate(api, NUMBER, True))
        native = [m for m in api.mutations if m[0] == 'graphql']
        self.assertEqual(len(native), 1)
        self.assertEqual(native[0][2]['head'], HEAD)
        api = platform(Transcript())
        first = p.proof(api, NUMBER)
        api.cross_run['run_attempt'] = 2
        api.cross_jobs[(CROSS_RUN, 2)] = api.cross_jobs[(CROSS_RUN, 1)]
        with self.assertRaisesRegex(p.Rejected, 'raced'):
            p.same(first, p.proof(api, NUMBER))

    def test_additional_page_two_check_and_status_failures(self):
        for state in ['queued', 'in_progress', 'failure', 'cancelled', 'skipped', 'neutral']:
            extra = dict(id=7000, name='External quality', app=dict(id=123), head_sha=HEAD,
                         check_suite=dict(id=999), status='completed', conclusion=state)
            self.reject(lambda a: a.checks.append(extra))
        self.reject(lambda a: a.merge_checks.append(dict(id=7000, name='Other matrix', app=dict(id=123),
                    head_sha=MERGE, check_suite=dict(id=999), status='completed', conclusion='failure')))
        self.reject(lambda a: a.statuses.append(dict(context='Legacy CI', state='pending')))

    def test_review_changes_requested_is_not_cleared_by_comments(self):
        self.api.review_list = [dict(id=1, user=dict(id=3), state='CHANGES_REQUESTED'),
                                dict(id=2, user=dict(id=3), state='COMMENTED')]
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)
        self.api.review_list.append(dict(id=3, user=dict(id=3), state='DISMISSED'))
        p.proof(self.api, NUMBER)
        self.reject(lambda a: a.threads.append(dict(isResolved=False)))
        self.reject(lambda a: a.__setattr__('graph_head', 'd' * 40))
        self.reject(lambda a: a.__setattr__('review_decision', 'REVIEW_REQUIRED'))

    def test_older_success_cannot_override_latest_failure_or_pending(self):
        self.api.run.update(run_attempt=2, conclusion='failure')
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)
        self.api.run.update(conclusion='success')
        old = dict(self.api.checks[0], id=6000, conclusion='failure')
        self.api.old_jobs = [dict(check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/6000')]
        self.api.checks.append(old)
        p.proof(self.api, NUMBER)  # Fully verified successful current attempt supersedes failed old attempt.
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER, dict(id=RUN, run_attempt=1))

    def test_ready_check_does_not_wait_on_itself_and_is_identity_pinned(self):
        self.api.native_check.update(status='in_progress', conclusion=None)
        p.proof(self.api, NUMBER)
        self.api.checks[-1]['app']['id'] = 123
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)

    def test_human_with_bot_labels_gets_manual_success_without_enable(self):
        self.api.pr.update(user=dict(id=1, login='human', type='User'), labels=[dict(name='dependencies')], draft=True)
        self.assertIn('manual PR', p.coordinate(self.api, NUMBER, True))
        self.assertFalse(any(m[0] == 'graphql' for m in self.api.mutations))
        self.assertEqual(self.api.native_check['conclusion'], 'success')

    def test_standby_never_enables_auto_merge(self):
        self.assertIn('standby', p.coordinate(self.api, NUMBER, False))
        self.assertFalse(any(m[0] == 'graphql' for m in self.api.mutations))
        self.assertFalse(any(m[0] in {'POST', 'PATCH'} for m in self.api.mutations))

    def test_missing_or_malformed_native_profile_cannot_arm_with_green_ci(self):
        for strict in [None, 0, 1, 'true', 'false']:
            for armed in [False, True]:
                api = Transcript()
                api.rules[0]['parameters']['strict_required_status_checks_policy'] = strict
                if armed:
                    api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
                result = p.coordinate(api, NUMBER, True)
                with self.subTest(strict=strict, armed=armed):
                    self.assertIn('standby: native strict-base policy is missing or malformed', result)
                    self.assertIsNone(api.pr['auto_merge'])
                    self.assertEqual(len(api.mutations), int(armed))
                    if armed:
                        self.assertIn('disablePullRequestAutoMerge', api.mutations[0][1])

    def test_invalid_profile_reports_unconfirmed_protective_cancellation(self):
        self.api.rules[0]['parameters']['strict_required_status_checks_policy'] = None
        self.api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
        self.api.graph_fail = True
        with self.assertRaisesRegex(p.Rejected, 'cancellation unconfirmed'):
            p.coordinate(self.api, NUMBER, True)
        self.assertEqual(len(self.api.mutations), 1)
        self.assertIn('disablePullRequestAutoMerge', self.api.mutations[0][1])

    def test_explicit_strict_profiles_and_optional_requests_preserve_native_guards(self):
        for strict in [False, True]:
            api = Transcript()
            api.rules[0]['parameters']['strict_required_status_checks_policy'] = strict
            api.pr.update(requested_reviewers=[dict(id=3)], requested_teams=[dict(id=4)])
            failed_native(api)
            self.assertIn('read-only Ready receipt refresh', p.coordinate(api, NUMBER, True))
            self.assertEqual(len(api.mutations), 1)
            self.assertIn('enablePullRequestAutoMerge', api.mutations[0][1])
            self.assertFalse(any('/check-runs' in str(m) for m in api.mutations))

    def test_non_strict_optional_requests_never_waive_current_evidence(self):
        changes = [lambda a: a.review_list.append(dict(id=1, user=dict(id=3), state='PENDING')),
                   lambda a: a.review_list.append(dict(id=1, user=dict(id=3), state='CHANGES_REQUESTED')),
                   lambda a: setattr(a, 'review_decision', 'REVIEW_REQUIRED'),
                   lambda a: a.threads.append(dict(isResolved=False)),
                   lambda a: setattr(a, 'base', 'd' * 40),
                   lambda a: a.run['pull_requests'][0]['base'].update(sha='d' * 40),
                   lambda a: a.run.update(conclusion='failure'),
                   lambda a: a.jobs[4].update(conclusion='skipped'),
                   lambda a: a.ruleset.update(current_user_can_bypass='always')]
        for change in changes:
            api = Transcript()
            api.rules[0]['parameters']['strict_required_status_checks_policy'] = False
            api.pr.update(requested_reviewers=[dict(id=3)], requested_teams=[dict(id=4)])
            change(api)
            with self.subTest(change=change):
                self.assertIn('blocked', p.coordinate(api, NUMBER, True))
                self.assertFalse(api.mutations)

    def test_failure_barrier_enables_native_expected_head_and_emits_receipt(self):
        failed_native(self.api)
        self.assertIn('read-only Ready receipt refresh', p.coordinate(self.api, NUMBER, True))
        native = [m for m in self.api.mutations if m[0] == 'graphql']
        self.assertEqual(len(native), 1)
        self.assertEqual(native[0][2]['head'], HEAD)
        self.assertIn('expectedHeadOid', native[0][1])
        self.assertIn('mergeMethod:SQUASH', native[0][1])
        self.assertIn('arm_receipt=Native arm v1', self.output.read_text())
        self.assertEqual(self.api.native_check['conclusion'], 'failure')
        # Until the real job/receipt step succeeds, another wake must cancel.
        self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertIsNone(self.api.pr['auto_merge'])

    def test_unarmed_green_ready_requires_failure_refresh_before_enable(self):
        self.assertIn('refresh unarmed success first', p.coordinate(self.api, NUMBER, True))
        self.assertFalse(self.api.mutations)
        self.assertFalse(self.output.exists())

    def test_head_base_or_attempt_race_blocks_or_cancels_native_enable(self):
        for field in ['head', 'base', 'merge', 'run', 'attempt', 'node']:
            for phase in [2, 3]:
                api = Transcript()
                failed_native(api)
                proof = p.proof(api, NUMBER)
                changed = dict(proof, **{field: 2 if field in {'run', 'attempt'} else 'd' * 40})
                evidence = [proof] * (phase - 1) + [changed]
                with self.subTest(field=field, phase=phase), mock.patch.object(p, 'proof', side_effect=evidence):
                    self.assertIn('blocked', p.coordinate(api, NUMBER, True))
                self.assertIsNone(api.pr['auto_merge'])
                self.assertEqual(len(api.mutations), 0 if phase == 2 else 2)
                if phase == 3:
                    self.assertIn('disablePullRequestAutoMerge', api.mutations[-1][1])

    def test_changed_or_failed_final_native_failure_barrier_cancels(self):
        readiness = p.ready_policy()
        arming = readiness.arm_policy()
        failed_native(self.api)
        barrier = arming.failed_reporter(self.api, p, readiness, NUMBER, HEAD)
        for verdict in [dict(barrier, attempt=2), p.Rejected('barrier changed')]:
            api = Transcript()
            failed_native(api)
            with mock.patch.object(p, 'ready_policy', return_value=readiness), \
                    mock.patch.object(readiness, 'arm_policy', return_value=arming), \
                    mock.patch.object(arming, 'failed_reporter', side_effect=[barrier, barrier, verdict]):
                self.assertIn('blocked', p.coordinate(api, NUMBER, True))
            self.assertIsNone(api.pr['auto_merge'])
            self.assertEqual(len(api.mutations), 2)
            self.assertIn('disablePullRequestAutoMerge', api.mutations[-1][1])
            self.assertFalse(self.output.exists())

    def test_third_proof_failure_cancels_before_receipt_or_ready_release(self):
        failed_native(self.api)
        proof = p.proof(self.api, NUMBER)
        with mock.patch.object(p, 'proof', side_effect=[proof, proof, p.Rejected('review raced')]):
            self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertEqual(len(self.api.mutations), 2)
        self.assertIn('disablePullRequestAutoMerge', self.api.mutations[-1][1])
        self.assertFalse(self.output.exists())
        self.assertEqual(self.api.native_check['conclusion'], 'failure')

    def test_base_edit_cancels_only_verified_bot_auto_request(self):
        self.api.pr['base']['ref'] = 'develop'
        self.api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
        self.assertIn('wrong base', p.coordinate(self.api, NUMBER, True))
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertFalse(any(m[0] in {'POST', 'PATCH'} for m in self.api.mutations))

    def test_permission_denial_does_not_retry_enable_or_direct_merge(self):
        failed_native(self.api)
        self.api.graph_fail = True
        self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertEqual(len([m for m in self.api.mutations if m[0] == 'graphql']), 1)
        self.assertFalse(any(str(m[1]).endswith('/merge') for m in self.api.mutations))
        self.assertFalse(any(m[0] in {'POST', 'PATCH'} for m in self.api.mutations))

    def test_obsolete_notification_cannot_overwrite_gate(self):
        self.assertIn('obsolete', p.coordinate(self.api, NUMBER, True, dict(id=RUN, run_attempt=0)))
        self.assertFalse(self.api.mutations)

    def test_redacted_bypass_list_is_not_treated_as_empty_or_admin_requirement(self):
        del self.api.ruleset['bypass_actors']
        p.proof(self.api, NUMBER)
        self.api.ruleset['current_user_can_bypass'] = 'pull_requests_only'
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)

    def test_gate_failure_still_cancels_existing_native_request(self):
        self.api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
        with mock.patch.object(self.api, 'mutate', side_effect=PermissionError('checks write denied')):
            result = p.coordinate(self.api, NUMBER, False)
        self.assertIn('blocked', result)
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertIn('disablePullRequestAutoMerge', self.api.mutations[-1][1])

    def test_both_gate_and_cancel_failure_surface_uncertainty(self):
        self.api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
        self.api.graph_fail = True
        with mock.patch.object(self.api, 'mutate', side_effect=PermissionError('checks write denied')):
            with self.assertRaisesRegex(p.Rejected, 'cancellation unconfirmed'):
                p.coordinate(self.api, NUMBER, False)

    def transport(self, name, status='in_progress', conclusion=None):
        check_id = 7000 + len(self.api.ready_jobs.get((READY_RUN, 1), []))
        job = dict(id=check_id, name=name, status=status, conclusion=conclusion,
                   run_id=READY_RUN, run_attempt=1, head_sha=HEAD, steps=[],
                   check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/{check_id}')
        if name == 'inspect':
            job['steps'] = [dict(name=p.COORDINATOR_SOURCE_STEP + BASE, status=status, conclusion=conclusion)]
        self.api.ready_jobs.setdefault((READY_RUN, 1), []).append(job)
        check = dict(job, app=dict(id=p.APP), head_sha=HEAD, check_suite=dict(id=800),
                     details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{READY_RUN}/job/{check_id}')
        self.api.checks.append(check)
        return job, check

    def test_exact_coordinator_transport_has_no_self_cycle(self):
        self.transport('inspect', 'completed', 'success')
        self.transport(f'bot-ready ({NUMBER})')
        self.transport('ready-plan', 'completed', 'skipped')
        self.transport('ready-refresh', 'completed', 'skipped')
        self.transport('post-merge-plan', 'queued')
        self.transport('post-merge', 'queued')
        self.assertIn('armed', p.coordinate(self.api, NUMBER, True))
        self.assertEqual(self.api.native_check['conclusion'], 'success')

    def test_actual_unexpanded_refresh_name_is_only_a_bound_empty_pr_target_skip(self):
        source = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        expression = source.split('  ready-refresh:\n', 1)[1].split('    name: ${{ ', 1)[1].split(' }}', 1)[0]
        self.assertEqual(expression, p.SKIPPED_REFRESH_NAME)
        self.transport('inspect', 'completed', 'success')
        self.transport(p.SKIPPED_REFRESH_NAME, 'completed', 'skipped')
        self.assertIn('armed', p.coordinate(self.api, NUMBER, True))

    def test_refresh_skip_rejects_lookalikes_executed_steps_and_other_outcomes(self):
        mutations = [lambda j,c: j.update(name=p.SKIPPED_REFRESH_NAME + ' '),
                     lambda j,c: j.update(name='Ready refresh PR45 run1 attempt1'),
                     lambda j,c: j.update(steps=[dict(name='unexpected execution')]),
                     lambda j,c: j.update(steps=None),
                     lambda j,c: j.update(status='in_progress'),
                     lambda j,c: j.update(conclusion='failure'), lambda j,c: j.update(conclusion='neutral'),
                     lambda j,c: j.update(conclusion='cancelled'), lambda j,c: j.update(conclusion='success'),
                     lambda j,c: c.update(conclusion='success'), lambda j,c: c.update(status='in_progress'),
                     lambda j,c: j.update(run_id=RUN), lambda j,c: j.update(run_attempt=2),
                     lambda j,c: j.update(head_sha=BASE), lambda j,c: c.update(app=dict(id=999)),
                     lambda j,c: c.update(check_suite=dict(id=999)),
                     lambda j,c: j.update(check_run_url='https://api.github.com/repos/foreign/repo/check-runs/7001')]
        for mutate in mutations:
            self.api = Transcript()
            self.transport('inspect', 'completed', 'success')
            job, check = self.transport(p.SKIPPED_REFRESH_NAME, 'completed', 'skipped')
            mutate(job, check)
            with self.subTest(mutation=mutate), self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)
            self.assertFalse(self.api.mutations)

    def test_refresh_skip_requires_successful_bound_trusted_source(self):
        mutations = [lambda j,c: j.update(steps=[]),
                     lambda j,c: j['steps'].append(copy.deepcopy(j['steps'][0])),
                     lambda j,c: j['steps'][0].update(name=p.COORDINATOR_SOURCE_STEP + HEAD),
                     lambda j,c: j['steps'][0].update(name=p.COORDINATOR_SOURCE_STEP + 'unknown'),
                     lambda j,c: j['steps'][0].update(conclusion='skipped'),
                     lambda j,c: j.update(conclusion='failure'), lambda j,c: c.update(conclusion='failure'),
                     lambda j,c: c.update(app=dict(id=999)), lambda j,c: j.update(run_attempt=2)]
        for mutate in mutations:
            self.api = Transcript()
            job, check = self.transport('inspect', 'completed', 'success')
            self.transport(p.SKIPPED_REFRESH_NAME, 'completed', 'skipped')
            mutate(job, check)
            with self.subTest(mutation=mutate), self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)
            self.assertFalse(self.api.mutations)
        self.api = Transcript()
        self.transport('inspect', 'completed', 'success')
        self.transport('inspect', 'completed', 'success')
        self.transport(p.SKIPPED_REFRESH_NAME, 'completed', 'skipped')
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)
        for field, value in [('path', p.CI_PATH), ('event', 'workflow_run'), ('workflow_id', 999)]:
            self.api = Transcript()
            self.transport('inspect', 'completed', 'success')
            self.transport(p.SKIPPED_REFRESH_NAME, 'completed', 'skipped')
            self.api.ready_run[field] = value
            with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)

    def test_transport_lookalikes_foreign_provenance_and_unknown_jobs_rejected(self):
        for field, value in [('app', dict(id=123)), ('head_sha', BASE), ('check_suite', dict(id=999)),
                             ('details_url', 'https://evil.test'), ('name', 'CI Required')]:
            self.api = Transcript()
            _, check = self.transport(f'bot-ready ({NUMBER})')
            check[field] = value
            with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)
        self.api = Transcript()
        self.transport('unexpected coordinator job')
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)
        self.api = Transcript()
        self.transport('bot-ready', 'in_progress')
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)
        self.api = Transcript()
        _, check = self.transport(f'bot-ready ({NUMBER})')
        self.api.ready_jobs.clear()  # A lookalike not in authenticated Actions jobs.
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)

    def test_wrong_coordinator_workflow_event_repo_and_head_rejected(self):
        for field, value in [('workflow_id', 99), ('path', p.CI_PATH), ('event', 'workflow_dispatch'),
                             ('repository', dict(id=101)), ('head_repository', dict(id=101)), ('head_sha', BASE)]:
            self.api = Transcript()
            self.api.ready_run[field] = value
            with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)
            self.assertFalse(self.api.mutations)

    def test_unassociated_notifications_reconcile_api_open_prs_without_approval(self):
        self.api.run['pull_requests'] = []
        self.assertEqual(p.targets(self.api, 'workflow_run', dict(workflow_run=dict(id=RUN))), ([NUMBER], None))
        self.api.run['pull_requests'] = [dict(number=NUMBER), dict(number=NUMBER + 1)]
        self.assertEqual(p.targets(self.api, 'workflow_run', dict(workflow_run=dict(id=RUN))), ([NUMBER], None))
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)

    def test_post_merge_exact_bot_main_fixed_dispatch_and_dedup(self):
        self.api.pr.update(state='closed', merged=True, merged_at='2026-09-30T00:00:00Z', merge_commit_sha=BASE)
        self.assertIn('dispatched', p.post_merge(self.api, True))
        self.assertEqual(self.api.mutations, [
            ('POST', p.route('actions/workflows/dependency-submission.yml/dispatches'), dict(ref='main')),
            ('POST', p.route('actions/workflows/dependabot-rebase.yml/dispatches'), dict(ref='main')),
            ('POST', p.route('actions/workflows/ci.yml/dispatches'), dict(ref='main', inputs=dict(dependabot_merge_pr=str(NUMBER))))])
        self.api.post_runs = [dict(head_sha=BASE, event='push', conclusion='failure')]
        self.assertIn('already exists', p.post_merge(self.api, True))
        self.assertEqual(len(self.api.mutations), 3)
        self.assertIn('standby', p.post_merge(self.api, False))

    def test_post_merge_uncertain_snapshot_dispatch_fails_closed_before_ci(self):
        self.merged_bot()
        original = self.api.mutate
        def flaky(method, route, payload):
            if 'dependency-submission.yml' in route: raise OSError('dispatch response lost')
            return original(method, route, payload)
        with mock.patch.object(self.api, 'mutate', side_effect=flaky):
            with self.assertRaisesRegex(p.Rejected, 'snapshot dispatch outcome uncertain'):
                p.post_merge(self.api, True)
            self.assertFalse(self.api.mutations)
            self.api.snapshot_runs = [dict(head_sha=BASE, event='workflow_dispatch')]
            self.assertIn('dispatched', p.post_merge(self.api, True))
        self.assertEqual([m[1] for m in self.api.mutations], [p.route('actions/workflows/dependabot-rebase.yml/dispatches'),
                                                              p.route('actions/workflows/ci.yml/dispatches')])

    def test_post_merge_lost_rebase_wake_still_dispatches_main_ci(self):
        # A merge push by GITHUB_TOKEN wakes nothing, so the queue is woken
        # directly; losing that reply must not cost the main CI dispatch.
        self.merged_bot()
        original = self.api.mutate
        def flaky(method, route, payload):
            if 'dependabot-rebase.yml' in route: raise OSError('dispatch response lost')
            return original(method, route, payload)
        with mock.patch.object(self.api, 'mutate', side_effect=flaky):
            self.assertIn('dispatched', p.post_merge(self.api, True))
        self.assertEqual([m[1] for m in self.api.mutations], [p.route('actions/workflows/dependency-submission.yml/dispatches'),
                                                              p.route('actions/workflows/ci.yml/dispatches')])

    def merged_bot(self):
        self.api.pr.update(state='closed', merged=True, merged_at='2026-10-01T00:00:00Z', merge_commit_sha=BASE)

    def test_post_merge_plan_is_read_only_and_only_selects_actual_current_bot_merge(self):
        self.assertEqual(p.post_merge_plan(self.api, True)[0], None)
        self.merged_bot()
        candidate, _ = p.post_merge_plan(self.api, True)
        self.assertEqual(candidate, dict(pr=NUMBER, main=BASE))
        self.api.pr['user'] = dict(login='human', id=1, type='User')
        self.assertIsNone(p.post_merge_plan(self.api, True)[0])
        self.assertFalse(self.api.mutations)
        self.api.reads.clear()
        self.assertIsNone(p.post_merge_plan(self.api, False)[0])
        self.assertFalse(self.api.reads)

    def test_post_merge_plan_existing_ci_never_retries_failed_runs(self):
        self.merged_bot()
        for conclusion in ['success', 'failure', 'cancelled', None]:
            self.api.post_runs = [dict(event='push', head_sha=BASE, conclusion=conclusion)]
            with mock.patch.object(p.time, 'sleep') as sleep:
                candidate, reason = p.post_merge_plan(self.api, True, True)
                self.assertIsNone(candidate)
                self.assertIn('already exists', reason)
                sleep.assert_not_called()
        self.assertFalse(self.api.mutations)

    def test_post_merge_plan_preserves_bounded_late_native_merge_recovery(self):
        self.merged_bot()
        original = self.api.pages
        calls = 0
        def delayed(route, key=None):
            nonlocal calls
            if route.endswith('/pulls'):
                calls += 1
                if calls < 3: return []
            return original(route, key)
        with mock.patch.object(self.api, 'pages', side_effect=delayed), mock.patch.object(p.time, 'sleep') as sleep:
            candidate, _ = p.post_merge_plan(self.api, True, True)
        self.assertEqual(candidate, dict(pr=NUMBER, main=BASE))
        self.assertEqual(sleep.call_args_list, [mock.call(5), mock.call(5)])
        self.assertFalse(self.api.mutations)
        self.api = Transcript()
        with mock.patch.object(p.time, 'sleep') as sleep:
            self.assertIsNone(p.post_merge_plan(self.api, True, True)[0])
            self.assertEqual(sleep.call_count, 6)
        with mock.patch.object(p.time, 'sleep') as sleep:
            self.assertIsNone(p.post_merge_plan(self.api, True, False)[0])
            sleep.assert_not_called()

    def test_post_merge_plan_ambiguity_missing_metadata_and_api_errors_fail_closed(self):
        for alter in [lambda a: a.pr['user'].update(id=123), lambda a: a.pr.pop('merged_at'),
                      lambda a: a.pr['user'].pop('type'), lambda a: a.pr.update(merged=False)]:
            self.api = Transcript()
            self.merged_bot()
            alter(self.api)
            with self.assertRaises(p.Rejected): p.post_merge_plan(self.api, True)
            self.assertFalse(self.api.mutations)
        self.api = Transcript()
        self.merged_bot()
        original = self.api.pages
        def ambiguous(route, key=None):
            result = original(route, key)
            return result * 2 if route.endswith('/pulls') else result
        with mock.patch.object(self.api, 'pages', side_effect=ambiguous):
            with self.assertRaisesRegex(p.Rejected, 'ambiguous'):
                p.post_merge_plan(self.api, True)
        with mock.patch.object(self.api, 'get', side_effect=OSError('API unavailable')):
            with self.assertRaises(OSError): p.post_merge_plan(self.api, True)
        self.assertFalse(self.api.mutations)

    def test_post_merge_writer_revalidates_plan_and_dedup_before_dispatch(self):
        self.merged_bot()
        candidate, _ = p.post_merge_plan(self.api, True)
        self.api.post_runs = [dict(event='push', head_sha=BASE)]
        self.assertIn('already exists', p.post_merge(self.api, True, candidate['main'], candidate['pr']))
        self.assertFalse(self.api.mutations)
        self.api.post_runs = []
        with self.assertRaisesRegex(p.Rejected, 'plan changed'):
            p.post_merge(self.api, True, 'd' * 40, candidate['pr'])
        self.assertFalse(self.api.mutations)
        self.api.pr.update(merged=False)
        with self.assertRaises(p.Rejected): p.post_merge(self.api, True, candidate['main'], candidate['pr'])
        self.assertFalse(self.api.mutations)

    def test_post_merge_writer_rejects_actual_main_movement_after_plan(self):
        self.merged_bot()
        candidate, _ = p.post_merge_plan(self.api, True)
        self.api.base = 'd' * 40
        self.api.pr['merge_commit_sha'] = self.api.base
        with self.assertRaisesRegex(p.Rejected, 'plan changed'):
            p.post_merge(self.api, True, candidate['main'], candidate['pr'])
        self.assertFalse(self.api.mutations)

    def test_post_merge_plan_cli_publishes_only_verified_target(self):
        for merged in [False, True]:
            self.api = Transcript()
            if merged: self.merged_bot()
            with tempfile.TemporaryDirectory() as folder:
                output = Path(folder) / 'outputs'
                with mock.patch.dict(os.environ, GITHUB_OUTPUT=str(output), DEPENDABOT_AUTO_MERGE_ENABLED='true'), \
                        mock.patch.object(p.sys, 'argv', ['policy', 'post-merge-plan']), \
                        mock.patch.object(p, 'GitHub', return_value=self.api):
                    self.assertEqual(p.main(), 0)
                self.assertEqual(output.read_text(), f'needed=true\npr={NUMBER}\nmain_sha={BASE}\n' if merged else 'needed=false\n')
            self.assertFalse(self.api.mutations)

    def test_post_merge_plan_cli_does_not_publish_false_success_on_error(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'outputs'
            with mock.patch.dict(os.environ, GITHUB_OUTPUT=str(output), DEPENDABOT_AUTO_MERGE_ENABLED='true'), \
                    mock.patch.object(p.sys, 'argv', ['policy', 'post-merge-plan']), \
                    mock.patch.object(p, 'GitHub', return_value=self.api), \
                    mock.patch.object(p, 'post_merge_plan', side_effect=OSError('API unavailable')):
                self.assertEqual(p.main(), 1)
            self.assertFalse(output.exists())
        with mock.patch.dict(os.environ, GITHUB_REF='refs/heads/untrusted'), \
                mock.patch.object(p.sys, 'argv', ['policy', 'post-merge-plan']), \
                mock.patch.object(p, 'GitHub') as api:
            self.assertEqual(p.main(), 1)
            api.assert_not_called()

    def test_post_merge_job_conditions_skip_humans_and_require_successful_positive_plan(self):
        source = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        def condition(job, overrides):
            expression = re.search(r'(?m)^  ' + job + r':\n    if: (.*)', source)[1]
            expression = expression.removeprefix('${{ ').removesuffix(' }}')
            values = {'always()':'True', 'github.repository':repr(p.REPOSITORY), 'github.ref':repr('refs/heads/main'),
                      'github.workflow_ref':repr(p.REPOSITORY + '/.github/workflows/dependabot-auto-merge.yml@refs/heads/main'),
                      'needs.inspect.result':repr('success'), 'needs.inspect.outputs.bot_prs':repr('[]'),
                      'github.event_name':repr('pull_request_target'), 'vars.DEPENDABOT_AUTO_MERGE_ENABLED':repr('true'),
                      'needs.post-merge-plan.result':repr('success'), 'needs.post-merge-plan.outputs.needed':repr('true')}
            values.update({k:repr(v) for k,v in overrides.items()})
            for name, value in values.items(): expression = expression.replace(name, value)
            return eval(expression.replace('&&','and').replace('||','or'), {'__builtins__':{}})
        for event in ['pull_request_target', 'workflow_run']:
            self.assertFalse(condition('post-merge-plan', {'github.event_name':event}))
            self.assertTrue(condition('post-merge-plan', {'github.event_name':event, 'needs.inspect.outputs.bot_prs':'[45]'}))
        for event in ['schedule','push','workflow_dispatch']:
            self.assertTrue(condition('post-merge-plan', {'github.event_name':event}))
        for result, needed in [('skipped',''),('failure','true'),('cancelled','true'),('success','false'),('success','')]:
            self.assertFalse(condition('post-merge', {'needs.post-merge-plan.result':result, 'needs.post-merge-plan.outputs.needed':needed}))
        self.assertTrue(condition('post-merge', {}))
        self.assertIn('post-merge --pr "$PLANNED_PR" --expected-sha "$PLANNED_MAIN"', source)
        planner = source.split('  post-merge-plan:\n')[1].split('  post-merge:\n')[0]
        self.assertNotIn(': write', planner)

    def test_post_merge_rejects_forged_or_stale_origin(self):
        for change in [lambda a: a.pr.update(merged=False), lambda a: a.pr['user'].update(id=123),
                       lambda a: a.pr['head'].update(repo=dict(id=101)), lambda a: a.pr.update(state='open')]:
            api = Transcript()
            api.pr.update(state='closed', merged=True, merge_commit_sha=BASE)
            change(api)
            with self.assertRaises(p.Rejected): p.verify_post_merge(api, NUMBER, BASE)
        with self.assertRaises(p.Rejected): p.verify_post_merge(self.api, NUMBER, HEAD)

    def test_supported_event_targets_and_foreign_notifications(self):
        for event in ['schedule', 'workflow_dispatch', 'push']:
            self.assertEqual(p.targets(self.api, event, {}), ([NUMBER], None))
        self.assertEqual(p.targets(self.api, 'workflow_run', dict(workflow_run=dict(id=RUN, run_attempt=1)))[0], [NUMBER])
        self.api.run['path'] = '.github/workflows/release.yml'
        with self.assertRaises(p.Rejected): p.targets(self.api, 'workflow_run', dict(workflow_run=dict(id=RUN)))

    def test_workflow_security_and_publication_wiring(self):
        coordinator = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        notice = (ROOT / '.github/workflows/dependabot-review-notice.yml').read_text()
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        docs = (ROOT / '.github/workflows/docs-publish.yml').read_text()
        self.assertEqual(coordinator.count('ref: refs/heads/main'), 0)
        self.assertEqual(coordinator.count('ref: ${{ github.workflow_sha }}'), 6)
        inspect = coordinator.split('  inspect:\n', 1)[1].split('  ready-plan:\n', 1)[0]
        self.assertIn('ref: ${{ github.workflow_sha }}', inspect)
        self.assertIn('name: ' + p.COORDINATOR_SOURCE_STEP + '${{ github.workflow_sha }}', inspect)
        self.assertEqual(coordinator.count('queue: max'), 3)
        self.assertEqual(coordinator.count('persist-credentials: false'), 6)
        for unsafe in ['pull_request.head', 'secrets.', 'download-artifact', 'cache@', 'gh pr merge', 'pip install']:
            self.assertNotIn(unsafe, coordinator)
        self.assertIn('permissions: {}', notice)
        self.assertNotIn('checkout', '\n'.join(line for line in notice.splitlines() if not line.startswith('#')))
        self.assertNotIn('pull_request_review_thread:', notice)
        self.assertIn('types: [requested, in_progress, completed]', coordinator)
        self.assertIn('verify-post-merge --pr "$MERGED_PR" --expected-sha "$GITHUB_SHA"', ci)
        self.assertIn('Scripts/publish-docs.py', docs)
        self.assertIn("github.event.workflow_run.head_branch == 'main'", docs)
        self.assertIn("publish: false", ci)
        self.assertEqual(set(workflow_inventory()), set(p.CORE))

    def test_actual_mutating_job_conditions_reject_branch_dispatch_and_inspect_failure(self):
        source = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        for job in ['ready-refresh', 'bot-ready', 'post-merge']:
            expression = re.search(r'(?m)^  ' + job + r':\n    (?:needs:.*\n    )?if: (.*)', source)[1]
            expression = expression.removeprefix('${{ ').removesuffix(' }}')
            for ref, workflow_ref, inspect_result, allowed in [
                    ('refs/heads/main', 'refs/heads/main', 'success', True),
                    ('refs/heads/unmerged', 'refs/heads/unmerged', 'success', False),
                    ('refs/heads/main', 'refs/heads/stale', 'success', False),
                    ('refs/heads/main', 'refs/heads/main', 'failure', False),
                    ('refs/heads/main', 'refs/heads/main', 'skipped', False)]:
                values = {'always()':'True', 'github.repository':repr(p.REPOSITORY), 'github.ref':repr(ref),
                          'github.workflow_ref':repr(p.REPOSITORY + '/.github/workflows/dependabot-auto-merge.yml@' + workflow_ref),
                          'needs.inspect.result':repr(inspect_result), 'needs.ready-plan.result':repr('success'),
                          'needs.bot-ready.result':repr('success'), 'needs.ready-plan.outputs.targets':repr('[{"pr":45}]'),
                          'github.event_name':repr('workflow_run'), 'needs.post-merge-plan.result':repr('success'),
                          'needs.post-merge-plan.outputs.needed':repr('true'), 'needs.inspect.outputs.manual_prs':repr('[45]'),
                          'needs.inspect.outputs.bot_prs':repr('[45]'), 'vars.DEPENDABOT_AUTO_MERGE_ENABLED':repr('true')}
                evaluated = expression
                for name, value in values.items(): evaluated = evaluated.replace(name, value)
                evaluated = evaluated.replace('&&', 'and').replace('||', 'or')
                with self.subTest(job=job, ref=ref, inspect=inspect_result):
                    self.assertEqual(eval(evaluated, {'__builtins__':{}}), allowed)

    def test_runtime_mutation_context_requires_exact_default_workflow(self):
        environment = dict(GITHUB_REPOSITORY=p.REPOSITORY, GITHUB_REF='refs/heads/main',
                           GITHUB_WORKFLOW_REF=p.REPOSITORY + '/.github/workflows/dependabot-auto-merge.yml@refs/heads/main')
        p.trusted_context(environment)
        for key, value in [('GITHUB_REF','refs/heads/unmerged'), ('GITHUB_WORKFLOW_REF','branch workflow'),
                           ('GITHUB_REPOSITORY','other/repo'), ('GITHUB_REF',None)]:
            with self.assertRaises(p.Rejected): p.trusted_context(dict(environment, **{key:value}))

    def test_pagination_reads_page_two_and_rejects_truncation(self):
        api = p.GitHub('test-token')
        with mock.patch.object(api, 'request', side_effect=[
                (dict(total_count=2, check_runs=[dict(id=1)]), {'Link':'<next>; rel="next"'}),
                (dict(total_count=2, check_runs=[dict(id=2, conclusion='failure')]), {})]) as request:
            self.assertEqual(api.pages(p.route(f'commits/{HEAD}/check-runs'), 'check_runs')[1]['conclusion'], 'failure')
            self.assertIn('page=2', request.call_args[0][1])
        with mock.patch.object(api, 'request', return_value=(dict(total_count=2, jobs=[{}]), {})):
            with self.assertRaises(p.Rejected): api.pages(p.route('actions/runs/1/jobs'), 'jobs')
        with self.assertRaises(p.Rejected): api.request('GET', 'repos/foreign/project/pulls/1')

    def test_graphql_thread_page_two_blocker_and_invalid_cursor(self):
        first = self.api.graphql('', {})
        second = copy.deepcopy(first)
        first['repository']['pullRequest']['reviewThreads']['pageInfo'] = dict(hasNextPage=True, endCursor='page2')
        second['repository']['pullRequest']['reviewThreads']['nodes'] = [dict(isResolved=False)]
        with mock.patch.object(self.api, 'graphql', side_effect=[first, second]):
            with self.assertRaises(p.Rejected): p.reviews(self.api, NUMBER)



    def test_native_pull_request_rule_is_required_and_verified(self):
        changes = [lambda a: a.rules.pop(),
                   lambda a: a.rules[1]['parameters'].pop('required_review_thread_resolution'),
                   lambda a: a.rules[1]['parameters'].update(required_review_thread_resolution=False),
                   lambda a: a.rules[1]['parameters'].update(required_review_thread_resolution='true'),
                   lambda a: a.rules[1].update(ruleset_source_type='Organization'),
                   lambda a: a.rules[1].update(ruleset_source='other/repository'),
                   lambda a: a.review_ruleset.update(enforcement='evaluate'),
                   lambda a: a.review_ruleset.update(current_user_can_bypass='always'),
                   lambda a: a.review_ruleset.update(bypass_actors=[dict(actor_id=p.APP, actor_type='Integration')])]
        for change in changes:
            with self.subTest(change=change): self.reject(change)

    def test_native_pr_rule_preserves_zero_approval_and_redaction_contract(self):
        self.assertEqual(self.api.rules[1]['parameters']['required_approving_review_count'], 0)
        p.proof(self.api, NUMBER)
        self.assertIn(p.route('rulesets/124'), self.api.reads)
        # Native rules are additive: one applicable thread-resolution requirement is enough.
        self.api.rules.append(dict(self.api.rules[1], parameters=dict(required_review_thread_resolution=False, required_approving_review_count=0)))
        self.api.review_ruleset.pop('bypass_actors')
        # Redacted actors remain acceptable only with explicit runtime no-bypass.
        self.api.review_ruleset['current_user_can_bypass'] = 'never'
        p.proof(self.api, NUMBER)  # Owner audit remains required; no admin credential is introduced.
        self.assertFalse(self.api.mutations)

    def test_missing_native_pr_rule_cannot_arm_auto_merge(self):
        self.api.rules.pop()
        result = p.coordinate(self.api, NUMBER, True)
        self.assertIn('native pull-request rule absent', result)
        self.assertFalse(any('enablePullRequestAutoMerge' in str(m) for m in self.api.mutations))
        self.assertFalse(any('/check-runs' in str(m) for m in self.api.mutations))

    def test_every_expanded_matrix_job_and_required_step_is_mandatory(self):
        for name, required in p.CORE.items():
            self.reject(lambda a, n=name: a.jobs.__setitem__(slice(None), [j for j in a.jobs if j['name'] != n]))
            for step in required:
                def remove(a, n=name, s=step):
                    job = next(j for j in a.jobs if j['name'] == n)
                    job['steps'] = [x for x in job['steps'] if x['name'] != s]
                with self.subTest(job=name, step=step): self.reject(remove)

    def test_reconciliation_finds_retargeted_bots_but_not_nonmain_humans(self):
        self.api.pr['base']['ref'] = 'develop'
        self.api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
        for event in ['schedule', 'workflow_dispatch', 'push']:
            self.assertEqual(p.targets(self.api, event, {}), ([NUMBER], None))
        self.assertIn('wrong base', p.coordinate(self.api, NUMBER, True))
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertFalse(any('/check-runs' in str(m) for m in self.api.mutations))
        self.api.pr['user'] = dict(login='human', id=1, type='User')
        self.assertEqual(p.targets(self.api, 'schedule', {}), ([], None))
        self.api.pr['base']['ref'] = 'main'
        self.assertEqual(p.targets(self.api, 'schedule', {}), ([NUMBER], None))

    def test_recovery_concurrency_cannot_cancel_native_main_validation(self):
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn("${{ inputs.dependabot_merge_pr != '' && format('dependabot-{0}', inputs.dependabot_merge_pr) || 'validation' }}", ci)
        for path in ['release-validation.yml']:
            source = (ROOT / '.github/workflows' / path).read_text()
            group = next(line for line in source.splitlines() if line.strip().startswith('group:'))
            self.assertIn('${{ github.run_id }}', group)

    def test_target_output_keeps_retargeted_bot_cancellation_out_of_reporter_plan(self):
        for state, base, expected_ready in [('open', 'main', [NUMBER]), ('open', 'develop', []), ('closed', 'main', [])]:
            self.api.pr.update(state=state)
            self.api.pr['base']['ref'] = base
            with tempfile.TemporaryDirectory() as directory:
                event, output = Path(directory) / 'event.json', Path(directory) / 'output'
                event.write_text('{}')
                with mock.patch.dict(os.environ, GITHUB_EVENT_NAME='schedule', GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output)), \
                        mock.patch.object(p, 'GitHub', return_value=self.api), \
                        mock.patch.object(p.sys, 'argv', ['dependabot-merge-policy.py', 'targets']):
                    self.assertEqual(p.main(), 0)
                values = dict(line.split('=', 1) for line in output.read_text().splitlines())
                self.assertEqual(json.loads(values['bot_prs']), [NUMBER])
                self.assertEqual(json.loads(values['prs']), expected_ready)



def workflow_jobs(text):
    body = text.split('\njobs:\n', 1)[1]
    jobs = {}
    for block in re.split(r'(?m)^  (?=[A-Za-z0-9_-]+:\n)', body):
        match = re.match(r'([A-Za-z0-9_-]+):\n', block)
        if match:
            name = re.search(r'(?m)^    name: (.+)$', block)
            uses = re.search(r'(?m)^    uses: \./\.github/workflows/(.+\.yml)$', block)
            jobs[match[1]] = dict(name=name[1].strip() if name else match[1], uses=uses[1] if uses else None,
                                  steps=re.findall(r'(?m)^      - name: (.+)$', block), block=block)
    return jobs


def workflow_documents(*paths):
    return json.loads(subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
        'puts ARGV.to_h { |p| [File.basename(p), YAML.safe_load(File.read(p), aliases: false)] }.to_json',
        *[str(ROOT / '.github/workflows' / name) for name in paths]], text=True))


def workflow_inventory(owners=None):
    """Independent expanded GitHub job/step names from native YAML."""
    docs = workflow_documents('ci.yml', 'release-validation.yml')
    inventory = {}
    def expand(document, prefix='', owner=None):
        for key, job in document['jobs'].items():
            name = job.get('name', key)
            if key == 'ci-required': name = 'CI Required'
            if key == 'consumer-smoke': name = 'Consumer Smoke'
            if 'uses' in job:
                expand(docs[job['uses'].rsplit('/', 1)[1]], prefix + name + ' / ', owner or key)
                continue
            matrix = job.get('strategy', {}).get('matrix', {})
            if 'include' in matrix: rows = matrix['include']
            elif matrix:
                if len(matrix) != 1: raise AssertionError('new matrix needs explicit inventory')
                dimension, values = next(iter(matrix.items()))
                rows = [{dimension: value} for value in values]
            else: rows = [{}]
            for row in rows:
                def render(text):
                    for key, value in row.items():
                        if isinstance(value, dict):
                            for field, v in value.items(): text = text.replace('${{ matrix.' + key + '.' + field + ' }}', str(v))
                        else: text = text.replace('${{ matrix.' + key + ' }}', str(value))
                    if '${{ matrix.' in text: raise AssertionError('unexpanded matrix: ' + text)
                    return text
                label = prefix + render(name)
                if row and '${{ matrix.' not in name: label += ' (' + ', '.join(str(v) for v in row.values()) + ')'
                if label in inventory: raise AssertionError('duplicate job name: ' + label)
                steps = [child for step in job['steps'] for child in (step['parallel'] if 'parallel' in step else [step])]
                inventory[label] = [render(step['name']) for step in steps if 'name' in step]
                if owners is not None: owners[label] = owner or key
    expand(docs['ci.yml'])
    return inventory


class WorkflowInventoryTests(unittest.TestCase):
    def test_core_skips_and_inventory_match_the_ci_workflow(self):
        # A new CI job or renamed step must update the policy and this inventory together.
        workflow = workflow_inventory()
        self.assertEqual(set(p.CORE) | p.FULL_SKIPPED, set(workflow))
        self.assertEqual(set(INVENTORY), set(workflow))
        for name, steps in p.CORE.items():
            self.assertLessEqual(set(steps), set(workflow[name]), name)
        for name, steps in INVENTORY.items():
            if name not in p.FULL_SKIPPED:
                self.assertEqual([s['name'] for s in steps], workflow[name], name)
        skipped = {(name, s['name']) for name, steps in INVENTORY.items() for s in steps if s['conclusion'] == 'skipped'}
        self.assertLessEqual(skipped, p.ALLOWED_STEP_SKIP)
        for name, step in p.ALLOWED_STEP_SKIP:
            self.assertIn(step, workflow[name], (name, step))

    def test_android_web_lane_inventory_matches_the_ci_workflow_and_planner(self):
        ci = p.sibling('ci_policy', 'ci-policy.py')
        metadata = p.sibling('ci_metadata_policy', 'ci-metadata-policy.py')
        owners = {}
        workflow_inventory(owners)
        selected = {job for job, run in ci.make_plan('pull_request', dict(action='opened', pull_request=dict(
            user=dict(login='dependabot[bot]'), labels=[])), [f['filename'] for f in NPM_FILES])['jobs'].items() if run}
        self.assertEqual(selected, set(ci.PLATFORM_JOBS) | {'policy'})
        ran = selected | {'ci-plan', 'ci-required'}
        self.assertEqual(set(p.PLATFORM_CORE), {label for label, key in owners.items() if key in ran})
        # Every other job reports one skipped name: its unexpanded YAML name.
        jobs = workflow_documents('ci.yml')['ci.yml']['jobs']
        self.assertEqual(p.PLATFORM_SKIPPED, {job.get('name', key) for key, job in jobs.items()
                                              if key not in ran | {'consumer-smoke', 'release-candidate'}})
        self.assertEqual({key for key, job in jobs.items() if 'uses' in job}, {'release-candidate'})
        # These are the spellings GitHub recorded for skipped jobs in metadata-only runs.
        self.assertLessEqual(p.PLATFORM_SKIPPED, metadata.DIRECT)
        expected = [set(p.PLATFORM_CORE) | p.PLATFORM_SKIPPED | call | smoke
                    for call in metadata.CALLS[0] for smoke in ({'Consumer Smoke'}, metadata.AGGREGATES[0][1])]
        self.assertCountEqual(map(frozenset, p.platform_inventories()), map(frozenset, expected))

    def test_cross_platform_inventory_matches_the_workflow(self):
        jobs = workflow_documents('cross-platform.yml')['cross-platform.yml']['jobs']
        expected = {}
        for job in jobs.values():
            (dimension, values), = job['strategy']['matrix'].items()
            for value in values:
                expected[job['name'].replace('${{ matrix.' + dimension + ' }}', value)] = [s['name'] for s in job['steps']]
        self.assertEqual(p.CROSS_PLATFORM, expected)
        web = jobs['web']['steps']
        self.assertEqual({s['name'] for s in web if 'if' in s}, p.NODE_24_STEPS)
        self.assertTrue(all(s['if'] == "matrix.node == '24'" for s in web if 'if' in s))
        self.assertEqual([s['name'] for s in web if s.get('continue-on-error')], [p.ADVISORY_STEP])
        self.assertFalse([s for s in jobs['android']['steps'] if 'if' in s or 'continue-on-error' in s])
        self.assertIn(p.NODE_24, p.CROSS_PLATFORM)




if __name__ == '__main__': unittest.main()
