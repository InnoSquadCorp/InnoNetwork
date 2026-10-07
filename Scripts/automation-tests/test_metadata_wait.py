import importlib.util
from pathlib import Path
import subprocess
import unittest
spec=importlib.util.spec_from_file_location('metadata_wait_test',Path(__file__).resolve().parents[1]/'metadata_wait.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class MetadataWaitTests(unittest.TestCase):
 def test_default_on_remains_pr_only_and_unknown_override_disables(self):
  for value in [None,'','enabled','ENABLED','disabled','unknown']:
   env={} if value is None else {'INNO_JOB_CANCELLATION':value}
   for event in ['pull_request','push','merge_group','workflow_dispatch']:
    self.assertEqual(m.enabled_for({**env,'GITHUB_EVENT_NAME':event}),event=='pull_request' and (value is None or value.lower() in ('','enabled')))
 def setUp(self):self.time=0;self.calls=[];self.codes=[]
 def invoke(self,cmd,check=False):self.calls.append(cmd);return subprocess.CompletedProcess(cmd,self.codes.pop(0))
 def sleep(self,seconds):self.time+=seconds
 def runwait(self,enabled,timeout=60):return m.run(['python3','verify.py'],enabled,timeout,30,self.invoke,lambda:self.time,self.sleep)
 def test_disabled_preserves_first_failure_without_retry(self):self.codes=[1,0];self.assertEqual(self.runwait(False),1);self.assertEqual(len(self.calls),1)
 def test_enabled_retries_until_authoritative_success(self):self.codes=[1,1,0];self.assertEqual(self.runwait(True),0);self.assertEqual(len(self.calls),3)
 def test_timeout_never_converts_failure_to_success(self):self.codes=[1,1,1];self.assertEqual(self.runwait(True),1);self.assertEqual(self.time,60)
 def test_cancellation_signal_not_retried(self):self.codes=[-15,0];self.assertEqual(self.runwait(True),-15);self.assertEqual(len(self.calls),1)
 def test_verifier_command_is_never_mutated(self):self.codes=[1,0];self.runwait(True);self.assertEqual(self.calls,[['python3','verify.py']]*2)
 def test_invalid_unbounded_controls_reject(self):
  for args in [([],False,10,1),(['x'],True,-1,1),(['x'],True,10,0)]:
   with self.assertRaises(ValueError):m.run(*args)
if __name__=='__main__':unittest.main()
