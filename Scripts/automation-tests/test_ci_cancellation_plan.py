import importlib.util
from pathlib import Path
import unittest
SCRIPTS=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('cancel_plan_test',SCRIPTS/'ci_cancellation_plan.py');p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
class CancellationPlanTests(unittest.TestCase):
 def setUp(self):self.args=dict(repository='Org/Repo',workflow='.github/workflows/ci.yml',subject_kind='pull_request',subject='57',product='Feature',lane='unit',matrix={'xcode':'26.6','platform':'macOS'})
 def test_stable_same_workload(self):self.assertEqual(p.plan(**self.args),p.plan(**self.args));self.assertTrue(p.plan(**self.args)['cancel_in_progress'])
 def test_no_cross_repo_workflow_pr_product_lane_matrix_collision(self):
  original=p.plan(**self.args)['group']
  for key,value in [('repository','Org/Other'),('workflow','.github/workflows/other.yml'),('subject','58'),('subject_kind','branch'),('product','Other'),('lane','coverage'),('matrix',{'xcode':'27.0','platform':'macOS'}),('matrix',{'xcode':'26.6','platform':'iOS'})]:
   with self.subTest(key=key):self.assertNotEqual(original,p.plan(**{**self.args,key:value})['group'])
 def test_matrix_order_does_not_change_identity(self):self.assertEqual(p.plan(**self.args)['group'],p.plan(**{**self.args,'matrix':{'platform':'macOS','xcode':'26.6'}})['group'])
 def test_commit_and_run_ids_are_not_supported_keys(self):
  for key in ['commit_sha','head_sha','run_id','run_attempt']:
   with self.subTest(key=key),self.assertRaises(TypeError):p.plan(**self.args,**{key:'different'})
 def test_stateful_metadata_never_cancel_validation(self):
  baseline=p.plan(**self.args)['group']
  for purpose in ['metadata','release','publish','stateful-writer']:
   result=p.plan(**self.args,purpose=purpose);self.assertFalse(result['cancel_in_progress']);self.assertNotEqual(result['group'],baseline)
 def test_distinct_case_sensitive_products_do_not_collapse_at_github(self):
  a=p.plan(**self.args)['group'].lower();b=p.plan(**{**self.args,'product':'feature'})['group'].lower();self.assertNotEqual(a,b)
 def test_incomplete_identity_and_unknown_purpose_fail(self):
  for override in [{'lane':''},{'subject_kind':'unknown'},{'purpose':'anything'},{'matrix':{'x':object()}}]:
   with self.subTest(override=override),self.assertRaises(ValueError):p.plan(**{**self.args,**override})
 def test_length_bounded(self):self.assertLess(len(p.plan(**{**self.args,'product':'p'*500})['group']),256)
if __name__=='__main__':unittest.main()
