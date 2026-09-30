"""Adversarial current-main recovery wake verification, with no mutation path."""
import copy
import importlib.util
from pathlib import Path
import unittest
from test_dependabot_merge_policy import Transcript, BASE, NUMBER, RUN

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('recovery', ROOT / 'Scripts/verify-recovery-run.py')
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)


def source():
    api = Transcript()
    api.pr.update(state='closed', merged=True, merge_commit_sha=BASE)
    api.run.update(event='workflow_dispatch', head_sha=BASE, head_branch='main',
                   display_title=p.p.PREFIX+str(NUMBER))
    api.run['head_repository'] = dict(api.repo)
    return api, {'workflow_run':copy.deepcopy(api.run)}


class RecoveryTests(unittest.TestCase):
    def test_verified_bot_current_main_wake(self):
        api,event=source(); p.verify(api,event,BASE);self.assertEqual(api.mutations,[])

    def test_stale_foreign_non_bot_or_unmerged_wake_rejected(self):
        changes=[lambda a:a.run.update(run_attempt=2), lambda a:a.run.update(path='.github/workflows/release.yml'),
                 lambda a:a.run.update(event='push'), lambda a:a.run.update(head_branch='topic'),
                 lambda a:a.run.update(display_title='CI'), lambda a:a.run.update(head_sha='f'*40),
                 lambda a:a.run['repository'].update(full_name='other/repo'),
                 lambda a:a.run['head_repository'].update(id=99),
                 lambda a:a.pr.update(merged=False), lambda a:a.pr['user'].update(id=99),
                 lambda a:a.pr.update(merge_commit_sha='f'*40), lambda a:setattr(a,'base','f'*40)]
        for change in changes:
            with self.subTest(change=change):
                api,event=source();change(api)
                with self.assertRaises(ValueError):p.verify(api,event,BASE)
                self.assertEqual(api.mutations,[])
