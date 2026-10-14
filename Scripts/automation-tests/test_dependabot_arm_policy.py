"""Offline native arm/receipt handshake and adversarial provenance transcripts."""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from test_dependabot_merge_policy import Transcript, p, HEAD, BASE, NUMBER, NATIVE_RUN, READY_RUN, TRUSTED

ROOT = Path(__file__).resolve().parents[2]


def load_policy(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'Scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


n = load_policy('dependabot-ready-policy')
a = load_policy('dependabot-arm-policy')
ISSUER, WRITER = 970, 980


class ArmTranscript(Transcript):
    """Keep background Actions checks separate from PR-head checks, as on GitHub."""
    def __init__(self):
        super().__init__()
        self.rules[0]['parameters']['strict_required_status_checks_policy'] = False
        self.pr.update(requested_reviewers=[dict(id=3)], requested_teams=[dict(id=4)])
        self.now = datetime.now(timezone.utc).replace(microsecond=0)
        self.when = self.stamp(0)
        self.native_run['created_at'] = self.stamp(-10)
        self.native_run['display_title'] = (
            f'Ready v1 pr:{NUMBER} head:{HEAD} head-repo:100 base-repo:100 base:main source:{BASE}')
        self.native_job['steps'][1]['name'] = (
            n.SOURCE_STEP + BASE + ' for ' + self.native_run['display_title'].rsplit(' source:', 1)[0])
        self.native_job.update(run_id=NATIVE_RUN, run_attempt=1, head_sha=HEAD, runner_id=123)
        self.verdict(False)
        self.arm = None
        self.arm_event = None
        self.arm_number = 0
        self.background_runs = {}
        self.background_checks = {}
        self.historical_runs = {}
        self.arm_graph_modifier = None
        self.lose_enable_reply = False
        self.fail_enable = False
        self.background_run(ISSUER)

    def stamp(self, seconds):
        return (self.now + timedelta(seconds=seconds)).isoformat().replace('+00:00', 'Z')

    def verdict(self, success):
        result = 'success' if success else 'failure'
        for item in (self.native_run, self.native_job, self.native_check):
            item.update(status='completed', conclusion=result)
        for step in self.native_job['steps']:
            step.update(status='completed', conclusion='success')
        self.native_job['steps'][-1]['conclusion'] = result

    def running(self):
        for item in (self.native_run, self.native_job, self.native_check):
            item.update(status='in_progress', conclusion=None)
        self.native_job['steps'] = [
            dict(name='Checkout immutable trusted reporter source', status='completed', conclusion='success'),
            dict(name=n.SOURCE_STEP + BASE + ' for ' + self.native_run['display_title'].rsplit(' source:', 1)[0],
                 status='in_progress', conclusion=None),
            dict(name=n.ENFORCE_STEP, status='queued', conclusion=None)]

    def advance_reporter(self):
        old_attempt = self.native_run['run_attempt']
        self.historical_runs[(NATIVE_RUN, old_attempt)] = copy.deepcopy(self.native_run)
        self.native_run.update(run_attempt=old_attempt + 1, status='queued', conclusion=None)
        job_id, check_id = 9001 + old_attempt * 10, 9000 + old_attempt * 10
        self.native_job = dict(self.native_job, id=job_id, run_attempt=old_attempt + 1,
            status='queued', conclusion=None, steps=[], runner_id=0,
            check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/{check_id}')
        self.native_check = dict(self.native_check, id=check_id, status='queued', conclusion=None,
            details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{NATIVE_RUN}/job/{job_id}')
        self.native_jobs[(NATIVE_RUN, old_attempt + 1)] = [self.native_job]
        self.checks.append(self.native_check)

    def get(self, route):
        suffix = route.removeprefix(p.route('') + '/')
        if suffix.startswith('actions/runs/'):
            parts = suffix.split('/')
            if len(parts) == 5 and parts[3] == 'attempts':
                return copy.deepcopy(self.historical_runs[(int(parts[2]), int(parts[4]))])
            if len(parts) == 3 and int(parts[2]) in self.background_runs:
                return copy.deepcopy(self.background_runs[int(parts[2])])
        if suffix.startswith('check-runs/') and int(suffix.split('/')[-1]) in self.background_checks:
            return copy.deepcopy(self.background_checks[int(suffix.split('/')[-1])])
        return super().get(route)

    def pages(self, route, key=None):
        if 'dependabot-auto-merge.yml/runs?created=' in route:
            return copy.deepcopy(list(self.background_runs.values()))
        return super().pages(route, key)

    def graphql(self, query, variables):
        if query.startswith('mutation'):
            if 'enablePullRequestAutoMerge' in query:
                self.mutations.append(('graphql', query, copy.deepcopy(variables)))
                if self.fail_enable:
                    raise PermissionError('denied')
                self.arm_number += 1
                self.arm = dict(enabledAt=self.when, mergeMethod='SQUASH', enabledBy=dict(a.ACTOR))
                self.arm_event = dict(__typename='AutoSquashEnabledEvent', id=f'ARM_{self.arm_number}',
                                      createdAt=self.when, actor=dict(a.ACTOR))
                self.pr['auto_merge'] = dict(enabled_by=dict(login='github-actions[bot]'))
                if self.lose_enable_reply:
                    raise OSError('lost enable reply after acceptance')
                return dict(enablePullRequestAutoMerge=dict(pullRequest=dict(id='PR_node', headRefOid=HEAD,
                                                                            autoMergeRequest=copy.deepcopy(self.arm))))
            if 'disablePullRequestAutoMerge' in query:
                self.arm = None
                self.arm_event = dict(__typename='AutoMergeDisabledEvent', id='DISABLED', createdAt=self.when)
        if 'timelineItems(' in query and 'autoMergeRequest' in query:
            result = dict(repository=dict(nameWithOwner=p.REPOSITORY, pullRequest=dict(
                id='PR_node', headRefOid=self.graph_head, autoMergeRequest=copy.deepcopy(self.arm),
                timelineItems=dict(nodes=[] if self.arm_event is None else [copy.deepcopy(self.arm_event)]))))
            if self.arm_graph_modifier:
                self.arm_graph_modifier(result)
            return result
        return super().graphql(query, variables)

    def mutate(self, method, route, payload):
        if route == p.route(f'actions/jobs/{self.native_job["id"]}/rerun'):
            self.mutations.append((method, route, copy.deepcopy(payload)))
            self.advance_reporter()
            return None
        raise AssertionError('Unexpected offline mutation: ' + method + ' ' + route)

    def background_run(self, identifier):
        run = dict(self.ready_run, id=identifier, run_number=identifier, check_suite_id=identifier + 1000,
                   event='workflow_run', head_sha=BASE, head_branch='main', pull_requests=[],
                   created_at=self.stamp(-5), status='in_progress', conclusion=None)
        self.background_runs[identifier] = run
        return run

    def background_job(self, run, name, identifier, steps):
        check_id = identifier + 1000
        job = dict(id=identifier, name=name, run_id=run['id'], run_attempt=run['run_attempt'], head_sha=BASE,
                   status='completed', conclusion='success', started_at=self.stamp(-1), completed_at=self.stamp(1),
                   check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/{check_id}',
                   steps=[dict(name=step, status='completed', conclusion='success') for step in steps])
        self.background_checks[check_id] = dict(id=check_id, name=name, app=dict(id=p.APP), head_sha=BASE,
            check_suite=dict(id=run['check_suite_id']), status='completed', conclusion='success',
            details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{run["id"]}/job/{identifier}')
        return job

    def publish_receipt(self, text):
        run = self.background_run(ISSUER)
        self.inspector = self.background_job(run, 'inspect', 12001, [p.COORDINATOR_SOURCE_STEP + BASE])
        self.receipt_job = self.background_job(run, f'bot-ready ({NUMBER})', 12002,
            ['Checkout trusted coordinator only', a.GATE_STEP, text])
        self.ready_jobs[(ISSUER, 1)] = [self.inspector, self.receipt_job]
        return run

    def publish_refresh_writer(self, target):
        run = self.background_run(WRITER)
        job = self.background_job(run, n.claim_name(target), 12003, [n.REQUEST_STEP])
        job.update(status='in_progress', conclusion=None, started_at=self.stamp(2), completed_at=None)
        job['steps'][0].update(status='in_progress', conclusion=None)
        self.ready_jobs[(WRITER, 1)] = [job]


class NativeArmPolicyTests(unittest.TestCase):
    def setUp(self):
        self.api = ArmTranscript()
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name) / 'output'
        self.env = mock.patch.dict(os.environ, dict(TRUSTED, GITHUB_JOB='bot-ready', GITHUB_WORKFLOW_SHA=BASE,
            GITHUB_EVENT_NAME='workflow_run', GITHUB_RUN_ID=str(ISSUER), GITHUB_OUTPUT=str(self.output)), clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def arm_and_publish(self):
        result = p.coordinate(self.api, NUMBER, True)
        self.assertIn('armed', result)
        values = dict(line.split('=', 1) for line in self.output.read_text().splitlines())
        self.receipt = values['arm_receipt']
        self.api.publish_receipt(self.receipt)
        return self.receipt

    def verify(self, snapshot=False):
        proof = p.proof(self.api, NUMBER)
        return a.verify(self.api, p, n, NUMBER, proof, self.api.native_run, snapshot=snapshot)

    def snapshot(self):
        event = Path(self.directory.name) / 'event.json'
        event.write_text(json.dumps(dict(pull_request=self.api.pr)))
        with mock.patch.dict(os.environ, GITHUB_JOB='ready', GITHUB_EVENT_NAME='pull_request_target',
            GITHUB_WORKFLOW_REF=p.REPOSITORY + '/' + n.REPORTER_PATH + '@refs/heads/main',
            GITHUB_RUN_ID=str(NATIVE_RUN), GITHUB_RUN_ATTEMPT=str(self.api.native_run['run_attempt']),
            GITHUB_EVENT_PATH=str(event)):
            return n.snapshot(self.api, p, NUMBER, True)

    def test_full_failed_ready_arm_receipt_refresh_pending_snapshot_success_handshake(self):
        self.arm_and_publish()
        binding = self.verify()
        self.assertEqual(len(self.api.mutations), 1)
        self.assertIn('expectedHeadOid', self.api.mutations[0][1])
        self.assertEqual(self.api.mutations[0][2], dict(id='PR_node', head=HEAD))
        target = n.refresh_plan(self.api, p, NUMBER, True)
        self.api.publish_refresh_writer(target)
        with mock.patch.dict(os.environ, GITHUB_JOB='ready-refresh', GITHUB_RUN_ID=str(WRITER)):
            self.assertIn('Verified native reporter rerun requested', n.refresh(self.api, p, target, True))
        self.assertEqual(self.api.native_run['run_attempt'], 2)
        self.assertEqual(self.verify(), binding)
        self.assertIn('armed', p.coordinate(self.api, NUMBER, True))
        self.assertEqual(len(self.api.mutations), 2)
        self.api.running()
        self.assertIn('armed', p.coordinate(self.api, NUMBER, True))
        self.assertTrue(self.snapshot()[0])
        self.assertEqual(len(self.api.mutations), 2)
        self.api.verdict(True)
        self.assertEqual(self.verify(), binding)
        self.assertIn('armed', p.coordinate(self.api, NUMBER, True))
        self.assertEqual(len(self.api.mutations), 2)
        self.assertIsNone(n.refresh_plan(self.api, p, NUMBER, True))
        self.assertFalse(any('/check-runs' in str(item) or str(item[1]).endswith('/merge') for item in self.api.mutations))

    def test_fresh_running_bot_cannot_pass_without_arm_receipt(self):
        self.api.running()
        self.assertFalse(self.snapshot()[0])
        self.assertFalse(self.api.mutations)

    def test_in_progress_issuer_workflow_is_allowed_but_receipt_job_must_succeed(self):
        self.arm_and_publish()
        self.assertEqual(self.api.background_runs[ISSUER]['status'], 'in_progress')
        self.verify()
        for field, value in [('status', 'in_progress'), ('conclusion', 'failure'), ('conclusion', 'cancelled')]:
            saved = self.api.receipt_job[field]
            self.api.receipt_job[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(p.Rejected):
                self.verify()
            self.api.receipt_job[field] = saved

    def test_failed_sibling_matrix_leg_does_not_authorize_or_block_this_pr(self):
        self.arm_and_publish()
        run = self.api.background_runs[ISSUER]
        run.update(status='completed', conclusion='failure')
        sibling = self.api.background_job(run, f'bot-ready ({NUMBER + 1})', 12004, [a.GATE_STEP])
        sibling.update(conclusion='failure')
        sibling['steps'][0]['conclusion'] = 'failure'
        self.api.background_checks[13004]['conclusion'] = 'failure'
        self.api.ready_jobs[(ISSUER, 1)].append(sibling)
        self.verify()
        target = n.refresh_plan(self.api, p, NUMBER, True)
        self.assertIsNotNone(target)
        self.api.publish_refresh_writer(target)
        with mock.patch.dict(os.environ, GITHUB_JOB='ready-refresh', GITHUB_RUN_ID=str(WRITER)):
            n.refresh(self.api, p, target, True)
        self.api.running()
        self.assertTrue(self.snapshot()[0])
        # Aggregate workflow failure is not evidence for this PR. Its own
        # receipt still has to pass every job/check/step validation.
        self.api.receipt_job['conclusion'] = 'failure'
        self.api.background_checks[13002]['conclusion'] = 'failure'
        with self.assertRaisesRegex(p.Rejected, 'did not succeed'):
            self.verify()
        self.assertFalse(n.desired(self.api, p, NUMBER, True)[0])

    def test_receipt_identity_tampering_never_reaches_ready_success(self):
        self.arm_and_publish()
        mutations = [lambda api: api.receipt_job.update(run_attempt=2),
            lambda api: api.receipt_job.update(head_sha=HEAD),
            lambda api: api.receipt_job.update(run_id=ISSUER + 1),
            lambda api: api.receipt_job.update(check_run_url='https://example.invalid/check-runs/13002'),
            lambda api: api.background_checks[13002]['app'].update(id=1),
            lambda api: api.background_checks[13002]['check_suite'].update(id=1),
            lambda api: api.background_checks[13002].update(details_url='https://example.invalid/job/12002'),
            lambda api: api.inspector['steps'][0].update(name=p.COORDINATOR_SOURCE_STEP + 'e' * 40),
            lambda api: api.receipt_job['steps'][-1].update(conclusion='skipped'),
            lambda api: api.receipt_job['steps'].append(copy.deepcopy(api.receipt_job['steps'][-1])),
            lambda api: api.receipt_job['steps'][1].update(name='Other successful step'),
            lambda api: api.background_runs[ISSUER].update(event='pull_request'),
            lambda api: api.background_runs[ISSUER].update(head_branch='untrusted'),
            lambda api: api.background_runs[ISSUER].update(head_sha=HEAD),
            lambda api: api.background_runs[ISSUER].update(workflow_id=99),
            lambda api: api.receipt_job.update(started_at=api.stamp(1)),
            lambda api: api.receipt_job.update(completed_at=api.stamp(-1))]
        baseline = copy.deepcopy(self.api)
        for mutate in mutations:
            self.api = copy.deepcopy(baseline)
            mutate(self.api)
            with self.subTest(mutate=mutate), self.assertRaises(p.Rejected):
                self.verify()
        self.api = baseline

    def test_request_and_event_times_may_differ_but_both_belong_to_issuer_job(self):
        self.arm_and_publish()
        proof = p.proof(self.api, NUMBER)
        barrier = a.failed_reporter(self.api, p, n, NUMBER, HEAD)
        # GitHub does not promise that the two timestamps are identical.
        self.api.arm_event['createdAt'] = self.api.stamp(1)
        updated = a.receipt(NUMBER, proof, barrier, BASE, a.state(self.api, p, NUMBER, proof))
        self.api.receipt_job['steps'][-1]['name'] = updated
        self.verify()
        baseline = copy.deepcopy(self.api)
        for field in ('request', 'event'):
            self.api = copy.deepcopy(baseline)
            if field == 'request': self.api.arm['enabledAt'] = self.api.stamp(-2)
            else: self.api.arm_event['createdAt'] = self.api.stamp(-2)
            self.api.receipt_job['steps'][-1]['name'] = a.receipt(
                NUMBER, proof, barrier, BASE, a.state(self.api, p, NUMBER, proof))
            with self.subTest(field=field), self.assertRaisesRegex(p.Rejected, 'job execution'):
                self.verify()

    def test_coordinator_older_than_selected_reporter_never_arms_undiscoverable_receipt(self):
        self.api.background_runs[ISSUER]['created_at'] = self.api.stamp(-11)
        self.assertIn('predates selected reporter', p.coordinate(self.api, NUMBER, True))
        self.assertFalse(self.api.mutations)
        self.assertFalse(self.output.exists())
        self.api.background_runs[ISSUER]['created_at'] = self.api.native_run['created_at']
        self.arm_and_publish()
        self.verify()

    def test_untrusted_other_pr_cannot_dos_discovery_with_malformed_receipt(self):
        self.arm_and_publish()
        run = self.api.background_run(ISSUER + 1)
        run.update(event='pull_request', head_branch='untrusted', head_sha=HEAD)
        self.api.ready_jobs[(run['id'], 1)] = [self.api.background_job(
            run, f'bot-ready ({NUMBER})', 14001, [a.PREFIX + f'pr:{NUMBER} malformed'])]
        self.verify()
        self.assertIn('armed', p.coordinate(self.api, NUMBER, True))
        self.assertEqual(len(self.api.mutations), 1)

    def test_untrusted_list_candidates_require_no_detail_or_job_reads(self):
        self.arm_and_publish()
        for offset, changes in enumerate(({'event': 'pull_request'}, {'workflow_id': -1},
                {'head_branch': 'untrusted'}, {'repository': {'id': -1}},
                {'head_repository': {'id': -1}}, {'event': 'pull_request_target', 'pull_requests': []}), 1):
            self.api.background_run(ISSUER + offset).update(changes)
        proof = p.proof(self.api, NUMBER)
        with mock.patch.object(self.api, 'get', wraps=self.api.get) as get, \
                mock.patch.object(self.api, 'pages', wraps=self.api.pages) as pages:
            a.verify(self.api, p, n, NUMBER, proof, self.api.native_run)
        for offset in range(1, 7):
            identifier = ISSUER + offset
            self.assertNotIn(mock.call(p.route(f'actions/runs/{identifier}')), get.call_args_list)
            self.assertNotIn(mock.call(p.route(f'actions/runs/{identifier}/attempts/1/jobs'), 'jobs'),
                             pages.call_args_list)
        self.assertIn(mock.call(p.route(f'actions/runs/{ISSUER}')), get.call_args_list)

    def test_trusted_list_candidate_is_revalidated_after_detail_fetch(self):
        self.arm_and_publish()
        proof = p.proof(self.api, NUMBER)
        original_get = self.api.get
        def changed_detail(route):
            result = original_get(route)
            if route == p.route(f'actions/runs/{ISSUER}'):
                result['event'] = 'pull_request'
            return result
        with mock.patch.object(self.api, 'get', side_effect=changed_detail) as get, \
                mock.patch.object(self.api, 'pages', wraps=self.api.pages) as pages:
            with self.assertRaisesRegex(p.Rejected, 'missing or ambiguous'):
                a.verify(self.api, p, n, NUMBER, proof, self.api.native_run)
        self.assertIn(mock.call(p.route(f'actions/runs/{ISSUER}')), get.call_args_list)
        self.assertNotIn(mock.call(p.route(f'actions/runs/{ISSUER}/attempts/1/jobs'), 'jobs'),
                         pages.call_args_list)

    def test_pending_native_step_shape_cannot_hide_failed_or_foreign_execution(self):
        self.arm_and_publish()
        self.api.advance_reporter()
        self.verify()
        baseline = copy.deepcopy(self.api)
        values = [None, {}, [{'name': 'untrusted', 'status': 'in_progress', 'conclusion': None}],
                  [{'name': 'Set up job', 'status': 'completed', 'conclusion': 'failure'}],
                  [{'name': 'Set up job', 'status': 'queued', 'conclusion': 'success'}]]
        for value in values:
            self.api = copy.deepcopy(baseline)
            self.api.native_job['steps'] = value
            with self.subTest(value=value), self.assertRaises((p.Rejected, AttributeError)):
                self.verify()
        self.api = baseline
        self.api.native_job.pop('steps')
        with self.assertRaises(p.Rejected): self.verify()

    def test_same_second_reenable_new_event_id_rejects_old_receipt(self):
        self.arm_and_publish()
        original = copy.deepcopy(self.api.arm)
        self.api.arm_event['id'] = 'SECOND_ENABLE_SAME_SECOND'
        self.assertEqual(self.api.arm, original)
        with self.assertRaises(p.Rejected):
            self.verify()
        self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertIn('disablePullRequestAutoMerge', self.api.mutations[-1][1])

    def test_arm_actor_method_timeline_and_pr_identity_are_not_optional(self):
        self.arm_and_publish()
        mutations = [lambda api: api.arm.update(mergeMethod='MERGE'),
            lambda api: api.arm['enabledBy'].update(databaseId=1),
            lambda api: api.arm_event['actor'].update(login='lookalike'),
            lambda api: api.arm_event.update(__typename='AutoMergeDisabledEvent'),
            lambda api: api.arm_event.update(createdAt=api.stamp(1)),
            lambda api: api.arm_event.update(id=''),
            lambda api: api.arm.update(enabledAt=None),
            lambda api: setattr(api, 'graph_head', BASE)]
        baseline = copy.deepcopy(self.api)
        for mutate in mutations:
            self.api = copy.deepcopy(baseline)
            mutate(self.api)
            with self.subTest(mutate=mutate), self.assertRaises(p.Rejected):
                self.verify()

    def test_proof_source_and_original_failure_cannot_be_replayed(self):
        self.arm_and_publish()
        proof = p.proof(self.api, NUMBER)
        for key in ['head', 'base', 'merge', 'run', 'attempt', 'node']:
            changed = dict(proof, **{key: 999 if key in {'run', 'attempt'} else 'e' * 40})
            with self.subTest(key=key), self.assertRaises(p.Rejected):
                a.verify(self.api, p, n, NUMBER, changed, self.api.native_run)
        self.api.verdict(True)
        with self.assertRaises(p.Rejected):
            self.verify()

    def test_obsolete_receipt_source_or_helper_blob_never_supplies_current_permission(self):
        self.arm_and_publish()
        proof = p.proof(self.api, NUMBER)
        self.api.receipt_job['steps'][-1]['name'] = self.receipt.replace('source:' + BASE, 'source:' + 'e' * 40)
        with self.assertRaises(p.Rejected):
            self.verify()
        self.api.receipt_job['steps'][-1]['name'] = self.receipt
        self.api.base = 'f' * 40
        self.api.source_blobs['contents/Scripts/dependabot-arm-policy.py?ref=' + BASE] = 'e' * 40
        with self.assertRaisesRegex(p.Rejected, 'obsolete reporter'):
            a.verify(self.api, p, n, NUMBER, proof, self.api.native_run)

    def test_queued_no_job_exempts_no_orphan_check_and_still_requires_full_proof_digest(self):
        self.arm_and_publish()
        self.api.advance_reporter()
        self.api.native_jobs[(NATIVE_RUN, 2)] = []
        orphan = self.api.checks.pop()
        self.assertEqual(n.verified_check_ids(self.api, p, NUMBER, HEAD), {9000})
        self.assertIn('armed', p.coordinate(self.api, NUMBER, True))
        self.assertEqual(len(self.api.mutations), 1)
        self.api.checks.append(orphan)
        with self.assertRaises(p.Rejected):
            p.proof(self.api, NUMBER)
        self.api.checks.pop()
        self.api.receipt_job['steps'][-1]['name'] = self.receipt.replace(
            a.PATTERN.fullmatch(self.receipt)[2], 'f' * 64)
        self.assertEqual(n.verified_check_ids(self.api, p, NUMBER, HEAD), {9000})
        self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertIsNone(self.api.pr['auto_merge'])

    def test_new_coordinator_attempt_cannot_reuse_prior_attempt_success(self):
        self.arm_and_publish()
        self.api.background_runs[ISSUER]['run_attempt'] = 2
        with self.assertRaises(p.Rejected):
            self.verify()

    def test_historical_reporter_attempt_identity_cannot_be_forged(self):
        self.arm_and_publish()
        self.api.advance_reporter()
        original = copy.deepcopy(self.api.historical_runs[(NATIVE_RUN, 1)])
        for key, value in [('id', NATIVE_RUN + 1), ('run_number', 1), ('run_attempt', 2),
                           ('check_suite_id', 1), ('display_title', ''), ('head_sha', BASE),
                           ('event', 'workflow_dispatch'), ('conclusion', 'success')]:
            self.api.historical_runs[(NATIVE_RUN, 1)] = dict(original, **{key: value})
            with self.subTest(key=key), self.assertRaises(p.Rejected):
                self.verify()
        self.api.historical_runs[(NATIVE_RUN, 1)] = original

    def test_native_arm_change_during_receipt_verification_is_rejected(self):
        self.arm_and_publish()
        proof = p.proof(self.api, NUMBER)
        reads = 0
        def changed(result):
            nonlocal reads
            reads += 1
            if reads == 2:
                result['repository']['pullRequest']['timelineItems']['nodes'][0]['id'] = 'NEW_EVENT'
        self.api.arm_graph_modifier = changed
        with self.assertRaisesRegex(p.Rejected, 'changed during receipt'):
            a.verify(self.api, p, n, NUMBER, proof, self.api.native_run)

    def test_current_blocker_or_new_lifecycle_reporter_revokes_pending_arm(self):
        self.arm_and_publish()
        self.api.advance_reporter()
        baseline = copy.deepcopy(self.api)
        for change in [lambda api: api.review_list.append(dict(id=1, user=dict(id=3), state='PENDING')),
                       lambda api: setattr(api, 'review_decision', 'REVIEW_REQUIRED'),
                       lambda api: api.threads.append(dict(isResolved=False)),
                       lambda api: api.run.update(conclusion='failure'),
                       lambda api: setattr(api, 'base', 'e' * 40),
                       lambda api: api.ruleset.update(current_user_can_bypass='always')]:
            self.api = copy.deepcopy(baseline)
            change(self.api)
            with self.subTest(change=change):
                self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
                self.assertIsNone(self.api.pr['auto_merge'])
        self.api = baseline
        newer = dict(self.api.native_run, id=NATIVE_RUN + 1, run_number=999, run_attempt=1,
                     status='queued', conclusion=None, check_suite_id=999)
        self.api.native_runs.append(newer)
        self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertIsNone(self.api.pr['auto_merge'])

    def test_only_original_failed_attempt_plus_one_can_issue_snapshot_success(self):
        self.arm_and_publish()
        self.api.running()
        self.assertFalse(self.snapshot()[0])
        # Restore the original controlled barrier before the real rerun.
        self.api.verdict(False)
        self.api.advance_reporter()
        self.api.running()
        self.assertTrue(self.snapshot()[0])
        self.api.verdict(False)
        self.api.advance_reporter()
        self.api.running()
        self.assertFalse(self.snapshot()[0])

    def test_unpublished_or_ambiguous_receipt_never_arms_reporter(self):
        self.arm_and_publish()
        self.api.ready_jobs[(ISSUER, 1)] = [self.api.inspector]
        with self.assertRaises(p.Rejected):
            self.verify()
        self.api.ready_jobs[(ISSUER, 1)].extend([self.api.receipt_job, copy.deepcopy(self.api.receipt_job)])
        with self.assertRaises(p.Rejected):
            self.verify()

    def test_lost_enable_reply_reads_back_without_second_enable(self):
        self.api.lose_enable_reply = True
        self.arm_and_publish()
        self.verify()
        self.assertEqual(len(self.api.mutations), 1)

    def test_denied_enable_never_issues_receipt_or_direct_merge(self):
        self.api.fail_enable = True
        self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertFalse(self.output.exists())
        self.assertEqual(len(self.api.mutations), 1)
        self.assertIsNone(self.api.pr['auto_merge'])

    def test_post_enable_proof_failure_cancels_and_leaves_no_receipt(self):
        original = p.proof
        calls = 0
        def raced(api, number, notification=None):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise p.Rejected('review changed after native enable')
            return original(api, number, notification)
        with mock.patch.object(p, 'proof', side_effect=raced):
            self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertFalse(self.output.exists())
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertEqual(len(self.api.mutations), 2)
        self.assertIn('disablePullRequestAutoMerge', self.api.mutations[-1][1])

    def test_terminal_failed_or_cancelled_target_attempt_revokes_existing_arm(self):
        for conclusion in ('failure', 'cancelled'):
            with self.subTest(conclusion=conclusion):
                self.api = ArmTranscript()
                self.arm_and_publish()
                self.api.advance_reporter()
                self.api.running()
                self.api.verdict(False)
                for item in (self.api.native_run, self.api.native_job, self.api.native_check):
                    item['conclusion'] = conclusion
                self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
                self.assertIsNone(self.api.pr['auto_merge'])


if __name__ == '__main__':
    unittest.main()
