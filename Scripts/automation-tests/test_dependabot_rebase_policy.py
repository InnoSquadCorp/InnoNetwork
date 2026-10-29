"""One-at-a-time Dependabot rebase requests and the command-token boundary."""
from datetime import datetime, timedelta, timezone
import importlib.util
import os
from pathlib import Path
import re
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('rebase_policy', ROOT / 'Scripts/dependabot-rebase-policy.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
p = r.p

MAIN, OLD = 'a' * 40, 'b' * 40
NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)
MOVED = NOW - timedelta(hours=2)
BOT = dict(p.BOT)


def stamp(value):
    return value.strftime('%Y-%m-%dT%H:%M:%SZ')


class FakeAPI:
    def __init__(self):
        self.prs, self.comments, self.runs, self.commits, self.posts = [], {}, {}, {}, []

    def pr(self, number, base=OLD, author=BOT, draft=False, repo=p.REPOSITORY):
        head = format(number, '040x')
        self.prs.append(dict(number=number, user=author, draft=draft, base=dict(ref='main', sha=base),
                             head=dict(sha=head, repo=dict(full_name=repo))))
        self.commits[head] = stamp(NOW - timedelta(hours=1))
        return head

    def comment(self, number, body, at, association='COLLABORATOR', user=None):
        self.comments.setdefault(number, []).append(dict(body=body, created_at=stamp(at), author_association=association,
                                                         user=user or dict(login='maintainer', id=7, type='User')))

    def run(self, number, status='completed', conclusion='success', updated=NOW - timedelta(hours=2), run_number=1):
        head = format(number, '040x')
        self.runs.setdefault(head, []).append(dict(
            display_title=f'CI validation v2 pr:{number} head:{head} base:{MAIN} source:{MAIN} release:true asan:false concurrency:false',
            status=status, conclusion=conclusion, updated_at=stamp(updated), run_number=run_number))

    def get(self, path):
        if path == p.route('commits/main'):
            return dict(sha=MAIN, commit=dict(committer=dict(date=stamp(MOVED))))
        sha = path.rsplit('/', 1)[1]
        return dict(sha=sha, commit=dict(committer=dict(date=self.commits[sha])))

    def pages(self, path, key=None):
        if path == p.route('pulls?state=open&base=main'):
            return list(self.prs)
        match = re.fullmatch(re.escape(p.route('issues/')) + r'(\d+)/comments', path)
        if match:
            return list(self.comments.get(int(match[1]), []))
        match = re.fullmatch(re.escape(p.route('actions/workflows/ci.yml/runs?event=pull_request&head_sha=')) + r'([0-9a-f]{40})', path)
        assert match is not None and key == 'workflow_runs', path
        return list(self.runs.get(match[1], []))

    def mutate(self, method, path, payload):
        self.posts.append((method, path, payload))


class RebasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.api, self.command = FakeAPI(), FakeAPI()

    def run_policy(self, enabled=True, command=True):
        return r.run(self.api, self.command if command else None, enabled, NOW)

    def assertRequested(self, number):
        self.assertEqual(self.command.posts, [('POST', p.route(f'issues/{number}/comments'), {'body': '@dependabot rebase'})])
        self.assertEqual(self.api.posts, [], 'the read-only job token must never post the command')

    def test_oldest_behind_pr_is_requested_with_the_command_token_only(self):
        for number in (170, 163, 165):
            self.api.pr(number)
        self.assertIn('#163', self.run_policy())
        self.assertRequested(163)

    def test_one_pr_in_flight_holds_every_other_request(self):
        self.api.pr(163)
        self.api.pr(164, base=MAIN)
        for state in [dict(status='in_progress', conclusion=None), dict(status='queued', conclusion=None),
                      dict(conclusion='success', updated=NOW - timedelta(minutes=5))]:
            with self.subTest(state=state):
                self.api.runs.clear(); self.command.posts.clear()
                self.api.run(164, **state)
                self.assertIn('#164', self.run_policy())
                self.assertEqual(self.command.posts, [])

    def test_failed_or_stalled_current_pr_releases_the_queue(self):
        self.api.pr(163)
        self.api.pr(164, base=MAIN)
        for state in [dict(conclusion='failure'), dict(conclusion='cancelled'),
                      dict(conclusion='success', updated=NOW - timedelta(hours=2))]:
            with self.subTest(state=state):
                self.api.runs.clear(); self.command.posts.clear()
                self.api.run(164, **state)
                self.run_policy()
                self.assertRequested(163)

    def test_latest_validation_run_decides_and_foreign_titles_are_ignored(self):
        self.api.pr(163)
        head = self.api.pr(164, base=MAIN)
        self.api.run(164, conclusion='failure', run_number=1)
        self.api.run(164, status='in_progress', conclusion=None, run_number=2)
        self.run_policy()
        self.assertEqual(self.command.posts, [])
        self.api.runs[head] = [dict(self.api.runs[head][1], display_title=f'CI metadata-only v1 pr:164 head:{head}')]
        self.api.commits[head] = stamp(NOW - timedelta(minutes=5))
        self.assertIn('waiting for CI to start', self.run_policy())
        self.api.commits[head] = stamp(NOW - timedelta(hours=1))
        self.run_policy()
        self.assertRequested(163)

    def test_pending_trusted_request_waits_then_expires_to_the_next_pr(self):
        self.api.pr(161)
        self.api.pr(163)
        self.api.comment(161, '@dependabot rebase', NOW - timedelta(minutes=10))
        self.assertIn('#161 rebase requested', self.run_policy())
        self.assertEqual(self.command.posts, [])
        self.api.comments[161][0]['created_at'] = stamp(NOW - timedelta(minutes=61))
        self.run_policy()
        self.assertRequested(163)

    def test_untrusted_or_pre_merge_commands_do_not_hold_the_queue(self):
        self.api.pr(161)
        self.api.comment(161, '@dependabot rebase', NOW - timedelta(minutes=5), association='NONE')
        self.api.comment(161, '@dependabot rebase', MOVED - timedelta(minutes=1))
        self.api.comment(161, 'please @dependabot rebase', NOW - timedelta(minutes=5))
        self.run_policy()
        self.assertRequested(161)

    def test_refusal_skips_the_pr_without_waiting(self):
        self.api.pr(161)
        self.api.pr(163)
        self.api.comment(161, '@dependabot rebase', NOW - timedelta(minutes=10))
        self.api.comment(161, 'Sorry, only users with push access can use that command.', NOW - timedelta(minutes=9),
                         association='NONE', user=BOT)
        self.run_policy()
        self.assertRequested(163)

    def test_only_same_repository_non_draft_dependabot_prs_are_moved(self):
        self.api.pr(150, author=dict(login='human', id=1, type='User'))
        self.api.pr(151, draft=True)
        self.api.pr(152, repo='fork/InnoNetwork')
        self.assertEqual(self.run_policy(), 'no behind Dependabot PR needs a rebase')
        self.assertEqual(self.command.posts, [])

    def test_standby_and_missing_command_token_post_nothing(self):
        self.api.pr(163)
        self.assertIn('standby', self.run_policy(enabled=False))
        self.assertIn('not configured', self.run_policy(command=False))
        self.assertEqual(self.command.posts, [])
        self.assertEqual(self.api.posts, [])

    def test_cli_requires_the_trusted_default_main_workflow(self):
        trusted = dict(GITHUB_REPOSITORY=p.REPOSITORY, GITHUB_REF='refs/heads/main',
                       GITHUB_WORKFLOW_REF=r.WORKFLOW_REF, GH_TOKEN='token')
        for key, value in [('GITHUB_REF', 'refs/heads/feature'), ('GITHUB_REPOSITORY', 'fork/InnoNetwork'),
                           ('GITHUB_WORKFLOW_REF', p.REPOSITORY + '/.github/workflows/ci.yml@refs/heads/main')]:
            with self.subTest(key=key), mock.patch.dict(os.environ, {**trusted, key: value}, clear=True), \
                    mock.patch.object(p.GitHub, 'request', side_effect=AssertionError('no API call')):
                self.assertEqual(self.cli('run'), 1)

    def cli(self, command):
        with mock.patch.object(sys, 'argv', ['dependabot-rebase-policy.py', command]):
            return r.main()

    def test_workflow_runs_the_policy_only_from_trusted_main_when_enabled(self):
        # Token boundaries are enforced by Scripts/check-public-operations.py.
        source = (ROOT / '.github/workflows/dependabot-rebase.yml').read_text()
        self.assertIn("github.workflow_ref == '" + r.WORKFLOW_REF + "'", source)
        self.assertIn("vars.DEPENDABOT_AUTO_MERGE_ENABLED == 'true'", source)
        self.assertIn("github.event.workflow_run.event == 'pull_request'", source)
        self.assertIn('run: python3 -B Scripts/dependabot-rebase-policy.py run', source)


if __name__ == '__main__':
    unittest.main()
