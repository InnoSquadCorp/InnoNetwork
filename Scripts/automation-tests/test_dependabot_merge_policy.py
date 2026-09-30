"""Adversarial metadata transcripts for the privileged coordinator; no network."""
import copy
import importlib.util
import json
import re
import subprocess
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('dependabot_policy', ROOT / 'Scripts/dependabot-merge-policy.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
HEAD, BASE, MERGE = 'a' * 40, 'b' * 40, 'c' * 40
NUMBER, RUN = 45, 900
INVENTORY = json.loads((Path(__file__).parent / 'fixtures/dependabot-full-ci.json').read_text())['jobs']


class Transcript:
    def __init__(self):
        self.repo = dict(id=100, full_name=p.REPOSITORY, default_branch='main', allow_auto_merge=True, allow_squash_merge=True)
        self.pr = dict(number=NUMBER, node_id='PR_node', user=dict(p.BOT), state='open', merged=False, draft=False,
                       mergeable=True, merge_commit_sha=MERGE, auto_merge=None, requested_reviewers=[], requested_teams=[],
                       base=dict(ref='main', sha=BASE, repo=self.repo), head=dict(sha=HEAD, repo=self.repo))
        self.base = BASE
        self.rules = [dict(type='required_status_checks', ruleset_source_type='Repository', ruleset_source=p.REPOSITORY,
                           ruleset_id=123, parameters=dict(strict_required_status_checks_policy=True,
                           required_status_checks=[dict(context=n, integration_id=p.APP) for n in ['CI Required', p.READY]]))]
        self.ruleset = dict(enforcement='active', bypass_actors=[], current_user_can_bypass='never')
        self.workflow = dict(id=10, path=p.CI_PATH, state='active')
        self.run = dict(id=RUN, run_number=30, run_attempt=1, workflow_id=10, path=p.CI_PATH, check_suite_id=400,
                        event='pull_request', head_sha=HEAD, head_repository=self.repo, repository=self.repo,
                        status='completed', conclusion='success', pull_requests=[dict(number=NUMBER, head=dict(sha=HEAD), base=dict(sha=BASE))])
        self.runs = [self.run]
        self.jobs, self.checks = [], []
        for index, (name, steps) in enumerate(INVENTORY.items()):
            check_id, job_id = 1000 + index, 2000 + index
            result = 'success'
            self.jobs.append(dict(id=job_id, name=name, status='completed', conclusion=result,
                                 check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/{check_id}',
                                 steps=[dict(s, status='completed') for s in steps]))
            self.checks.append(dict(id=check_id, name=name, status='completed', conclusion=result,
                                   app=dict(id=p.APP), head_sha=HEAD, check_suite=dict(id=400),
                                   details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{RUN}/job/{job_id}'))
        self.merge_checks, self.statuses, self.review_list, self.threads = [], [], [], []
        self.graph_head, self.review_decision = HEAD, None
        self.mutations, self.reads = [], []
        self.old_jobs, self.post_runs = [], []
        self.graph_fail = False

    def get(self, route):
        self.reads.append(route)
        suffix = route.removeprefix(f'repos/{p.REPOSITORY}').lstrip('/')
        if not suffix: value = self.repo
        elif suffix == f'pulls/{NUMBER}': value = self.pr
        elif suffix == 'git/ref/heads/main': value = dict(object=dict(sha=self.base))
        elif suffix == f'git/commits/{MERGE}': value = dict(parents=[dict(sha=BASE), dict(sha=HEAD)])
        elif suffix == 'rulesets/123': value = self.ruleset
        elif suffix == 'actions/workflows/ci.yml': value = self.workflow
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
        elif suffix.startswith('actions/workflows/ci.yml/runs?branch='): value = self.post_runs
        elif suffix == f'actions/runs/{RUN}/attempts/{self.run["run_attempt"]}/jobs': value = self.jobs
        elif suffix.startswith(f'actions/runs/{RUN}/attempts/'): value = self.old_jobs
        elif suffix == f'commits/{HEAD}/check-runs?filter=all': value = self.checks
        elif suffix == f'commits/{MERGE}/check-runs?filter=all': value = self.merge_checks
        elif suffix.endswith('/statuses'): value = self.statuses
        elif suffix == f'commits/{self.base}/pulls': value = [self.pr]
        elif suffix == 'pulls?state=open': value = [self.pr]
        else: raise AssertionError('Unexpected pages: ' + route)
        return copy.deepcopy(value)

    def graphql(self, query, variables):
        if query.startswith('mutation'):
            self.mutations.append(('graphql', query, copy.deepcopy(variables)))
            if self.graph_fail: raise PermissionError('403 denied')
            if 'disablePullRequestAutoMerge' in query: self.pr['auto_merge'] = None
            else: self.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
            return {}
        return dict(repository=dict(pullRequest=dict(id='PR_node', headRefOid=self.graph_head,
                    reviewDecision=self.review_decision, reviewThreads=dict(nodes=copy.deepcopy(self.threads),
                    pageInfo=dict(hasNextPage=False, endCursor=None)))))

    def mutate(self, method, route, payload):
        self.mutations.append((method, route, copy.deepcopy(payload)))
        if route.endswith('/check-runs'):
            check = dict(payload, id=8000, app=dict(id=p.APP), check_suite=dict(id=800))
            self.checks.append(check)
            return copy.deepcopy(check)
        if '/check-runs/' in route:
            check = next(c for c in self.checks if c['id'] == int(route.rsplit('/', 1)[1]))
            check.update(payload)
            return copy.deepcopy(check)
        if route.endswith('/dispatches'): return None
        raise AssertionError('Unexpected mutation: ' + route)


class DependabotPolicyTests(unittest.TestCase):
    def setUp(self): self.api = Transcript()

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
                   lambda a: a.rules[0]['parameters'].update(strict_required_status_checks_policy=False),
                   lambda a: a.rules[0]['parameters']['required_status_checks'].pop(),
                   lambda a: a.rules[0]['parameters']['required_status_checks'][0].update(integration_id=None)]
        for change in changes:
            with self.subTest(change=change): self.reject(change)

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

    def test_every_expanded_matrix_job_and_required_step_is_mandatory(self):
        for name, required in p.CORE.items():
            self.reject(lambda a, n=name: a.jobs.__setitem__(slice(None), [j for j in a.jobs if j['name'] != n]))
            for step in required:
                def remove(a, n=name, s=step):
                    job = next(j for j in a.jobs if j['name'] == n)
                    job['steps'] = [x for x in job['steps'] if x['name'] != s]
                with self.subTest(job=name, step=step): self.reject(remove)

    def test_only_predefined_non_target_skips(self):
        p.proof(self.api, NUMBER)  # Pages, main-tip-only and origin guard are PR non-targets.
        for name in ['CI Required', 'Tests under ThreadSanitizer', 'Build DocC Site']:
            self.reject(lambda a: next(j for j in a.jobs if j['name'] == name).update(conclusion='skipped'))

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
        self.reject(lambda a: a.pr.update(requested_reviewers=[dict(id=3)]))
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
        p.gate(self.api, NUMBER, HEAD, 'in_progress')
        p.proof(self.api, NUMBER)
        self.api.checks[-1]['app']['id'] = 123
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)

    def test_human_with_bot_labels_gets_manual_success_without_enable(self):
        self.api.pr.update(user=dict(id=1, login='human', type='User'), labels=[dict(name='dependencies')], draft=True)
        self.assertIn('manual PR', p.coordinate(self.api, NUMBER, True))
        self.assertFalse(any(m[0] == 'graphql' for m in self.api.mutations))
        self.assertEqual(self.api.checks[-1]['conclusion'], 'success')

    def test_standby_never_enables_auto_merge(self):
        self.assertIn('standby', p.coordinate(self.api, NUMBER, False))
        self.assertFalse(any(m[0] == 'graphql' for m in self.api.mutations))
        self.assertEqual(self.api.checks[-1]['conclusion'], 'failure')

    def test_success_enables_native_expected_head_and_reuses_gate(self):
        self.assertIn('armed', p.coordinate(self.api, NUMBER, True))
        native = [m for m in self.api.mutations if m[0] == 'graphql']
        self.assertEqual(len(native), 1)
        self.assertEqual(native[0][2]['head'], HEAD)
        self.assertIn('expectedHeadOid', native[0][1])
        self.assertIn('mergeMethod:SQUASH', native[0][1])
        self.assertEqual(len([c for c in self.api.checks if c['name'] == p.READY]), 1)
        p.coordinate(self.api, NUMBER, True)
        self.assertEqual(len([m for m in self.api.mutations if m[0] == 'graphql']), 1)

    def test_head_base_or_attempt_race_prevents_enable(self):
        for field in ['head', 'base', 'attempt']:
            proof = p.proof(self.api, NUMBER)
            changed = dict(proof, **{field: 'd' * 40 if field != 'attempt' else 2})
            with mock.patch.object(p, 'proof', side_effect=[proof, changed]):
                self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
            self.assertFalse(any(m[0] == 'graphql' for m in self.api.mutations))

    def test_failure_after_enable_cancels_native_request(self):
        proof = p.proof(self.api, NUMBER)
        with mock.patch.object(p, 'proof', side_effect=[proof, proof, p.Rejected('review raced')]):
            self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertIn('disablePullRequestAutoMerge', self.api.mutations[-1][1])
        self.assertEqual(self.api.checks[-1]['conclusion'], 'failure')

    def test_base_edit_cancels_only_verified_bot_auto_request(self):
        self.api.pr['base']['ref'] = 'develop'
        self.api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
        self.assertIn('wrong base', p.coordinate(self.api, NUMBER, True))
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertEqual(self.api.checks[-1]['conclusion'], 'failure')

    def test_permission_denial_does_not_retry_enable_or_direct_merge(self):
        self.api.graph_fail = True
        self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertEqual(len([m for m in self.api.mutations if m[0] == 'graphql']), 1)
        self.assertFalse(any(str(m[1]).endswith('/merge') for m in self.api.mutations))
        self.assertEqual(self.api.checks[-1]['conclusion'], 'failure')

    def test_obsolete_notification_cannot_overwrite_gate(self):
        self.assertIn('obsolete', p.coordinate(self.api, NUMBER, True, dict(id=RUN, run_attempt=0)))
        self.assertFalse(self.api.mutations)

    def test_redacted_bypass_list_is_not_treated_as_empty_or_admin_requirement(self):
        del self.api.ruleset['bypass_actors']
        p.proof(self.api, NUMBER)
        self.api.ruleset['current_user_can_bypass'] = 'pull_requests_only'
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)

    def test_gate_failure_still_cancels_existing_native_request(self):
        p.gate(self.api, NUMBER, HEAD, 'completed')
        self.api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
        with mock.patch.object(self.api, 'mutate', side_effect=PermissionError('checks write denied')):
            result = p.coordinate(self.api, NUMBER, False)
        self.assertIn('blocked', result)
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertIn('disablePullRequestAutoMerge', self.api.mutations[-1][1])

    def test_both_gate_and_cancel_failure_surface_uncertainty(self):
        p.gate(self.api, NUMBER, HEAD, 'completed')
        self.api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
        self.api.graph_fail = True
        with mock.patch.object(self.api, 'mutate', side_effect=PermissionError('checks write denied')):
            with self.assertRaisesRegex(p.Rejected, 'cancellation unconfirmed'):
                p.coordinate(self.api, NUMBER, False)

    def test_uncertain_gate_write_is_read_back_without_retry(self):
        check_id = p.gate(self.api, NUMBER, HEAD, 'in_progress')
        original = self.api.mutate
        def applied_then_timeout(method, route, payload):
            original(method, route, payload)
            raise TimeoutError('reply lost')
        with mock.patch.object(self.api, 'mutate', side_effect=applied_then_timeout) as mutation:
            self.assertEqual(p.gate(self.api, NUMBER, HEAD, 'completed', check_id), check_id)
            self.assertEqual(mutation.call_count, 1)

    def test_unknown_initial_create_is_not_repeated_in_failure_handler(self):
        self.api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
        with mock.patch.object(self.api, 'mutate', side_effect=TimeoutError('reply lost')) as mutation:
            self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
            self.assertEqual(mutation.call_count, 1)
        self.assertIsNone(self.api.pr['auto_merge'])

    def test_post_merge_exact_bot_main_fixed_dispatch_and_dedup(self):
        self.api.pr.update(state='closed', merged=True, merged_at='2026-09-30T00:00:00Z', merge_commit_sha=BASE)
        self.assertIn('dispatched', p.post_merge(self.api, True))
        dispatch = self.api.mutations[-1]
        self.assertEqual(dispatch[1], p.route('actions/workflows/ci.yml/dispatches'))
        self.assertEqual(dispatch[2], dict(ref='main', inputs=dict(dependabot_merge_pr=str(NUMBER))))
        self.api.post_runs = [dict(head_sha=BASE, event='push', conclusion='failure')]
        self.assertIn('already exists', p.post_merge(self.api, True))
        self.assertEqual(len(self.api.mutations), 1)
        self.assertIn('standby', p.post_merge(self.api, False))

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

    def test_scheduled_reconciliation_discovers_and_revokes_retargeted_bot(self):
        self.api.pr['base']['ref'] = 'develop'
        self.api.pr['auto_merge'] = {'enabled_by': {'login': 'github-actions[bot]'}}
        numbers, _ = p.targets(self.api, 'schedule', {})
        self.assertEqual(numbers, [NUMBER])
        self.assertEqual(p.coordinate(self.api, NUMBER, True), 'wrong base: auto-merge ineligible')
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertEqual(self.api.checks[-1]['conclusion'], 'failure')
        self.assertFalse(any('enablePullRequestAutoMerge' in str(m) for m in self.api.mutations))

    def test_retargeted_human_pr_does_not_enter_periodic_targets(self):
        self.api.pr['base']['ref'] = 'develop'
        self.api.pr['user'] = {'login': 'human', 'id': 123, 'type': 'User'}
        self.assertEqual(p.targets(self.api, 'schedule', {}), ([], None))
        self.assertFalse(self.api.mutations)

    def test_workflow_security_and_publication_wiring(self):
        coordinator = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        notice = (ROOT / '.github/workflows/dependabot-review-notice.yml').read_text()
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertEqual(coordinator.count('ref: refs/heads/main'), 4)
        self.assertEqual(coordinator.count('persist-credentials: false'), 4)
        for unsafe in ['pull_request.head', 'secrets.', 'download-artifact', 'cache@', 'gh pr merge', 'pip install']:
            self.assertNotIn(unsafe, coordinator)
        self.assertIn('permissions: {}', notice)
        self.assertNotIn('checkout', '\n'.join(line for line in notice.splitlines() if not line.startswith('#')))
        self.assertIn('types: [requested, in_progress, completed]', coordinator)
        self.assertIn('verify-post-merge --pr "$MERGED_PR" --expected-sha "$GITHUB_SHA"', ci)
        self.assertIn('publish: false', ci)
        self.assertEqual(set(p.CORE), set(INVENTORY))

    def test_recovery_concurrency_cannot_cancel_native_main_validation(self):
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn("${{ inputs.dependabot_merge_pr != '' && format('dependabot-{0}', inputs.dependabot_merge_pr) || 'validation' }}", ci)
        self.assertNotIn('concurrency:', (ROOT / '.github/workflows/release-validation.yml').read_text())

    def test_actual_mutating_job_conditions_reject_branch_dispatch_and_inspect_failure(self):
        source = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        for job in ['manual-ready', 'bot-ready', 'post-merge']:
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
                          'needs.inspect.result':repr(inspect_result), 'needs.inspect.outputs.manual_prs':repr('[45]'),
                          'needs.inspect.outputs.bot_prs':repr('[45]'), 'vars.DEPENDABOT_AUTO_MERGE_ENABLED':repr('true')}
                evaluated = expression
                for name, value in values.items(): evaluated = evaluated.replace(name, value)
                evaluated = evaluated.replace('&&', 'and')
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


if __name__ == '__main__': unittest.main()
