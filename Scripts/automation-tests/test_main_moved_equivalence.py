"""End-to-end metadata proof: real blob/ZIP hashes and authoritative fake API races."""
import base64,copy,hashlib,importlib.util,io,json,unittest,zipfile
from pathlib import Path
import test_verify_ci_metadata as original
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('equiv_test',ROOT/'Scripts/main_moved_equivalence.py');equiv=importlib.util.module_from_spec(spec);spec.loader.exec_module(equiv)
spec=importlib.util.spec_from_file_location('policy_for_equiv',ROOT/'Scripts/ci-policy.py');policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
class MovedTranscript(original.Transcript):
 def __init__(self):
  super().__init__();self.main=self.final_main='d'*40;self.new_source='f'*40;self.new_tree='9'*40;self.blobs={};self.mapping={};self.artifact_race=False;self.ref_race=False;self.ref_reads=0
  self.env.update(INNO_MAIN_MOVED_REUSE='enabled',CI_INPUT_VARIABLES=json.dumps({'INNO_MAIN_MOVED_REUSE':'enabled'}))
  def blob(text):
   data=text.encode();sha=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest();self.blobs[sha]={'sha':sha,'size':len(data),'encoding':'base64','content':base64.b64encode(data).decode()};return sha
  before=blob('# Readme\nOld prose\n```swift\nlet value = 1\n```\n');after=before
  entries=[{'path':'README.md','mode':'100644','type':'blob','sha':before},{'path':'Package.resolved','mode':'100644','type':'blob','sha':'1'*40},{'path':'Sources/Core.swift','mode':'100644','type':'blob','sha':'2'*40},{'path':'.github/workflows/ci.yml','mode':'100644','type':'blob','sha':'3'*40},{'path':'Scripts/ci-policy.py','mode':'100644','type':'blob','sha':'4'*40}]
  self.old_tree={'sha':'e'*40,'truncated':False,'tree':copy.deepcopy(entries)};entries[0]['sha']=after;self.current_tree={'sha':self.new_tree,'truncated':False,'tree':entries}
  self.current_merge={'sha':self.new_source,'tree':{'sha':self.new_tree},'parents':[{'sha':self.main},{'sha':original.HEAD}]}
  event={'action':'synchronize','pull_request':{'labels':[],'user':{'login':'user'}}}
  self.plan=policy.make_plan('pull_request',event,['Sources/Core.swift']);self.config=equiv.configuration(self.env['CI_INPUT_VARIABLES']);self.make_archive()
 def make_archive(self):
  data=io.BytesIO()
  with zipfile.ZipFile(data,'w') as z:z.writestr('ci-plan.json',json.dumps(self.plan));z.writestr('ci-evidence-config.json',json.dumps(self.config))
  self.archive_data=data.getvalue();self.artifacts=[{'id':501,'name':f'ci-plan-{original.SOURCE}-1','expired':False,'workflow_run':{'id':10,'head_sha':original.HEAD},'digest':'sha256:'+hashlib.sha256(self.archive_data).hexdigest()}]
 def get(self,path):
  if 'git/ref/pull/' in path:
   self.ref_reads+=1;return {'object':{'sha':'0'*40 if self.ref_race and self.ref_reads>1 else self.new_source}}
  if 'compare/' in path:return {'status':'ahead','merge_base_commit':{'sha':original.BASE}}
  if path.endswith('git/commits/'+self.new_source):return copy.deepcopy(self.current_merge)
  if 'git/trees/' in path:return copy.deepcopy(self.old_tree if '/'+self.old_tree['sha']+'?' in path else self.current_tree)
  if 'git/blobs/' in path:return copy.deepcopy(self.blobs[path.rsplit('/',1)[1]])
  if path.endswith('actions/artifacts/501'):
   value=copy.deepcopy(self.artifacts[0]);value['expired']=self.artifact_race;return value
  return super().get(path)
 def pages(self,path,key):return copy.deepcopy(self.artifacts) if key=='artifacts' else super().pages(path,key)
 def archive(self,path):
  if not path.endswith('actions/artifacts/501/zip'):raise AssertionError(path)
  return self.archive_data
