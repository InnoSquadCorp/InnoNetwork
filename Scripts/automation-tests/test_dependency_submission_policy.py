"""No-op notifications must never replace an immutable dependency submission."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


def workflows():
    names = ['dependency-submission.yml', 'pr-dependency-submission.yml', 'ci.yml', 'release.yml']
    return json.loads(subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
        'puts ARGV.to_h { |p| [File.basename(p), YAML.safe_load(File.read(p), aliases: false)] }.to_json',
        *[str(ROOT / '.github/workflows' / name) for name in names]], text=True))


def main_eligible(condition, event, ref='refs/heads/main', source_event='pull_request', source_branch='topic', title='CI'):
    values = {'github.ref':repr(ref), 'github.event_name':repr(event),
              'github.event.workflow_run.event':repr(source_event),
              'github.event.workflow_run.head_branch':repr(source_branch),
              'github.event.workflow_run.display_title':repr(title)}
    for name, value in values.items(): condition = condition.replace(name, value)
    return eval(condition.replace('&&', ' and ').replace('||', ' or '),
                {'__builtins__':{}, 'startsWith':lambda text, prefix:text.startswith(prefix)})


class SubmissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.docs = workflows()

    def test_only_eligible_jobs_enter_sha_scoped_non_cancelling_queues(self):
        for filename, group in [
                ('dependency-submission.yml', 'swift-dependency-submission-${{ github.sha }}'),
                ('pr-dependency-submission.yml', 'swift-pr-dependency-submission-${{ github.event.workflow_run.head_sha }}')]:
            workflow = self.docs[filename]
            self.assertNotIn('concurrency', workflow)
            self.assertEqual(set(workflow['jobs']), {'submit'})
            job = workflow['jobs']['submit']
            self.assertTrue(job['if'])
            self.assertEqual(job['concurrency'], {'group':group, 'cancel-in-progress':False, 'queue':'max'})

    def test_pr_and_push_ci_wake_cannot_preempt_main_snapshot(self):
        condition = self.docs['dependency-submission.yml']['jobs']['submit']['if']
        self.assertTrue(main_eligible(condition, 'push'))
        self.assertTrue(main_eligible(condition, 'workflow_dispatch'))
        for source_event in ['pull_request', 'push', 'merge_group']:
            self.assertFalse(main_eligible(condition, 'workflow_run', source_event=source_event, source_branch='main'))
        self.assertFalse(main_eligible(condition, 'workflow_run', source_event='workflow_dispatch', source_branch='main'))
        self.assertTrue(main_eligible(condition, 'workflow_run', source_event='workflow_dispatch',
                                      source_branch='main', title='CI / Dependabot merge #123'))
        self.assertFalse(main_eligible(condition, 'push', ref='refs/heads/topic'))

    def test_initial_notification_is_deduplicated_but_reruns_are_kept(self):
        from test_ci_event_routing import evaluate
        condition = self.docs['pr-dependency-submission.yml']['jobs']['submit']['if'].replace('null', 'None')
        for action in ['requested', 'in_progress', 'completed']:
            for attempt in [1, 2, 3]:
                for metadata in [False, True]:
                    values = {'github.event.workflow_run.event': 'pull_request',
                              'github.event.workflow_run.pull_requests[0].number': 137,
                              'github.event.workflow_run.display_title': 'CI metadata-only v1 pr:137' if metadata else 'CI validation v2 pr:137',
                              'github.event.action': action, 'github.event.workflow_run.run_attempt': attempt}
                    self.assertEqual(evaluate(condition, values), not metadata and
                                     (action == 'requested' or action == 'in_progress' and attempt > 1))
                    values['github.event.workflow_run.event'] = 'push'
                    self.assertFalse(evaluate(condition, values))

    def test_snapshot_writers_keep_trusted_checkout_and_pr_data_only(self):
        for filename in ['dependency-submission.yml', 'pr-dependency-submission.yml']:
            workflow = self.docs[filename]
            steps = workflow['jobs']['submit']['steps']
            checkouts = [step for step in steps if step.get('uses', '').startswith('actions/checkout@')]
            self.assertEqual(len(checkouts), 1)
            self.assertEqual(checkouts[0]['with']['ref'], '${{ github.workflow_sha }}')
            self.assertFalse(checkouts[0]['with']['persist-credentials'])
            source = (ROOT / '.github/workflows' / filename).read_text()
            for forbidden in ['pull_request.head.sha }}', 'download-artifact', 'secrets.', 'cache@', 'workflow_dispatch:', 'workflow_run:']:
                if forbidden in ['workflow_dispatch:', 'workflow_run:']: continue
                self.assertNotIn(forbidden, source)
            self.assertIn('.result == "ACCEPTED" or .result == "SUCCESS"', source)
        source = (ROOT / '.github/workflows/dependency-submission.yml').read_text()
        self.assertIn('python3 -B Scripts/verify-recovery-run.py', source)
        source = (ROOT / '.github/workflows/pr-dependency-submission.yml').read_text()
        self.assertIn('--verify-package-resolved-transition', source)
        self.assertIn('PR moved while the snapshot was generated; not submitting.', source)
        self.assertIn('test "$pin_count" -eq "$snapshot_count"', source)

    def test_ready_changes_do_not_start_heavy_ci(self):
        trigger = self.docs['ci.yml'].get('on', self.docs['ci.yml'].get('true'))
        self.assertEqual(set(trigger['pull_request']['types']), {'opened','synchronize','reopened','edited','labeled','unlabeled'})
        self.assertNotIn('pull_request_target', trigger)
        # `edited` includes base retargeting: keep the original tree/diff refresh.
        self.assertIn('edited', trigger['pull_request']['types'])
        self.assertNotIn('ready_for_review', trigger['pull_request']['types'])

    def test_manual_release_publication_requires_boolean_opt_in_and_tag(self):
        workflow = self.docs['release.yml']
        trigger = workflow.get('on', workflow.get('true'))
        publish = trigger['workflow_dispatch']['inputs']['publish']
        self.assertEqual(publish['type'], 'boolean')
        self.assertIs(publish['default'], False)
        publication = workflow['jobs']['publish-release']
        self.assertEqual(set(publication['needs']), {'validate-release', 'validate-platform-builds'})
        condition = publication['if']
        for event in ['push', 'workflow_dispatch', 'pull_request']:
            for tag in [False, True]:
                for publish in [False, True]:
                    expression = condition.replace('github.event_name', repr(event)).replace('github.ref', repr('refs/tags/6.1.0' if tag else 'refs/heads/main')).replace('inputs.publish', repr(publish))
                    actual = eval(expression.replace('&&', ' and ').replace('||', ' or '), {'__builtins__':{}, 'startsWith':lambda value, prefix:value.startswith(prefix)})
                    self.assertEqual(actual, tag and (event == 'push' or event == 'workflow_dispatch' and publish))


if __name__ == '__main__': unittest.main()
