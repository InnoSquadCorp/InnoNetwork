"""One-at-a-time Dependabot rebase requests and the command-token boundary."""
from datetime import datetime, timedelta, timezone
import importlib.util
import os
from pathlib import Path
import re
import sys
import unittest
import urllib.error
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
        self.prs, self.comments, self.runs, self.posts = [], {}, {}, []
        # Activity is newest first; main moved to MAIN two hours ago.
        self.moves = {'refs/heads/main': [dict(after=MAIN, timestamp=stamp(MOVED)),
                                          dict(after=OLD, timestamp=stamp(MOVED - timedelta(days=1)))]}
        self.roles = {'maintainer': 'write', 'owner': 'admin', 'reader': 'read'}
        self.lookups = []

    def pr(self, number, base=OLD, author=BOT, draft=False, repo=p.REPOSITORY, ecosystem='npm_and_yarn'):
        head, ref = format(number, '040x'), f'dependabot/{ecosystem}/pr-{number}'
        self.prs.append(dict(number=number, user=author, draft=draft, base=dict(ref='main', sha=base),
                             head=dict(sha=head, ref=ref, repo=dict(full_name=repo))))
        self.moves['refs/heads/' + ref] = [dict(after=head, timestamp=stamp(NOW - timedelta(hours=1)))]
        return head

    def comment(self, number, body, at, login='maintainer', user=None, association='COLLABORATOR'):
        self.comments.setdefault(number, []).append(dict(body=body, created_at=stamp(at), author_association=association,
                                                         user=user or dict(login=login, id=7, type='User')))

    def run(self, number, status='completed', conclusion='success', updated=NOW - timedelta(hours=2), run_number=1):
        head = format(number, '040x')
        self.runs.setdefault(head, []).append(dict(
            display_title=f'CI validation v2 pr:{number} head:{head} base:{MAIN} source:{MAIN} release:true asan:false concurrency:false',
            status=status, conclusion=conclusion, updated_at=stamp(updated), run_number=run_number))

    def get(self, path):
        if path == p.route('commits/main'):
            # A commit date says nothing about when main moved; keep it misleading.
            return dict(sha=MAIN, commit=dict(committer=dict(date=stamp(MOVED - timedelta(hours=5)))))
        match = re.fullmatch(re.escape(p.route('activity?ref=')) + r'(.+)&per_page=100', path)
        if match:
            return list(self.moves.get(match[1], []))
        match = re.fullmatch(re.escape(p.route('collaborators/')) + r'([^/]+)/permission', path)
        assert match is not None, path
        self.lookups.append(match[1])
        if match[1] not in self.roles:
            raise urllib.error.HTTPError(path, 404, 'Not Found', {}, None)
        return dict(permission=self.roles[match[1]])

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

    def run_policy(self, enabled=True, command=True, owner='maintainer'):
        return r.run(self.api, self.command if command else None, lambda: owner, enabled, NOW)

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

    def test_latest_validation_run_decides_and_push_time_comes_from_the_move_record(self):
        self.api.pr(163)
        head = self.api.pr(164, base=MAIN)
        ref = 'refs/heads/dependabot/npm_and_yarn/pr-164'
        self.api.run(164, conclusion='failure', run_number=1)
        self.api.run(164, status='in_progress', conclusion=None, run_number=2)
        self.run_policy()
        self.assertEqual(self.command.posts, [])
        self.api.runs[head] = [dict(self.api.runs[head][1], display_title=f'CI metadata-only v1 pr:164 head:{head}')]
        self.api.moves[ref] = [dict(after=head, timestamp=stamp(NOW - timedelta(minutes=5)))]
        self.assertIn('waiting for CI to start', self.run_policy())
        for moves in ([dict(after=head, timestamp=stamp(NOW - timedelta(hours=1)))],
                      [dict(after=OLD, timestamp=stamp(NOW - timedelta(minutes=5)))], []):
            with self.subTest(moves=moves):
                self.command.posts.clear()
                self.api.moves[ref] = moves
                self.run_policy()
                self.assertRequested(163)

    def test_pending_push_capable_request_waits_then_expires_to_the_next_pr(self):
        self.api.pr(161)
        self.api.pr(163)
        self.api.comment(161, '@dependabot rebase', NOW - timedelta(minutes=10), login='owner')
        self.assertIn('#161 rebase requested', self.run_policy())
        self.assertEqual(self.command.posts, [])
        self.api.comments[161][0]['created_at'] = stamp(NOW - timedelta(minutes=61))
        self.run_policy()
        self.assertRequested(163)

    def test_commands_without_current_write_access_do_not_hold_the_queue(self):
        self.api.pr(161)
        # A MEMBER/COLLABORATOR association alone does not grant push access.
        self.api.comment(161, '@dependabot rebase', NOW - timedelta(minutes=5), login='reader', association='MEMBER')
        self.api.comment(161, '@dependabot rebase', NOW - timedelta(minutes=4), login='stranger')
        self.api.comment(161, '@dependabot recreate', NOW - timedelta(minutes=3), login='')
        self.api.comment(161, 'please @dependabot rebase', NOW - timedelta(minutes=2))
        self.run_policy()
        self.assertRequested(161)
        self.assertEqual(sorted(set(self.api.lookups)), ['maintainer', 'reader', 'stranger'])

    def test_commands_and_refusals_before_the_actual_main_move_belong_to_the_old_main(self):
        # After the misleading commit date but before main actually moved.
        self.api.pr(161)
        self.api.comment(161, '@dependabot rebase', MOVED - timedelta(minutes=30))
        self.api.comment(161, 'Sorry, only users with push access can use that command.', MOVED - timedelta(minutes=29),
                         user=BOT)
        self.run_policy()
        self.assertRequested(161)

    def test_missing_main_move_record_fails_closed(self):
        self.api.pr(161)
        self.api.moves['refs/heads/main'] = [dict(after=OLD, timestamp=stamp(MOVED))]
        with self.assertRaisesRegex(p.Rejected, 'no main move record'):
            self.run_policy()
        self.assertEqual(self.command.posts, [])

    def test_refusal_after_a_push_capable_command_skips_the_pr_without_waiting(self):
        self.api.pr(161)
        self.api.pr(163)
        self.api.comment(161, '@dependabot rebase', NOW - timedelta(minutes=10))
        self.api.comment(161, 'Sorry, only users with push access can use that command.', NOW - timedelta(minutes=9),
                         user=BOT)
        self.run_policy()
        self.assertRequested(163)

    def test_permission_lookup_errors_other_than_absence_fail_closed(self):
        self.api.pr(161)
        self.api.comment(161, '@dependabot rebase', NOW - timedelta(minutes=5))
        def forbidden(path):
            raise urllib.error.HTTPError(path, 403, 'Forbidden', {}, None)
        with mock.patch.object(self.api, 'get', side_effect=lambda path: forbidden(path) if '/collaborators/' in path
                               else FakeAPI.get(self.api, path)):
            with self.assertRaises(urllib.error.HTTPError) as raised:
                self.run_policy()
            raised.exception.close()
        self.assertEqual(self.command.posts, [])

    def test_command_token_owner_without_write_access_posts_nothing(self):
        self.api.pr(163)
        for owner in ('reader', 'stranger'):
            with self.subTest(owner=owner):
                self.assertIn('lacks write access', self.run_policy(owner=owner))
                self.assertEqual(self.command.posts, [])
        self.run_policy(owner='owner')
        self.assertRequested(163)

    def test_gradle_prs_await_a_human_replacement_and_never_hold_the_queue(self):
        # The oldest PR is a Gradle ticket that can never pass CI on its own.
        self.api.pr(160, ecosystem='gradle')
        self.api.pr(161, base=MAIN, ecosystem='gradle')
        self.api.run(161, status='in_progress', conclusion=None)
        self.api.pr(163)
        self.assertIn('#163', self.run_policy())
        self.assertRequested(163)
        self.command.posts.clear()
        self.api.prs = [pr for pr in self.api.prs if pr['number'] != 163]
        self.assertEqual(self.run_policy(), 'no behind Dependabot PR needs a rebase')
        self.assertEqual(self.command.posts, [])

    def test_only_same_repository_non_draft_dependabot_prs_are_moved(self):
        self.api.pr(150, author=dict(login='human', id=1, type='User'))
        self.api.pr(151, draft=True)
        self.api.pr(152, repo='fork/InnoNetwork')
        self.assertEqual(self.run_policy(), 'no behind Dependabot PR needs a rebase')
        self.assertEqual(self.command.posts, [])

    def test_standby_and_missing_command_token_post_nothing_or_look_up_the_owner(self):
        self.api.pr(163)
        owner = mock.Mock(side_effect=AssertionError('owner lookup needs a planned command'))
        self.assertIn('standby', r.run(self.api, self.command, owner, False, NOW))
        self.assertIn('not configured', r.run(self.api, None, owner, True, NOW))
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