class MainMovedEquivalenceTests(unittest.TestCase):
 def test_unset_and_blank_default_enable_only_complete_input_identity(self):
  for value in [None,'','ENABLED']:
   t=MovedTranscript();t.env.pop('INNO_MAIN_MOVED_REUSE')
   if value is not None:t.env['INNO_MAIN_MOVED_REUSE']=value
   t.env['CI_INPUT_VARIABLES']='{}';t.config=equiv.configuration('{}');t.make_archive()
   self.assertEqual(t.prove()['main_moved_equivalence']['current_main'],t.main)
   t.current_tree['tree'][0]['sha']='8'*40
   with self.assertRaises(ValueError):t.prove()
  for value in ['disabled','false','unknown']:
   t=MovedTranscript();t.env['INNO_MAIN_MOVED_REUSE']=value
   with self.assertRaisesRegex(ValueError,'main moved'):t.prove()
 def test_complete_input_identity_across_main_advance_uses_native_success_and_hashed_artifact(self):
  t=MovedTranscript();result=t.prove();self.assertEqual(result['run'],10);proof=result['main_moved_equivalence'];self.assertEqual(proof['current_main'],t.main);self.assertEqual(proof['ignored_prose_paths'],[]);self.assertEqual(result['source_artifact']['artifact_id'],501)
 def test_updated_event_base_reuses_old_validation_only_with_effective_input_proof(self):
  t=MovedTranscript();t.pr['base']['sha']=t.main;t.event['pull_request']['base']['sha']=t.main;t.env['GITHUB_SHA']=t.new_source
  result=t.prove();self.assertEqual(result['main_moved_equivalence']['base'],original.BASE);self.assertEqual(result['main_moved_equivalence']['current_main'],t.main)
  t=MovedTranscript();t.pr['base']['sha']=t.main;t.event['pull_request']['base']['sha']=t.main;t.env['GITHUB_SHA']=t.new_source;t.env['INNO_MAIN_MOVED_REUSE']='disabled'
  with self.assertRaises(ValueError):t.prove()
 def test_explicit_disable_retains_old_main_guard(self):
  t=MovedTranscript();t.env['INNO_MAIN_MOVED_REUSE']='disabled'
  with self.assertRaisesRegex(ValueError,'main moved'):t.prove()
 def test_source_lock_workflow_or_policy_change_rejects(self):
  for index in [1,2,3,4]:
   t=MovedTranscript();t.current_tree['tree'][index]['sha']='5'*40
   with self.subTest(index=index),self.assertRaises(ValueError):t.prove()
 def test_changed_literal_prose_requires_fresh_docs_gate_even_with_same_code_fences(self):
  t=MovedTranscript();t.current_tree['tree'][0]['sha']='8'*40
  with self.assertRaisesRegex(ValueError,'fresh affected gate'):t.prove()
 def test_changed_code_fence_or_corrupted_blob_rejects(self):
  t=MovedTranscript();sha=t.current_tree['tree'][0]['sha'];data=b'# Readme\n```swift\nlet value = 2\n```\n';new=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest();t.blobs[new]={'sha':new,'size':len(data),'encoding':'base64','content':base64.b64encode(data).decode()};t.current_tree['tree'][0]['sha']=new
  with self.assertRaises(ValueError):t.prove()
  t=MovedTranscript();t.current_tree['tree'][0]['sha']='7'*40
  with self.assertRaises(ValueError):t.prove()
 def test_truncated_added_deleted_mode_and_unready_merge_reject(self):
  mutations=[lambda t:t.current_tree.update(truncated=True),lambda t:t.current_tree['tree'].pop(),lambda t:t.current_tree['tree'][0].update(mode='120000'),lambda t:t.current_merge['parents'][0].update(sha='0'*40)]
  for change in mutations:
   t=MovedTranscript();change(t)
   with self.assertRaises(ValueError):t.prove()
 def test_artifact_attempt_expiry_integrity_and_variable_drift_reject(self):
  mutations=[lambda t:t.artifacts[0].update(name='ci-plan-wrong-2'),lambda t:t.artifacts[0].update(expired=True),lambda t:t.artifacts[0]['workflow_run'].update(id=11),lambda t:setattr(t,'archive_data',t.archive_data+b'corrupt'),lambda t:t.env.update(CI_INPUT_VARIABLES='{}')]
  for change in mutations:
   t=MovedTranscript();change(t)
   with self.assertRaises(ValueError):t.prove()
 def test_source_failure_app_or_attempt_still_reject(self):
  for change in [lambda t:t.run.update(conclusion='failure'),lambda t:t.checks[400]['app'].update(id=7),lambda t:t.run.update(run_attempt=2)]:
   t=MovedTranscript();change(t)
   with self.assertRaises(ValueError):t.prove()
 def test_final_main_merge_artifact_and_newer_run_races_reject(self):
  for change in [lambda t:setattr(t,'final_main','0'*40),lambda t:setattr(t,'ref_race',True),lambda t:setattr(t,'artifact_race',True),lambda t:setattr(t,'list_race',lambda runs:runs.append({**t.run,'id':30,'run_number':30}))]:
   t=MovedTranscript();change(t)
   with self.assertRaises(ValueError):t.prove()
 def test_no_execution_config_artifact_cannot_enter_reuse(self):
  t=MovedTranscript();data=io.BytesIO()
  with zipfile.ZipFile(data,'w') as z:z.writestr('ci-plan.json',json.dumps(t.plan))
  t.archive_data=data.getvalue();t.artifacts[0]['digest']='sha256:'+hashlib.sha256(t.archive_data).hexdigest()
  with self.assertRaises(ValueError):t.prove()

