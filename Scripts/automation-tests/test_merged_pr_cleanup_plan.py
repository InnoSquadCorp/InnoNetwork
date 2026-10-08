import copy
import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('cleanup_plan',Path(__file__).resolve().parents[1]/'merged_pr_cleanup_plan.py');p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
class MergedPRCleanupTests(unittest.TestCase):
 def setUp(self):
  self.repo='Org/Repo';self.rid=10;self.sha='a'*40;self.workflow='.github/workflows/ci.yml'
  pr={'number':42,'state':'closed','merged':True,'head':{'sha':self.sha},'base':{'repo':{'id':self.rid}}}
  self.event={'action':'closed','number':42,'repository':{'full_name':self.repo,'id':self.rid},'pull_request':pr}
  self.run={'id':123,'run_attempt':2,'repository':self.event['repository'],'event':'pull_request','status':'in_progress','conclusion':None,'head_sha':self.sha,'path':self.workflow,'pull_requests':[copy.deepcopy(pr)]}
 def select(self,run=None):return p.select(self.event,[run or self.run],self.repo,self.rid,{self.workflow})
 def test_merged_pending_validation_is_dry_run_candidate(self):
  for status in p.PENDING:
   self.run['status']=status;result=self.select();self.assertEqual(len(result['candidates']),1);self.assertTrue(result['dry_run']);self.assertFalse(result['writes_performed'])
 def test_unmerged_or_wrong_webhook_rejects(self):
  for field,value in [('action','synchronize'),('number',43)]:
   original=self.event[field];self.event[field]=value
   with self.assertRaises(ValueError):self.select()
   self.event[field]=original
  self.event['pull_request']['merged']=False
  with self.assertRaises(ValueError):self.select()
 def test_same_sha_push_manual_workflow_run_preserved(self):
  for event in ['push','workflow_dispatch','workflow_run','pull_request_target','merge_group']:
   self.run['event']=event;self.assertEqual(self.select()['candidates'],[])
 def test_other_pr_and_missing_association_preserved(self):
  for links in [[],None,[{'number':43}],self.run['pull_requests']*2]:
   run=copy.deepcopy(self.run);run['pull_requests']=links;self.assertEqual(self.select(run)['candidates'],[])
 def test_other_head_repository_or_workflow_preserved(self):
  for field,value in [('head_sha','b'*40),('repository',{'full_name':'Org/Other','id':11}),('path','.github/workflows/other.yml')]:
   run=copy.deepcopy(self.run);run[field]=value;self.assertEqual(self.select(run)['candidates'],[])
 def test_release_publish_and_stateful_allowlist_rejected(self):
  for path in ['release.yml','docs-publish.yml','deploy.yml','perf-history.yml','dependabot-auto-merge.yml']:
   with self.assertRaises(ValueError):p.select(self.event,[self.run],self.repo,self.rid,{'.github/workflows/'+path})
 def test_completed_and_cancelled_preserved(self):
  for conclusion in ['success','failure','cancelled','skipped']:
   self.run.update(status='completed',conclusion=conclusion);self.assertEqual(self.select()['candidates'],[])
 def test_stale_association_and_missing_attempt_preserved(self):
  run=copy.deepcopy(self.run);run['pull_requests'][0]['head']['sha']='c'*40;self.assertEqual(self.select(run)['candidates'],[])
  run=copy.deepcopy(self.run);del run['run_attempt'];self.assertEqual(self.select(run)['candidates'],[])
 def test_duplicate_inventory_rejects(self):
  with self.assertRaises(ValueError):p.select(self.event,[self.run,self.run],self.repo,self.rid,{self.workflow})
 def test_repo_workflow_proposal_is_narrow_and_resolves(self):
  import json
  scripts=Path(__file__).resolve().parents[1];root=scripts.parent
  config=json.loads((scripts/'ci-cleanup-workflows.json').read_text())
  self.assertEqual(config['status'],'reviewed-cleanup-policy-v1')
  allowed=config['merged_pr_pull_request_workflow_allowlist']
  self.assertTrue(allowed);self.assertEqual(allowed,sorted(set(allowed)))
  for path in allowed:self.assertTrue((root/path).is_file());self.assertIsNone(p.PROTECTED.search(path))
  self.assertFalse(set(allowed)&set(config['always_preserved_workflows']))
 def test_no_foreign_base_or_webhook_authorization(self):
  self.event['pull_request']['base']['repo']['id']=99
  with self.assertRaises(ValueError):self.select()
if __name__=='__main__':unittest.main()
