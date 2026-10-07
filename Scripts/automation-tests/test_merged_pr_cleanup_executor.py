import copy
import importlib.util
from pathlib import Path
import unittest
import urllib.error
spec=importlib.util.spec_from_file_location('cleanup_executor',Path(__file__).resolve().parents[1]/'merged_pr_cleanup.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class FakeAPI:
 def __init__(self,repo,pr,runs):self.repo=repo;self.pr=pr;self.runs=runs;self.calls=[];self.pages=None;self.mutate=None;self.posts=0;self.failure=None
 def request(self,method,path):
  self.calls.append((method,path))
  if self.mutate:self.mutate(self,method,path)
  if method=='POST':
   self.posts+=1
   if self.failure:raise self.failure
   return {}
  if '/pulls/' in path:return copy.deepcopy(self.pr)
  if '?' in path:
   page=int(path.split('page=')[-1]);rows=self.pages[page-1] if self.pages else self.runs
   return {'total_count':sum(map(len,self.pages)) if self.pages else len(self.runs),'workflow_runs':copy.deepcopy(rows)}
  if '/actions/runs/' in path:return copy.deepcopy(next(r for r in self.runs if str(r['id'])==path.rsplit('/',1)[1]))
  return copy.deepcopy(self.repo)
class CleanupExecutorTests(unittest.TestCase):
 def test_actual_default_on_handler_retains_trust_and_disable_boundaries(self):
  from test_ci_event_routing import condition,expression_value
  root=Path(__file__).resolve().parents[2];text=(root/'.github/workflows/merged-pr-cleanup.yml').read_text()
  trusted={'github.event.pull_request.merged':True,'github.repository':'InnoSquadCorp/InnoNetwork','github.ref':'refs/heads/main','github.event.repository.default_branch':'main','github.workflow_ref':'InnoSquadCorp/InnoNetwork/.github/workflows/merged-pr-cleanup.yml@refs/heads/main'}
  for value in ['','enabled','ENABLED','disabled','false','unknown']:
   values={**trusted,'vars.INNO_MERGED_PR_CLEANUP':value};active=value.lower() in ('','enabled')
   self.assertEqual(bool(expression_value(condition(text,'cleanup'),values)),active)
   self.assertEqual(bool(expression_value(condition(text,'inspect'),values)),not active)
   for key in trusted:
    if key=='github.event.repository.default_branch':continue
    bad={**values,key:False if key=='github.event.pull_request.merged' else 'untrusted'}
    self.assertFalse(expression_value(condition(text,'cleanup'),bad))
 def setUp(self):
  self.repo={'full_name':'Org/Repo','id':1,'default_branch':'main'};self.sha='a'*40;source='b'*40
  self.pr={'number':42,'state':'closed','merged':True,'created_at':'2026-01-01T00:00:00Z','merged_at':'2026-01-02T00:00:00Z','head':{'sha':self.sha},'base':{'repo':{'id':1}}}
  self.event={'action':'closed','number':42,'repository':self.repo,'pull_request':copy.deepcopy(self.pr)}
  self.context={'event_name':'pull_request_target','repository':'Org/Repo','ref':'refs/heads/main','workflow_ref':'Org/Repo/.github/workflows/merged-pr-cleanup.yml@refs/heads/main','source_sha':source,'checkout_sha':source,'enable_writes':'enabled'}
  self.config={'schema':1,'repository':'Org/Repo','status':'reviewed-cleanup-policy-v1','merged_pr_pull_request_workflow_allowlist':['.github/workflows/ci.yml']}
  run={'id':100,'run_attempt':1,'created_at':'2026-01-01T12:00:00Z','run_started_at':'2026-01-01T12:01:00Z','repository':self.repo,'event':'pull_request','status':'queued','conclusion':None,'head_sha':self.sha,'path':'.github/workflows/ci.yml','pull_requests':[copy.deepcopy(self.pr)]}
  self.api=FakeAPI(self.repo,self.pr,[run])
 def execute(self,apply=False):return m.execute(self.event,self.context,self.config,self.api,apply)
 def test_default_dry_run_only_reads(self):
  result=self.execute();self.assertTrue(result['dry_run']);self.assertEqual(self.api.posts,0);self.assertEqual(len(result['candidates']),1)
 def test_apply_requires_canonical_write_intent_and_fresh_rechecks(self):
  self.context['enable_writes']='';
  with self.assertRaises(ValueError):self.execute(True)
  self.assertEqual(self.api.calls,[]);self.context['enable_writes']='enabled';result=self.execute(True)
  self.assertEqual(result['cancellation_requested'],[100]);self.assertEqual(self.api.calls[-3:],[('GET','repos/Org/Repo/pulls/42'),('GET','repos/Org/Repo/actions/runs/100'),('POST','repos/Org/Repo/actions/runs/100/cancel')])
 def test_untrusted_ref_checkout_workflow_never_calls_api(self):
  for key in ['ref','checkout_sha','workflow_ref','event_name']:
   original=self.context[key];self.context[key]='untrusted'
   with self.assertRaises(ValueError):self.execute(True)
   self.context[key]=original;self.assertEqual(self.api.calls,[])
 def test_push_and_different_pr_preserved(self):
  run=copy.deepcopy(self.api.runs[0]);run.update(id=101,event='push');self.api.runs.append(run)
  run=copy.deepcopy(self.api.runs[0]);run.update(id=102,pull_requests=[{'number':99}]);self.api.runs.append(run)
  self.assertEqual(self.execute(True)['cancellation_requested'],[100])
 def test_completed_or_new_attempt_at_recheck_is_not_cancelled(self):
  for mutation in [lambda r:r.update(status='completed',conclusion='success'),lambda r:r.update(run_attempt=2)]:
   self.setUp()
   def race(api,method,path):
    if path.endswith('/actions/runs/100'):mutation(api.runs[0])
   self.api.mutate=race;result=self.execute(True);self.assertEqual(self.api.posts,0);self.assertEqual(result['already_finished_or_changed'],[100])
 def test_pr_reopened_or_changed_before_write_rejects(self):
  count=[0]
  def race(api,method,path):
   if '/pulls/' in path:
    count[0]+=1
    if count[0]>1:api.pr['head']['sha']='c'*40
  self.api.mutate=race
  with self.assertRaises(ValueError):self.execute(True)
  self.assertEqual(self.api.posts,0)
 def test_closed_unmerged_and_foreign_repo_reject(self):
  self.api.pr['merged']=False
  with self.assertRaises(ValueError):self.execute(True)
  self.assertEqual(self.api.posts,0)
 def test_pagination_is_collected_before_any_write(self):
  second=copy.deepcopy(self.api.runs[0]);second['id']=101;self.api.runs.append(second);self.api.pages=[[self.api.runs[0]],[second]]
  self.assertEqual(self.execute(True)['cancellation_requested'],[100,101]);self.assertTrue(any('page=2' in path for method,path in self.api.calls))
 def test_previous_head_same_pr_is_cancelled_but_post_merge_rerun_survives(self):
  previous=copy.deepcopy(self.api.runs[0]);previous.update(id=101,head_sha='d'*40);previous['pull_requests'][0]['head']['sha']='d'*40;self.api.runs.append(previous)
  restarted=copy.deepcopy(previous);restarted.update(id=102,run_attempt=2,run_started_at='2026-01-02T01:00:00Z');self.api.runs.append(restarted)
  self.assertEqual(self.execute(True)['cancellation_requested'],[100,101])
 def test_missing_merge_or_run_time_cannot_authorize_cancellation(self):
  del self.api.runs[0]['created_at'];self.assertEqual(self.execute(True)['cancellation_requested'],[])
  del self.api.pr['merged_at']
  with self.assertRaises(ValueError):self.execute(True)
 def test_permission_denial_no_retry(self):
  self.api.failure=urllib.error.HTTPError('https://api.github.com',403,'Forbidden',{},None)
  with self.assertRaises(urllib.error.HTTPError):self.execute(True)
  self.assertEqual(self.api.posts,1)
 def test_unexpected_redirects_are_never_followed(self):
  with self.assertRaises(ValueError):m.NoRedirect().redirect_request(None,None,302,'redirect',{},'https://evil.example')
 def test_truncated_or_capped_inventory_cannot_partially_cancel(self):
  original=self.api.request
  def incomplete(method,path):
   value=original(method,path)
   if '?' in path:value['total_count']=1001
   return value
  self.api.request=incomplete
  with self.assertRaises(ValueError):self.execute(True)
  self.assertEqual(self.api.posts,0)
 def test_foreign_post_path_forbidden(self):
  api=m.API('Org/Repo','test-token')
  with self.assertRaises(ValueError):api.request('POST','repos/Org/Other/actions/runs/1/cancel')
  with self.assertRaises(ValueError):api.request('POST','repos/Org/Repo/actions/runs/1/rerun')
 def test_workflow_privileged_source_and_default_on_contract(self):
  root=Path(__file__).resolve().parents[2];text=(root/'.github/workflows/merged-pr-cleanup.yml').read_text()
  self.assertIn('pull_request_target:',text);self.assertIn('types: [closed]',text);self.assertIn('ref: ${{ github.workflow_sha }}',text)
  self.assertIn('persist-credentials: false',text);self.assertIn('cancel-in-progress: false',text);self.assertIn('INNO_MERGED_PR_CLEANUP',text)
  self.assertNotIn('pull_request.head.ref',text);self.assertNotIn('pull_request.head.sha',text);self.assertNotIn('contents: write',text)
  inspect=text.split('  inspect:\n',1)[1].split('  cleanup:\n',1)[0];apply=text.split('  cleanup:\n',1)[1]
  self.assertIn('actions: read',inspect);self.assertNotIn('actions: write',inspect);self.assertIn("!(vars.INNO_MERGED_PR_CLEANUP == '' || vars.INNO_MERGED_PR_CLEANUP == 'enabled')",inspect)
  self.assertIn('actions: write',apply);self.assertIn("(vars.INNO_MERGED_PR_CLEANUP == '' || vars.INNO_MERGED_PR_CLEANUP == 'enabled')",apply)
if __name__=='__main__':unittest.main()
