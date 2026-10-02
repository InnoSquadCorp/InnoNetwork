"""Offline source/provenance transcripts for the trusted Pages publisher."""
import copy
from contextlib import redirect_stderr
import importlib.util
import io
from pathlib import Path
import re
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('publish_docs', ROOT / 'Scripts/publish-docs.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
HEAD, OLD = 'a' * 40, 'b' * 40
RUN, ATTEMPT = 91, 2
NEW_INTERMEDIATE_STATES = ['syncing_files', 'finished_file_sync', 'updating_pages', 'purging_cdn', 'deployment_queued']


class Transcript:
    def __init__(self, name='CI', event='push', branch='main'):
        self.repo = dict(id=100, full_name=p.REPOSITORY, default_branch='main')
        self.run = dict(id=RUN, run_attempt=ATTEMPT, name=name, path=p.WORKFLOWS[name],
                        workflow_id=10, check_suite_id=20, head_sha=HEAD, head_branch=branch,
                        event=event, status='completed', conclusion='success',
                        repository=self.repo, head_repository=self.repo,
                        display_title='CI / Dependabot merge #45' if event == 'workflow_dispatch' else name)
        self.notice = dict(repository=self.repo, workflow_run=copy.deepcopy(self.run))
        self.workflow = dict(id=10, path=self.run['path'], name=name, state='active')
        self.main = dict(object=dict(type='commit', sha=HEAD))
        self.tag = dict(object=dict(type='commit', sha=HEAD))
        self.tag_object = dict(object=dict(type='commit', sha=HEAD))
        self.pr = dict(number=45, state='closed', merged=True, merge_commit_sha=HEAD,
                       user=dict(p.BOT), base=dict(ref='main', repo=self.repo), head=dict(repo=self.repo))
        self.jobs, self.checks = [], {}
        if name == 'CI':
            self.add_job('CI Plan', ['Checkout', 'Verify actual post-merge main origin', 'Plan exact changed paths', 'Preserve change selection evidence'])
            if event == 'push':
                self.jobs[0]['steps'][1]['conclusion'] = 'skipped'
            self.add_job('CI Required', ['Require every planned CI result'])
        self.add_job('Build DocC Site' if name == 'CI' else 'Build DocC archives',
                     ['Checkout', 'Build DocC archives', 'Verify public DocC archives', 'Transform DocC archives for static hosting', 'Validate DocC site files', 'Upload Documentation Artifact'])
        self.artifact = dict(id=30, name=f'github-pages-{RUN}-{ATTEMPT}-{HEAD}', expired=False,
                             size_in_bytes=256, digest='sha256:' + 'c' * 64,
                             workflow_run=dict(id=RUN, repository_id=100, head_repository_id=100,
                                               head_branch=branch, head_sha=HEAD))
        self.artifacts = [self.artifact]
        self.page = dict(build_type='workflow', html_url='https://innosquadcorp.github.io/InnoNetwork/')
        self.deployment = dict(id=HEAD, page_url=self.page['html_url'])
        self.statuses = ['succeed']
        self.reads, self.mutations = [], []
        self.oidc_hook = None
        self.proof_run_reads = 0
        self.fail_create = False

    def add_job(self, name, names):
        index = len(self.jobs)
        job_id, check_id = 200 + index, 300 + index
        self.jobs.append(dict(id=job_id, name=name, status='completed', conclusion='success',
                             check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/{check_id}',
                             steps=[dict(name=n, status='completed', conclusion='success') for n in names]))
        self.checks[str(check_id)] = dict(id=check_id, name=name, status='completed', conclusion='success',
                                        app=dict(id=p.APP), check_suite=dict(id=20), head_sha=HEAD,
                                        details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{RUN}/job/{job_id}')

    def get(self, route):
        self.reads.append(route)
        suffix = route.removeprefix(f'repos/{p.REPOSITORY}').lstrip('/')
        if not suffix: value = self.repo
        elif suffix == f'actions/runs/{RUN}':
            self.proof_run_reads += 1
            value = self.run
        elif suffix.startswith('actions/workflows/'): value = self.workflow
        elif suffix.startswith('check-runs/'): value = self.checks[suffix.rsplit('/', 1)[1]]
        elif suffix == 'git/ref/heads/main': value = self.main
        elif suffix.startswith('git/ref/tags/'): value = self.tag
        elif suffix.startswith('git/tags/'): value = self.tag_object
        elif suffix == 'pulls/45': value = self.pr
        elif suffix == 'pages': value = self.page
        elif suffix == f'pages/deployments/{HEAD}':
            value = dict(status=self.statuses[0])
            if len(self.statuses) > 1: self.statuses.pop(0)
        else: raise AssertionError('Unexpected read ' + route)
        return copy.deepcopy(value)

    def pages(self, route, key):
        self.reads.append(route)
        if route == p.route(f'actions/runs/{RUN}/attempts/{ATTEMPT}/jobs'):
            assert key == 'jobs'
            return copy.deepcopy(self.jobs)
        if route == p.route(f'actions/runs/{RUN}/artifacts'):
            assert key == 'artifacts'
            return copy.deepcopy(self.artifacts)
        raise AssertionError('Unexpected page read ' + route)

    def id_token(self):
        if self.oidc_hook: self.oidc_hook(self)
        return 'not-a-real-token'

    def mutate(self, route, data):
        self.mutations.append((route, copy.deepcopy(data)))
        if route.endswith('/cancel'): return None
        if self.fail_create: raise OSError('ambiguous create response')
        assert route == p.route('pages/deployments')
        return copy.deepcopy(self.deployment)


class PublisherProofTests(unittest.TestCase):
    def reject(self, change, **kwargs):
        api = Transcript(**kwargs)
        change(api)
        with self.assertRaises((p.Rejected, KeyError, TypeError, ValueError)):
            p.publish(api, api.notice, sleep=lambda _: None)
        self.assertEqual(api.mutations, [])

    def test_current_main_push_and_verified_recovery_publish_once(self):
        for event in ['push', 'workflow_dispatch']:
            api = Transcript(event=event)
            self.assertEqual(p.publish(api, api.notice), api.page['html_url'])
            self.assertEqual(len(api.mutations), 1)
            route, data = api.mutations[0]
            self.assertEqual(route, p.route('pages/deployments'))
            self.assertEqual(data['artifact_id'], api.artifact['id'])
            self.assertEqual(data['pages_build_version'], HEAD)
            self.assertEqual(api.reads.count(p.route('git/ref/heads/main')), 3)
            self.assertEqual(api.proof_run_reads, 2)
            self.assertFalse(any('/zip' in path or '/download' in path for path in api.reads))

    def test_non_ci_source_rejected(self):
        self.reject(lambda a: a.run.update(name='Documentation'))
        self.reject(lambda a: a.run.update(path='.github/workflows/docc-pages.yml'))

    def test_publisher_requires_trusted_default_branch_execution(self):
        env = dict(GITHUB_REPOSITORY=p.REPOSITORY, GITHUB_EVENT_NAME='workflow_run', GITHUB_REF='refs/heads/main',
                   GITHUB_WORKFLOW_REF=f'{p.REPOSITORY}/.github/workflows/docs-publish.yml@refs/heads/main', GITHUB_WORKFLOW_SHA=HEAD)
        p.environment(env)
        for key, value in [('GITHUB_REPOSITORY', 'fork/InnoNetwork'), ('GITHUB_EVENT_NAME', 'pull_request_target'),
                           ('GITHUB_REF', 'refs/pull/45/merge'), ('GITHUB_WORKFLOW_REF', f'{p.REPOSITORY}/.github/workflows/docs-publish.yml@refs/heads/develop'),
                           ('GITHUB_WORKFLOW_SHA', 'main')]:
            with self.subTest(key=key), self.assertRaises(p.Rejected): p.environment(dict(env, **{key: value}))

    def test_wrong_repository_workflow_event_sha_and_latest_attempt(self):
        changes = [lambda a: a.repo.update(default_branch='develop'),
                   lambda a: a.run.update(repository=dict(id=111, full_name=p.REPOSITORY)),
                   lambda a: a.run.update(head_repository=dict(id=111, full_name=p.REPOSITORY)),
                   lambda a: a.run.update(path='.github/workflows/else.yml'),
                   lambda a: a.workflow.update(id=11), lambda a: a.workflow.update(name='Fake CI'),
                   lambda a: a.workflow.update(state='disabled_manually'),
                   lambda a: a.run.update(head_sha=OLD), lambda a: a.run.update(run_attempt=1),
                   lambda a: a.run.update(run_attempt=3), lambda a: a.notice['workflow_run'].update(run_attempt=1),
                   lambda a: a.run.update(status='in_progress'), lambda a: a.run.update(conclusion='failure')]
        for change in changes:
            with self.subTest(change=change): self.reject(change)
        for event in ['pull_request', 'pull_request_target', 'merge_group']:
            self.reject(lambda _: None, event=event)
        self.reject(lambda _: None, branch='develop')

    def test_wrong_app_suite_head_job_and_incomplete_build_or_upload(self):
        changes = [lambda a: a.checks['302']['app'].update(id=999),
                   lambda a: a.checks['302']['check_suite'].update(id=999),
                   lambda a: a.checks['302'].update(head_sha=OLD),
                   lambda a: a.checks['302'].update(name='Build DocC archives'),
                   lambda a: a.checks['302'].update(details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{RUN}/job/999'),
                   lambda a: a.jobs[-1].update(check_run_url='https://evil.test/check-runs/302'),
                   lambda a: a.jobs[-1].update(conclusion='skipped'),
                   lambda a: a.jobs.pop(), lambda a: a.jobs.append(copy.deepcopy(a.jobs[-1])),
                   lambda a: a.jobs[-1]['steps'].pop(),
                   lambda a: a.jobs[-1]['steps'][1].update(conclusion='skipped'),
                   lambda a: a.jobs[-1]['steps'][2].update(conclusion='skipped'),
                   lambda a: a.jobs[-1]['steps'][2].update(status='in_progress'),
                   lambda a: a.jobs[-1]['steps'][2].update(conclusion='failure'),
                   lambda a: a.jobs[1]['steps'].clear(),
                   lambda a: a.jobs[0]['steps'][2].update(conclusion='skipped')]
        for change in changes:
            with self.subTest(change=change): self.reject(change)

    def test_forged_recovery_marker_origin_and_skipped_validation(self):
        changes = [lambda a: a.run.update(display_title='CI'),
                   lambda a: a.run.update(display_title='CI / Dependabot merge #45 extra'),
                   lambda a: a.pr.update(user=dict(login='dependabot[bot]', id=123, type='Bot')),
                   lambda a: a.pr.update(merged=False), lambda a: a.pr.update(state='open'),
                   lambda a: a.pr.update(merge_commit_sha=OLD),
                   lambda a: a.pr['base'].update(ref='develop'),
                   lambda a: a.pr['head'].update(repo=dict(id=101, full_name=p.REPOSITORY)),
                   lambda a: a.jobs[0]['steps'][1].update(conclusion='skipped')]
        for change in changes:
            with self.subTest(change=change): self.reject(change, event='workflow_dispatch')

    def test_artifact_origin_attempt_digest_and_completeness(self):
        changes = [lambda a: a.artifacts.clear(), lambda a: a.artifacts.append(copy.deepcopy(a.artifact)),
                   lambda a: a.artifact.update(name=f'github-pages-{RUN}-1-{HEAD}'),
                   lambda a: a.artifact.update(expired=True), lambda a: a.artifact.update(size_in_bytes=0),
                   lambda a: a.artifact.update(digest=None), lambda a: a.artifact.update(digest=''),
                   lambda a: a.artifact.update(id=0), lambda a: a.artifact.update(workflow_run={}),
                   lambda a: a.artifact['workflow_run'].update(id=RUN - 1),
                   lambda a: a.artifact['workflow_run'].update(repository_id=101),
                   lambda a: a.artifact['workflow_run'].update(head_repository_id=101),
                   lambda a: a.artifact['workflow_run'].update(head_sha=OLD),
                   lambda a: a.artifact['workflow_run'].update(head_branch='feature')]
        for change in changes:
            with self.subTest(change=change): self.reject(change)

    def test_stale_main_and_non_main_source_are_rejected(self):
        self.reject(lambda a: a.main['object'].update(sha=OLD))
        for branch in ['feature', '6.0.0', 'v6.0.0']:
            self.reject(lambda _: None, branch=branch)

    def test_ref_attempt_or_upload_race_before_mutation(self):
        for hook in [lambda a: a.main['object'].update(sha=OLD),
                     lambda a: a.run.update(run_attempt=3),
                     lambda a: a.artifact.update(id=31),
                     lambda a: a.jobs[-1]['steps'][2].update(conclusion='failure')]:
            self.reject(lambda a: setattr(a, 'oidc_hook', hook))
        self.reject(lambda a: a.page.update(build_type='legacy'))

    def test_pages_poll_failure_and_timeout_never_create_twice(self):
        api = Transcript()
        api.statuses = ['deployment_attempt_error', 'deployment_in_progress', 'succeed']
        p.publish(api, api.notice, sleep=lambda _: None)
        self.assertEqual(len(api.mutations), 1)
        api = Transcript()
        api.statuses = ['deployment_failed']
        with self.assertRaises(p.Rejected): p.publish(api, api.notice, sleep=lambda _: None)
        self.assertEqual(len(api.mutations), 1)
        api = Transcript()
        api.statuses = ['deployment_in_progress']
        with self.assertRaises(p.Rejected): p.publish(api, api.notice, sleep=lambda _: None)
        self.assertEqual([path.rsplit('/', 1)[1] for path, _ in api.mutations], ['deployments', 'cancel'])
        api = Transcript()
        api.fail_create = True
        with self.assertRaises(OSError): p.publish(api, api.notice, sleep=lambda _: None)
        self.assertEqual(len(api.mutations), 1)

    def test_last_main_read_and_status_read_errors_are_fail_closed(self):
        api = Transcript()
        original = api.get
        main_reads = 0
        def moved_on_final_read(route):
            nonlocal main_reads
            if route == p.route('git/ref/heads/main'):
                main_reads += 1
                if main_reads == 3: api.main['object']['sha'] = OLD
            return original(route)
        api.get = moved_on_final_read
        with self.assertRaises(p.Rejected): p.publish(api, api.notice)
        self.assertEqual(api.mutations, [])
        for temporary in [True, False]:
            api = Transcript()
            original = api.get
            failures = 0
            def unavailable_status(route):
                nonlocal failures
                if '/pages/deployments/' in route and (not temporary or failures == 0):
                    failures += 1
                    raise p.urllib.error.URLError('temporary status outage')
                return original(route)
            api.get = unavailable_status
            if temporary:
                p.publish(api, api.notice, sleep=lambda _: None)
                self.assertEqual(len(api.mutations), 1)
            else:
                with self.assertRaises(p.Rejected): p.publish(api, api.notice, sleep=lambda _: None)
                self.assertEqual([path.rsplit('/', 1)[1] for path, _ in api.mutations], ['deployments', 'cancel'])

    def test_known_intermediate_states_only_succeed_after_explicit_success(self):
        for states in [[state] for state in NEW_INTERMEDIATE_STATES] + [NEW_INTERMEDIATE_STATES]:
            with self.subTest(states=states):
                api = Transcript()
                api.statuses = list(states) + ['succeed']
                sleeps = []
                self.assertEqual(p.publish(api, api.notice, sleep=sleeps.append), api.page['html_url'])
                self.assertEqual(sleeps, [5] * len(states))
                self.assertEqual(len(api.mutations), 1)
                self.assertEqual(api.reads.count(p.route(f'pages/deployments/{HEAD}')), len(states) + 1)

    def test_each_known_intermediate_state_still_times_out_and_cancels_once(self):
        for state in NEW_INTERMEDIATE_STATES:
            with self.subTest(state=state):
                api = Transcript()
                api.statuses = [state]
                sleeps = []
                with mock.patch.object(p.time, 'monotonic', return_value=0), self.assertRaisesRegex(p.Rejected, 'timed out'):
                    p.publish(api, api.notice, sleep=sleeps.append)
                self.assertEqual(sleeps, [5] * 120)
                self.assertEqual(api.reads.count(p.route(f'pages/deployments/{HEAD}')), 120)
                self.assertEqual([path.rsplit('/', 1)[1] for path, _ in api.mutations], ['deployments', 'cancel'])

    def test_intermediate_states_cannot_extend_the_absolute_deadline(self):
        api = Transcript()
        api.statuses = ['deployment_queued', 'succeed']
        sleeps = []
        with mock.patch.object(p.time, 'monotonic', side_effect=[0, 0, 600]), self.assertRaisesRegex(p.Rejected, 'timed out'):
            p.publish(api, api.notice, sleep=sleeps.append)
        self.assertEqual(sleeps, [5])
        self.assertEqual(api.reads.count(p.route(f'pages/deployments/{HEAD}')), 1)
        self.assertEqual([path.rsplit('/', 1)[1] for path, _ in api.mutations], ['deployments', 'cancel'])

    def test_intermediate_then_terminal_failure_never_reports_success(self):
        for state in ['deployment_failed', 'deployment_content_failed', 'deployment_cancelled', 'deployment_lost']:
            with self.subTest(state=state):
                api = Transcript()
                api.statuses = ['deployment_queued', state, 'succeed']
                sleeps = []
                with self.assertRaisesRegex(p.Rejected, 'Pages deployment failed'):
                    p.publish(api, api.notice, sleep=sleeps.append)
                self.assertEqual(sleeps, [5])
                self.assertEqual(len(api.mutations), 1)

    def test_unknown_status_is_escaped_before_cancellation_even_when_cancel_fails(self):
        for state in ['success', 'deployment_queued_extra', 'updating_page', '', None, [], {},
                      'unexpected\n::error::injected\r\x1b[31m']:
            for cancel_fails in [False, True]:
                with self.subTest(state=state, cancel_fails=cancel_fails):
                    api = Transcript()
                    api.statuses = [state, 'succeed']
                    stderr = io.StringIO()
                    original = api.mutate
                    def mutation(route, data):
                        if route.endswith('/cancel'):
                            self.assertIn(repr(state), stderr.getvalue())
                            self.assertEqual(len(stderr.getvalue().splitlines()), 1)
                            if cancel_fails:
                                api.mutations.append((route, data))
                                raise p.urllib.error.URLError('cancel transport failure')
                        return original(route, data)
                    api.mutate = mutation
                    with redirect_stderr(stderr), self.assertRaises(p.urllib.error.URLError if cancel_fails else p.Rejected):
                        p.publish(api, api.notice, sleep=lambda _: self.fail('unknown status must not wait'))
                    self.assertEqual(api.reads.count(p.route(f'pages/deployments/{HEAD}')), 1)
                    self.assertEqual([path.rsplit('/', 1)[1] for path, _ in api.mutations], ['deployments', 'cancel'])

    def test_every_api_page_is_consumed_without_following_external_links(self):
        api = object.__new__(p.GitHub)
        calls = []
        def request(method, path):
            calls.append(path)
            if path.endswith('&page=1'): return {'jobs': [1]}, {'Link': '<https://evil.test/>; rel="next"'}
            return {'jobs': [2]}, {}
        api.request = request
        self.assertEqual(api.pages(p.route('actions/runs/91/attempts/2/jobs'), 'jobs'), [1, 2])
        self.assertTrue(all(path.startswith(p.route()) for path in calls))
        api.request = lambda method, path: ({'jobs': [1], 'total_count': 2}, {})
        with self.assertRaisesRegex(p.Rejected, 'truncated'):
            api.pages(p.route('actions/runs/91/attempts/2/jobs'), 'jobs')


    def test_workflow_split_is_read_only_build_and_trusted_api_publisher(self):
        build = (ROOT / '.github/workflows/ci.yml').read_text()
        publish = (ROOT / '.github/workflows/docs-publish.yml').read_text()
        docs_job = build.split('  documentation:\n')[1].split('  release-candidate:')[0]
        self.assertNotIn('write', docs_job)
        self.assertIn('  pull_request:', build)
        self.assertNotIn('deploy-pages@', build)
        self.assertNotIn('configure-pages@', build)
        self.assertNotIn('deploy-docs:', build)
        self.assertIn('github-pages-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.sha }}', build)
        self.assertIn('bash Scripts/check_docc_archives.sh .build/DocC', build)
        self.assertIn('    workflows: [CI]', publish)
        self.assertIn("github.workflow_ref == 'InnoSquadCorp/InnoNetwork/.github/workflows/docs-publish.yml@refs/heads/main'", publish)
        self.assertIn('ref: ${{ github.workflow_sha }}', publish)
        self.assertIn('sparse-checkout: Scripts/publish-docs.py', publish)
        self.assertIn('persist-credentials: false', publish)
        self.assertIn('run: python3 -B Scripts/publish-docs.py', publish)
        self.assertNotIn('\nconcurrency:', publish)  # Ineligible PR notifications cannot evict a queued deployment.
        for forbidden in ['workflow_run.head_sha }}', 'download-artifact', 'cache@', 'secrets.', 'continue-on-error']:
            self.assertNotIn(forbidden, publish)


if __name__ == '__main__':
    unittest.main()
