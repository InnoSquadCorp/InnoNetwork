import copy
import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('reuse_design',Path(__file__).resolve().parents[1]/'main_moved_reuse_design.py');p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
class MainMovedReuseDesignTests(unittest.TestCase):
 def setUp(self):
  self.old={'repository':'InnoSquadCorp/InnoNetwork','pr':148,'pr_head':'1'*40,'synthetic_merge':'2'*40,'base':'3'*40,'product_closure':['Core','Upload'],'test_closure':['UploadTests'],'inputs':{name:'a'*64 for name in p.CATEGORIES}}
  self.current=copy.deepcopy(self.old);self.current.update(base='4'*40,synthetic_merge='5'*40)
  self.run={'repository':self.old['repository'],'id':123,'attempt':2,'status':'completed','conclusion':'success','app_id':777,'event':'pull_request','workflow_path':'.github/workflows/ci.yml','workflow_content_sha256':'b'*64,'head_sha':self.old['synthetic_merge'],'pr_head':self.old['pr_head'],'base_sha':self.old['base']}
  self.trust={key:self.run[key] for key in ['repository','workflow_path','workflow_content_sha256','app_id']};self.trust.update(latest_run_id=123,latest_attempt=2)
  self.artifact={'repository':self.old['repository'],'run_id':123,'attempt':2,'head_sha':self.old['synthetic_merge'],'workflow_content_sha256':'b'*64,'payload_sha256':'c'*64,'observed_payload_sha256':'c'*64,'expired':False}
 def assess(self):return p.assess(self.current,self.old,self.run,self.artifact,self.trust)
 def test_prose_only_base_change_is_candidate_not_authorization(self):
  result=self.assess();self.assertEqual(result['decision'],'candidate-for-authoritative-revalidation');self.assertFalse(result['reuse_authorized'])
 def test_every_input_category_change_requires_full(self):
  for category in p.CATEGORIES:
   with self.subTest(category=category):
    self.current['inputs'][category]='d'*64;self.assertEqual(self.assess()['decision'],'full-validation');self.current['inputs'][category]='a'*64
 def test_dependency_or_test_closure_change_requires_full(self):
  for field in ['product_closure','test_closure']:
   original=self.current[field];self.current[field]=['Different'];self.assertEqual(self.assess()['decision'],'full-validation');self.current[field]=original
 def test_incomplete_category_or_anchor_fails(self):
  del self.current['inputs']['fixtures'];self.assertEqual(self.assess()['decision'],'full-validation')
 def test_wrong_or_superseded_run_app_attempt_rejects(self):
  for field,value in [('id',124),('attempt',1),('app_id',999),('event','workflow_dispatch'),('head_sha','6'*40),('base_sha','7'*40),('pr_head','8'*40),('workflow_content_sha256','9'*64)]:
   with self.subTest(field=field):
    old=self.run[field];self.run[field]=value;self.assertEqual(self.assess()['decision'],'full-validation');self.run[field]=old
 def test_failed_cancelled_incomplete_source_rejects(self):
  for status,conclusion in [('queued',None),('in_progress',None),('completed','failure'),('completed','cancelled'),('completed','skipped')]:
   self.run.update(status=status,conclusion=conclusion);self.assertEqual(self.assess()['decision'],'full-validation')
 def test_artifact_wrong_attempt_sha_integrity_and_expiry_reject(self):
  for field,value in [('attempt',1),('head_sha','0'*40),('observed_payload_sha256','d'*64),('expired',True),('repository','other/repo')]:
   with self.subTest(field=field):
    old=self.artifact[field];self.artifact[field]=value;self.assertEqual(self.assess()['decision'],'full-validation');self.artifact[field]=old
 def test_current_pr_head_movement_rejects(self):self.current['pr_head']='9'*40;self.assertEqual(self.assess()['decision'],'full-validation')
 def test_untrusted_boolean_claim_cannot_grant_reuse(self):
  self.run['verified']=True;result=self.assess();self.assertEqual(result['decision'],'full-validation');self.assertFalse(result['reuse_authorized'])
if __name__=='__main__':unittest.main()
