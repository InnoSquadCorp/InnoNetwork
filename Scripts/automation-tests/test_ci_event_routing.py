"""Exercise the actual native admission expressions, including their negative paths."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def condition(source, job):
    block = source.split('\n  ' + job + ':\n', 1)[1]
    block = re.split(r'\n  [\w-]+:\n', block, maxsplit=1)[0]
    found = re.search(r'^    if: (.+)(?:\n|$)', block, re.M)
    value = found[1]
    if value == '>-':
        value = ' '.join(re.match(r'(?:      .*\n)+', block[found.end():])[0].split())
    return value.removeprefix('${{ ').removesuffix(' }}')


class GitHubString(str):
    # GitHub compares strings case-insensitively. Use its documented semantics
    # for these string-only predicates, not Python's default string equality.
    def __eq__(self, other):
        if not isinstance(other, str):
            return NotImplemented
        return self.lower() == other.lower()

    def __ne__(self, other):
        equal = self.__eq__(other)
        return NotImplemented if equal is NotImplemented else not equal


def expression_value(expression, values):
    values = {'vars.INNO_JOB_CANCELLATION': '', 'github.run_attempt': 1, **values}
    for key in sorted(values, key=len, reverse=True):
        value = repr(values[key])
        expression = expression.replace(key, 'string(' + value + ')' if isinstance(values[key], str) else value)
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'\bfalse\b', 'False', expression)
    expression = re.sub(r'\btrue\b', 'True', expression)
    expression = re.sub(r'!(?!=)', ' not ', expression).replace('always()', 'True')
    return eval(expression.strip(), {'__builtins__': {}, 'string': GitHubString,
                                    'format': lambda value, *args: value.format(*args),
                                    'contains': lambda values, item: any(str(value).lower() == item.lower() for value in values),
                                    'startsWith': lambda value, prefix: value.lower().startswith(prefix.lower())})


def evaluate(expression, values):
    return bool(expression_value(expression, values))


class PRMetadataAdmissionTests(unittest.TestCase):
    def test_metadata_queues_and_revalidates_a_fixed_required_context(self):
        source = (ROOT / '.github/workflows/ci.yml').read_text()
        title = source.split('run-name: >-\n', 1)[1].split('\non:', 1)[0].strip()[3:-3]
        concurrency = source.split('  group: ci-${{ github.workflow }}-${{ ', 1)[1].split(' }}', 1)[0]
        required = source.split('  ci-required:\n', 1)[1]
        self.assertIn('    name: CI Required\n', required)
        cancel = source.split('  cancel-in-progress: ${{ ', 1)[1].split(' }}', 1)[0]
        queue = source.split('  queue: ${{ ', 1)[1].split(' }}', 1)[0]
        gate = required.split('      - name: Verify prior validation for metadata\n', 1)[1]
        gate_condition = gate.split('        if: ${{ ', 1)[1].split(' }}', 1)[0]
        for action, label, base, ignored in [
                ('opened', '', '', False), ('synchronize', '', '', False), ('reopened', '', '', False),
                ('labeled', 'release-validation', '', False), ('unlabeled', 'release-validation', '', False),
                ('labeled', 'Release-Validation', '', False), ('unlabeled', 'RELEASE-VALIDATION', '', False),
                ('labeled', 'concurrency-review', '', False), ('unlabeled', 'CONCURRENCY-REVIEW', '', False),
                ('labeled', 'documentation', '', True), ('unlabeled', 'bug', '', True),
                ('labeled', '', '', False), ('edited', '', '', True),
                ('edited', '', {'ref': {'from': 'develop'}}, False)]:
            values = {'vars.INNO_JOB_CANCELLATION': 'disabled', 'github.event_name': 'pull_request', 'github.event.action': action,
                      'github.event.label.name': label, 'github.event.changes.base': base,
                      'github.event.pull_request.number': 45, 'github.event.pull_request.head.sha': 'a' * 40,
                      'github.event.pull_request.base.sha': 'b' * 40, 'github.workflow_sha': 'c' * 40,
                      'github.event.pull_request.labels.*.name': [], 'github.sha': 'c' * 40, 'github.run_id': 123, 'github.ref': 'refs/pull/45/merge', 'inputs.dependabot_merge_pr': ''}
            with self.subTest(action=action, label=label, base=base):
                self.assertEqual(evaluate(condition(source, 'ci-plan'), values), not ignored)
                self.assertTrue(evaluate(condition(source, 'ci-required'), values))
                self.assertEqual(evaluate(gate_condition, values), ignored)
                self.assertEqual(evaluate(cancel, values), not ignored)
                self.assertEqual(expression_value(queue, values), 'max' if ignored else 'single')
                consumer = condition(source, 'consumer-smoke').replace('fromJSON(needs.ci-plan.outputs.plan).jobs.consumer-smoke', 'True')
                self.assertEqual(evaluate(consumer, values), not ignored)
                self.assertEqual(expression_value(title, values).startswith('CI metadata-only v1 '), ignored)
                self.assertEqual(expression_value(concurrency, values), 45)
        for event in ['push', 'merge_group', 'workflow_dispatch']:
            values.update({'github.event_name': event, 'github.event.action': 'edited', 'github.event.changes.base': ''})
            self.assertTrue(evaluate(condition(source, 'ci-plan'), values))
            self.assertEqual(expression_value(queue, values), 'single')
            self.assertTrue(evaluate(cancel, values))
            self.assertTrue(evaluate(condition(source, 'ci-required'), values))

    def test_metadata_runs_allocate_no_other_runner(self):
        import test_dependabot_merge_policy as bot
        source = (ROOT / '.github/workflows/ci.yml').read_text()
        jobs = bot.workflow_jobs(source)
        for key, job in jobs.items():
            if key in {'ci-plan', 'ci-required', 'consumer-smoke'}:
                continue
            self.assertRegex(job['block'], r'    needs: (?:ci-plan|\[ci-plan[,\]])')
            self.assertNotIn('always()', job['block'].split('    steps:', 1)[0])


class CoordinatorAdmissionTests(unittest.TestCase):
    def test_main_ci_notifications_are_filtered_without_losing_pr_invalidations(self):
        source = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        expr = condition(source, 'inspect')
        trusted = {'github.repository': 'InnoSquadCorp/InnoNetwork', 'github.ref': 'refs/heads/main',
                   'github.workflow_ref': 'InnoSquadCorp/InnoNetwork/.github/workflows/dependabot-auto-merge.yml@refs/heads/main'}
        for event in ['push', 'schedule', 'workflow_dispatch', 'pull_request_target', 'workflow_run']:
            for path in ['.github/workflows/ci.yml', '.github/workflows/dependabot-ready.yml', '.github/workflows/dependabot-review-notice.yml']:
                for original in ['pull_request', 'push', 'workflow_dispatch', 'merge_group', 'pull_request_target']:
                    values = {**trusted, 'github.event_name': event, 'github.event.workflow_run.path': path,
                              'github.event.workflow_run.event': original}
                    expected = not (event == 'workflow_run' and path.endswith('/ci.yml') and original != 'pull_request')
                    self.assertEqual(evaluate(expr, values), expected)
                    for key in trusted:
                        self.assertFalse(evaluate(expr, {**values, key: 'untrusted'}))

    def test_empty_ready_targets_do_not_suppress_post_merge_recovery(self):
        source = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        expr = condition(source, 'ready-plan')
        for result in ['success', 'failure', 'cancelled', 'skipped']:
            for event in ['pull_request_target', 'workflow_run', 'push', 'schedule', 'workflow_dispatch']:
                for targets in ['', '[]', '[45]']:
                    actual = evaluate(expr, {'needs.inspect.result': result, 'needs.bot-ready.result': 'success', 'github.event_name': event,
                                             'needs.inspect.outputs.prs': targets, 'github.repository': 'InnoSquadCorp/InnoNetwork',
                                             'github.ref': 'refs/heads/main', 'github.workflow_ref': 'InnoSquadCorp/InnoNetwork/.github/workflows/dependabot-auto-merge.yml@refs/heads/main'})
                    self.assertEqual(actual, result == 'success' and event != 'pull_request_target' and targets == '[45]')
        self.assertIn('    needs: [inspect, bot-ready]', source.split('  ready-plan:\n', 1)[1].split('  ready-refresh:\n', 1)[0])
        for bot_result in ['cancelled', '', 'unknown']:
            self.assertFalse(evaluate(expr, {'needs.inspect.result': 'success', 'needs.bot-ready.result': bot_result,
                'github.event_name': 'workflow_run', 'needs.inspect.outputs.prs': '[45]',
                'github.repository': 'InnoSquadCorp/InnoNetwork', 'github.ref': 'refs/heads/main',
                'github.workflow_ref': 'InnoSquadCorp/InnoNetwork/.github/workflows/dependabot-auto-merge.yml@refs/heads/main'}))
        recovery = condition(source, 'post-merge-plan')
        self.assertNotIn('needs.inspect.outputs.prs', recovery)
        for event in ['push', 'schedule', 'workflow_dispatch']:
            self.assertIn("github.event_name == '" + event + "'", recovery)


    def test_failed_bot_matrix_allows_independent_plan_and_receipt_verified_refresh(self):
        source = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        values = {'needs.inspect.result': 'success', 'needs.ready-plan.result': 'success',
                  'needs.inspect.outputs.prs': '[45,46]', 'needs.ready-plan.outputs.targets': '[{"pr":45}]',
                  'github.repository': 'InnoSquadCorp/InnoNetwork', 'github.ref': 'refs/heads/main',
                  'github.workflow_ref': 'InnoSquadCorp/InnoNetwork/.github/workflows/dependabot-auto-merge.yml@refs/heads/main',
                  'github.event_name': 'workflow_run'}
        for job in ('ready-plan', 'ready-refresh'):
            expr = condition(source, job)
            for result in ('success', 'skipped', 'failure', 'cancelled', '', 'unknown'):
                with self.subTest(job=job, bot_result=result):
                    self.assertEqual(evaluate(expr, {**values, 'needs.bot-ready.result': result}),
                                     result in {'success', 'skipped', 'failure'})
            allowed = {**values, 'needs.bot-ready.result': 'failure'}
            for field, invalid in (('needs.inspect.result', 'failure'), ('github.ref', 'refs/heads/untrusted'),
                                   ('github.workflow_ref', 'untrusted'), ('github.repository', 'untrusted'),
                                   ('github.event_name', 'pull_request_target')):
                with self.subTest(job=job, field=field):
                    self.assertFalse(evaluate(expr, {**allowed, field: invalid}))
            field = 'needs.inspect.outputs.prs' if job == 'ready-plan' else 'needs.ready-plan.outputs.targets'
            for empty in ('', '[]'):
                self.assertFalse(evaluate(expr, {**allowed, field: empty}))
        for result in ('failure', 'cancelled', 'skipped'):
            self.assertFalse(evaluate(condition(source, 'ready-refresh'),
                                      {**values, 'needs.bot-ready.result': 'failure', 'needs.ready-plan.result': result}))