class ArchiveTransportTests(unittest.TestCase):
 def test_signed_storage_download_never_receives_github_token(self):
  from unittest import mock
  import urllib.error
  class Response:
   def __enter__(self):return self
   def __exit__(self,*args):pass
   def read(self,limit):return b'zip-bytes'
  first=mock.Mock();first.open.side_effect=urllib.error.HTTPError('https://api.github.com',302,'Found',{'Location':'https://example.blob.core.windows.net/file?sig=opaque'},None)
  second=mock.Mock();second.open.return_value=Response()
  with mock.patch.object(original.gate,'build_opener',side_effect=[first,second]):
   api=original.gate.API(original.REPO,'secret-test-token');self.assertEqual(api.archive('repos/'+original.REPO+'/actions/artifacts/1/zip'),b'zip-bytes')
  self.assertIn('Authorization',first.open.call_args.args[0].headers)
  self.assertNotIn('Authorization',second.open.call_args.args[0].headers)
 def test_http_foreign_userinfo_and_unrecognized_storage_are_rejected(self):
  from unittest import mock
  import urllib.error
  for location in ['http://example.blob.core.windows.net/file','https://evil.example/file','https://user:pass@example.blob.core.windows.net/file','https://example.blob.core.windows.net:8443/file']:
   first=mock.Mock();first.open.side_effect=urllib.error.HTTPError('https://api.github.com',302,'Found',{'Location':location},None)
   with mock.patch.object(original.gate,'build_opener',return_value=first),self.assertRaises(ValueError):original.gate.API(original.REPO,'test').archive('repos/'+original.REPO+'/actions/artifacts/1/zip')
   self.assertEqual(first.open.call_count,1)
 def test_foreign_and_wrong_artifact_route_reject_before_transport(self):
  from unittest import mock
  with mock.patch.object(original.gate,'build_opener') as opener:
   for path in ['repos/foreign/repo/actions/artifacts/1/zip','repos/'+original.REPO+'/actions/runs/1/cancel']:
    with self.assertRaises(ValueError):original.gate.API(original.REPO,'test').archive(path)
   opener.assert_not_called()

if __name__=='__main__':unittest.main()
