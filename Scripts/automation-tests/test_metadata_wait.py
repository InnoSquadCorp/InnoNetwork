import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
spec=importlib.util.spec_from_file_location('metadata_wait_test',Path(__file__).resolve().parents[1]/'metadata_wait.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class MetadataWaitTests(unittest.TestCase):
 def test_default_on_remains_pr_only_and_unknown_override_disables(self):
  for value in [None,'','enabled','ENABLED','disabled','unknown']:
   env={} if value is None else {'INNO_JOB_CANCELLATION':value}
   for event in ['pull_request','push','merge_group','workflow_dispatch']:
    self.assertEqual(m.enabled_for({**env,'GITHUB_EVENT_NAME':event}),event=='pull_request' and (value is None or value.lower() in ('','enabled')))
 def setUp(self):self.time=0;self.calls=[];self.codes=[]
 def invoke(self,cmd,check=False,**kwargs):self.calls.append(cmd);return subprocess.CompletedProcess(cmd,self.codes.pop(0))
 def sleep(self,seconds):self.time+=seconds
 def runwait(self,enabled,timeout=60):return m.run(['python3','verify.py'],enabled,timeout,30,self.invoke,lambda:self.time,self.sleep)
 def test_disabled_preserves_first_failure_without_retry(self):self.codes=[1,0];self.assertEqual(self.runwait(False),1);self.assertEqual(len(self.calls),1)
 def test_enabled_retries_until_authoritative_success(self):self.codes=[1,1,0];self.assertEqual(self.runwait(True,90),0);self.assertEqual(len(self.calls),3)
 def test_timeout_never_converts_failure_to_success(self):self.codes=[1,1,1];self.assertEqual(self.runwait(True),1);self.assertEqual(self.time,60)
 def test_cancellation_signal_not_retried(self):self.codes=[-15,0];self.assertEqual(self.runwait(True),-15);self.assertEqual(len(self.calls),1)
 def test_verifier_command_is_never_mutated(self):self.codes=[1,0];self.runwait(True);self.assertEqual(self.calls,[['python3','verify.py']]*2)
 def test_each_invocation_is_bounded_by_remaining_deadline(self):
  budgets=[]
  def invoke(command,**kwargs):
   budgets.append(kwargs['timeout']);self.time+=5
   return subprocess.CompletedProcess(command,1)
  self.assertEqual(m.run(['verify'],True,40,30,invoke,lambda:self.time,self.sleep),1)
  self.assertEqual(budgets,[40,5])
 def test_hanging_verifier_timeout_cannot_succeed_or_retry(self):
  calls=[]
  def invoke(command,**kwargs):
   calls.append(kwargs);raise subprocess.TimeoutExpired(command,kwargs['timeout'])
  self.assertEqual(m.run(['verify'],True,10,30,invoke,lambda:0,self.sleep),124)
  self.assertEqual(calls,[{'check':False,'timeout':10}])
 def test_real_hung_child_is_terminated_at_deadline(self):
  self.assertEqual(m.run([sys.executable,'-c','import time; time.sleep(10)'],True,0.05),124)
 def test_expired_budget_never_starts_command(self):
  self.assertEqual(self.runwait(True,0),124);self.assertEqual(self.calls,[])
 def test_invalid_unbounded_controls_reject(self):
  for args in [([],False,10,1),(['x'],True,-1,1),(['x'],True,10,0)]:
   with self.assertRaises(ValueError):m.run(*args)
if __name__=='__main__':unittest.main()
