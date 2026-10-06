"""Native proof positive controls, stale/failing evidence and race regressions."""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('gate', ROOT / 'Scripts/verify-ci-metadata.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
HEAD, BASE, SOURCE = 'a' * 40, 'b' * 40, 'c' * 40
REPO = gate.CONFIG['repository']


class Transcript:
    def __init__(self):
        self.pr = dict(number=45, state='open', labels=[], head=dict(sha=HEAD),
                       base=dict(ref='main', sha=BASE, repo=dict(full_name=REPO)))
        self.event = dict(action='edited', pull_request=copy.deepcopy(self.pr), changes={})
        self.env = dict(GITHUB_REPOSITORY=REPO, GITHUB_EVENT_NAME='pull_request', GITHUB_REF='refs/pull/45/merge',
                        GITHUB_RUN_ID='20', GITHUB_RUN_ATTEMPT='1', GITHUB_SHA=SOURCE)
        self.run = dict(id=10, run_number=10, workflow_id=100, path=gate.CONFIG['workflow'], event='pull_request',
                        head_sha=HEAD, repository=dict(full_name=REPO), status='completed', conclusion='success',
                        run_attempt=1, check_suite_id=200,
                        display_title=f'CI validation v2 pr:45 head:{HEAD} base:{BASE} source:{SOURCE} release:false asan:false concurrency:false')
        self.own = {**self.run, 'id':20, 'run_number':20, 'status':'in_progress', 'conclusion':None,
                    'display_title':gate.METADATA_PREFIX+'current'}
        self.merge = dict(sha=SOURCE, tree=dict(sha='e'*40), parents=[dict(sha=BASE),dict(sha=HEAD)])
        self.validated_merge = None
        self.runs = [self.run,self.own]
        self.jobs,self.checks = [],{}
        for i,name in enumerate(gate.CONFIG['checks']):
            job = dict(id=300+i, name=name, run_id=10, run_attempt=1, head_sha=HEAD, status='completed', conclusion='success',
                       completed_at=(datetime.now(timezone.utc)-timedelta(hours=1)).isoformat(),
                       steps=[dict(name='Require all planned results',conclusion='success'),dict(name=gate.VERIFY_STEP,conclusion='skipped')],
                       check_run_url=f'https://api.github.com/repos/{REPO}/check-runs/{400+i}')
            self.jobs.append(job)
            self.checks[400+i] = dict(name=name,app=dict(id=15368),check_suite=dict(id=200),head_sha=HEAD,
                                      status='completed',conclusion='success',details_url=f'https://github.com/{REPO}/actions/runs/10/job/{300+i}')
        self.reads,self.pages_read=0,0
        self.run_race,self.pr_race,self.list_race=None,None,None
        self.main, self.final_main, self.main_reads = BASE, BASE, 0
        self.main_error = None

    def get(self,path):
        if path.endswith('git/ref/heads/main'):
            self.main_reads += 1
            if self.main_error:
                raise self.main_error
            return dict(object=dict(sha=self.main if self.main_reads == 1 else self.final_main))
        if path.endswith('pulls/45'):
            self.reads+=1
            result=copy.deepcopy(self.pr)
            if self.reads==2 and self.pr_race:self.pr_race(result)
            return result
        if path.endswith('actions/runs/20'):return copy.deepcopy(self.own)
        if path.endswith('actions/runs/10'):
            result=copy.deepcopy(self.run)
            if self.reads==1 and getattr(self,'run_read',False) and self.run_race:self.run_race(result)
            self.run_read=True
            return result
        if '/git/commits/' in path:
            return copy.deepcopy(self.validated_merge if self.validated_merge and path.endswith(self.validated_merge['sha']) else self.merge)
        if '/check-runs/' in path:return copy.deepcopy(self.checks[int(path.rsplit('/',1)[1])])
        if '/actions/runs/' in path:
            return copy.deepcopy(next(r for r in self.runs if r['id']==int(path.rsplit('/',1)[1])))
        raise AssertionError(path)

    def pages(self,path,key):
        if key=='workflow_runs':
            assert 'event=' not in path, 'newer manual validation must not be hidden by an event filter'
            self.pages_read+=1
            result=copy.deepcopy(self.runs)
            if self.pages_read==2 and self.list_race:self.list_race(result)
            return result
        if key=='jobs':return copy.deepcopy(self.jobs)
        raise AssertionError(path)

    def prove(self):
        return gate.prove(self,self.event,self.env)


class MetadataGateTests(unittest.TestCase):
    def test_current_success_is_read_only_and_bound(self):
        t=Transcript();proof=t.prove()
        self.assertEqual(proof,dict(run=10,attempt=1,head=HEAD,base=BASE,source=SOURCE,check='CI Required'))
        self.assertEqual(t.main_reads, 2)
        for name in gate.CONFIG['checks']:
            t=Transcript();self.assertEqual(gate.prove(t,t.event,t.env,name)['check'],name)

    def test_regenerated_merge_requires_exact_tree_and_ordered_parents(self):
        def regenerated():
            t = Transcript()
            old = 'd' * 40
            t.run['display_title'] = t.run['display_title'].replace(SOURCE, old)
            t.validated_merge = {**copy.deepcopy(t.merge), 'sha': old}
            t.checks[400]['head_sha'] = old
            return t
        self.assertEqual(regenerated().prove()['run'], 10)
        mutations = [lambda t: t.validated_merge['tree'].update(sha='f'*40),
                     lambda t: t.validated_merge['parents'].reverse(),
                     lambda t: t.validated_merge.update(parents=[]),
                     lambda t: t.merge.pop('tree'),
                     lambda t: t.merge['tree'].update(sha=None),
                     lambda t: t.validated_merge.pop('tree'),
                     lambda t: t.checks[400].update(head_sha=SOURCE)]
        for mutate in mutations:
            t = regenerated(); mutate(t)
            with self.assertRaises(ValueError): t.prove()

    def test_failed_pending_cancelled_or_missing_validation_cannot_turn_green(self):
        for state,result in [('completed','failure'),('completed','cancelled'),('in_progress',None),('queued',None),('completed','skipped')]:
            t=Transcript();t.run.update(status=state,conclusion=result)
            with self.subTest(state=state,result=result),self.assertRaises(ValueError):t.prove()
        t=Transcript();t.runs=[t.own]
        with self.assertRaises(ValueError):t.prove()

    def test_newest_real_failure_is_not_hidden_by_older_success_or_metadata(self):
        t=Transcript();t.runs.append({**t.run,'id':9,'run_number':9,'conclusion':'success'});t.run['conclusion']='failure'
        t.runs.append({**t.own,'id':19,'run_number':19,'status':'completed','conclusion':'success'})
        with self.assertRaises(ValueError):t.prove()

    def test_head_base_label_workflow_and_native_check_mismatches_reject(self):
        mutations=[lambda t:t.env.update(GITHUB_EVENT_NAME='workflow_dispatch'),
                   lambda t:t.env.update(GITHUB_REPOSITORY='foreign/repo'),
                   lambda t:t.env.update(GITHUB_REF='refs/heads/main'),
                   lambda t:t.pr['head'].update(sha='d'*40),lambda t:t.pr['base'].update(sha='d'*40),
                   lambda t:t.pr.update(labels=[dict(name='release-validation')]),lambda t:t.pr.update(state='closed'),
                   lambda t:t.run.update(display_title=t.run['display_title'].replace(BASE,'d'*40)),
                   lambda t:t.run.update(display_title=t.run['display_title'].replace('release:false','release:true')),
                   lambda t:t.run.update(display_title=t.run['display_title'].replace(SOURCE,'d'*40)),
                   lambda t:t.run.update(workflow_id=999),lambda t:t.run.update(event='push'),
                   lambda t:t.run.update(event='workflow_dispatch'),
                   lambda t:t.merge['parents'].reverse(),lambda t:t.jobs.clear(),
                   lambda t:t.jobs.append(copy.deepcopy(t.jobs[0])),lambda t:t.jobs[0].update(conclusion='skipped'),
                   lambda t:t.jobs[0]['steps'][0].update(conclusion='skipped'),
                   lambda t:t.jobs[0]['steps'][1].update(conclusion='success'),
                   lambda t:t.jobs[0].update(check_run_url='https://example.invalid/400'),
                   lambda t:t.checks[400]['app'].update(id=999),lambda t:t.checks[400].update(head_sha='d'*40),
                   lambda t:t.checks[400]['check_suite'].update(id=999),lambda t:t.checks[400].update(conclusion='failure')]
        for index,mutate in enumerate(mutations):
            t=Transcript();mutate(t)
            with self.subTest(index=index),self.assertRaises(ValueError):t.prove()

    def test_rerun_new_validation_and_pr_races_reject(self):
        mutations=[lambda t:setattr(t,'run_race',lambda r:r.update(run_attempt=2)),
                   lambda t:setattr(t,'pr_race',lambda p:p['base'].update(sha='d'*40)),
                   lambda t:setattr(t,'list_race',lambda runs:runs.append({**t.run,'id':21,'run_number':21}))]
        for mutate in mutations:
            t=Transcript();mutate(t)
            with self.assertRaises(ValueError):t.prove()

    def test_cached_pr_base_cannot_hide_authoritative_main_drift(self):
        for field in ('main', 'final_main'):
            t = Transcript()
            setattr(t, field, 'd' * 40)
            # Both PR reads keep returning the old base and head.
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'current main moved'):
                t.prove()

    def test_unavailable_or_malformed_main_fails_closed(self):
        for field in ('main', 'final_main'):
            for value in (None, 123, '', 'main', 'a' * 39, 'A' * 40):
                t = Transcript()
                setattr(t, field, value)
                with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'current main SHA'):
                    t.prove()
        t = Transcript()
        t.main_error = PermissionError('main lookup denied')
        with self.assertRaises(PermissionError):
            t.prove()

    def test_equal_sha_retarget_or_foreign_repository_cannot_reuse_validation(self):
        mutations = (lambda p: p['base'].update(ref='develop'),
                     lambda p: p['base'].pop('ref'),
                     lambda p: p['base']['repo'].update(full_name='foreign/repo'))
        for mutation in mutations:
            for phase in ('initial', 'final'):
                t = Transcript()
                if phase == 'initial':
                    mutation(t.pr)
                else:
                    t.pr_race = mutation
                with self.subTest(phase=phase, mutation=mutation), self.assertRaisesRegex(ValueError, 'target this repository main'):
                    t.prove()

    def test_only_unrelated_labels_and_description_edits_can_revalidate(self):
        for action in ['opened','synchronize','reopened','closed']:
            t=Transcript();t.event['action']=action
            with self.assertRaises(ValueError):t.prove()
        t=Transcript();t.event['changes']={'base':{'ref':{'from':'develop'}}}
        with self.assertRaises(ValueError):t.prove()
        for label in gate.CONFIG['labels']:
            for action in ['labeled','unlabeled']:
                t=Transcript();t.event.update(action=action,label=dict(name=label.upper()))
                with self.assertRaises(ValueError):t.prove()
        for action in ['labeled','unlabeled']:
            t=Transcript();t.event.update(action=action,label=dict(name='documentation'))
            self.assertEqual(t.prove()['run'],10)

    def test_stale_future_and_unzoned_completion_cannot_refresh_required_ci(self):
        for delta in [timedelta(hours=-25), timedelta(hours=1)]:
            t=Transcript();t.jobs[0]['completed_at']=(datetime.now(timezone.utc)+delta).isoformat()
            with self.subTest(delta=delta),self.assertRaises(ValueError):t.prove()
        t=Transcript();t.jobs[0]['completed_at']='2026-10-03T01:00:00'
        with self.assertRaises(ValueError):t.prove()

    def test_shared_head_is_scoped_to_verified_pr_associations(self):
        t=Transcript()
        other={**t.run, 'id':21, 'run_number':21, 'pull_requests':[dict(number=46)],
               'display_title':t.run['display_title'].replace('pr:45 ', 'pr:46 ')}
        t.runs.append(other)
        self.assertEqual(t.prove()['run'],10)
        t=Transcript();t.list_race=lambda runs:runs.append(other)
        self.assertEqual(t.prove()['run'],10)
        for associations in [None,[],[dict(number=45),dict(number=46)],[dict(number='46')]]:
            t=Transcript();t.runs.append({**other,'pull_requests':associations})
            with self.subTest(associations=associations),self.assertRaises(ValueError):t.prove()
