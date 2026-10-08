"""Real Git admission and command/receipt controls; fake tools are not Swift proof."""
import copy,importlib.util,json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path
from unittest import mock
SCRIPTS=Path(__file__).resolve().parents[1];ROOT=SCRIPTS.parent
spec=importlib.util.spec_from_file_location('own_product_execution',SCRIPTS/'ci_product_execution.py');x=importlib.util.module_from_spec(spec);spec.loader.exec_module(x)
GRAPH=json.loads((SCRIPTS/'ci-product-graph.json').read_text());DI='InnoDI' in GRAPH['products'];TARGET='InnoDITesting' if DI else 'InnoNetworkAuthAWS'
class ProductExecutionTests(unittest.TestCase):
 def setUp(self):
  temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);self.root=Path(temp.name);self.envgit={**os.environ,'GIT_AUTHOR_NAME':'Test','GIT_COMMITTER_NAME':'Test','GIT_AUTHOR_EMAIL':'test@example.invalid','GIT_COMMITTER_EMAIL':'test@example.invalid'}
  self.git('init','-q','-b','main');(self.root/SCRIPTS.name).mkdir();shutil.copyfile(SCRIPTS/'ci-product-graph.json',self.root/SCRIPTS.name/'ci-product-graph.json');shutil.copyfile(ROOT/'Package.swift',self.root/'Package.swift');(self.root/'Package.resolved').write_text('{}');self.base=self.commit()
  path=self.root/'Sources'/TARGET/'Change.swift';path.parent.mkdir(parents=True);path.write_text('struct Change {}');self.head=self.commit();self.event={'action':'synchronize','pull_request':{'base':{'sha':self.base},'head':{'sha':self.head},'user':{'login':'user'},'labels':[]}};self.path=self.root/'event.json';self.path.write_text(json.dumps(self.event));self.env={'PRODUCT_SCOPE_ENABLED':'true','GITHUB_EVENT_NAME':'pull_request','GITHUB_SHA':self.head,'GITHUB_EVENT_PATH':str(self.path)};self.calls=[]
 def git(self,*args):return subprocess.check_output(['git','-C',str(self.root),'-c','commit.gpgsign=false',*args],env=self.envgit,text=True).strip()
 def commit(self):self.git('add','-A');self.git('commit','-qm','fixture');return self.git('rev-parse','HEAD')
 def dump(self,*args,**kwargs):
  return json.dumps({'targets':[{'name':n,'type':v['kind'],'path':v['inputs'][0].rstrip('/'),'dependencies':[{'target':[d,None]} for d in v['dependencies']]} for n,v in GRAPH['targets'].items()],'products':[{'name':n,'targets':v} for n,v in GRAPH['products'].items()]})
 def runner(self,cmd,**kwargs):self.calls.append(cmd);self.assertTrue(kwargs['check'])
 def mode(self):return ('di-example','SampleApp') if DI else ('network-build','package')
 def test_default_on_and_explicit_disable_still_require_exact_admission(self):
  for value in [None,'','true','TRUE']:
   env={k:v for k,v in self.env.items() if k!='PRODUCT_SCOPE_ENABLED'}
   if value is not None:env['PRODUCT_SCOPE_ENABLED']=value
   with self.subTest(value=value):
    self.assertEqual(x.admit(self.root,env,self.dump)['mode'],'scoped')
    for event in ['push','merge_group','workflow_dispatch']:
     self.assertEqual(x.admit(self.root,{**env,'GITHUB_EVENT_NAME':event},self.dump)['mode'],'full')
    self.assertEqual(x.admit(self.root,env,lambda *a,**k:'{}')['mode'],'full')
  for value in ['false','FALSE','disabled','unknown']:
   with self.subTest(value=value):self.assertEqual(x.admit(self.root,{**self.env,'PRODUCT_SCOPE_ENABLED':value},self.dump)['mode'],'full')
 def test_exact_admission_and_native_or_unaffected_execution(self):
  plan=x.admit(self.root,self.env,self.dump);self.assertEqual(plan['mode'],'scoped');self.assertEqual(plan['products'],[TARGET]);kind,unit=self.mode();receipt=x.execute(self.root,self.env,kind,unit,'macOS',self.root/'tmp',self.root/'receipts',self.runner,self.dump)
  if DI:self.assertEqual(receipt['decision'],'skip-unaffected');self.assertEqual(self.calls,[])
  else:self.assertEqual(self.calls,[['xcrun','swift','build','--target',TARGET,'--force-resolved-versions']])
  x.verify(self.root,self.env,kind,[unit],'macOS',self.root/'tmp',self.root/'receipts',self.dump)
 def test_full_fallback_commands_are_original(self):
  kind,unit=self.mode();plan=x.admit(self.root,{**self.env,'PRODUCT_SCOPE_ENABLED':'false'},self.dump);recipe=x.recipe(self.root,plan,kind,unit,'macOS',self.root/'tmp')
  if DI:self.assertEqual(recipe['commands'],[['swift','build','-Xswiftc','-strict-concurrency=complete','-Xswiftc','-warnings-as-errors'],['swift','test','-Xswiftc','-strict-concurrency=complete','-Xswiftc','-warnings-as-errors'],['swift','run','--skip-build','SampleApp']])
  else:self.assertEqual(recipe['commands'],[['xcrun','swift','build']])
 def test_bot_release_main_queue_and_wrong_sha_stay_full(self):
  for env in [{**self.env,'GITHUB_EVENT_NAME':name} for name in ['push','merge_group','workflow_dispatch']]+[{**self.env,'GITHUB_SHA':'a'*40}]:self.assertEqual(x.admit(self.root,env,self.dump)['mode'],'full')
  for key,value in [('labels',[{'name':'release-validation'}]),('user',{'login':'dependabot[bot]'})]:
   event=copy.deepcopy(self.event);event['pull_request'][key]=value;self.path.write_text(json.dumps(event));self.assertEqual(x.admit(self.root,self.env,self.dump)['mode'],'full')
 def test_graph_diff_or_dirty_failure_stays_full(self):
  self.assertEqual(x.admit(self.root,self.env,lambda *a,**k:'{}')['mode'],'full')
  with mock.patch.object(x.impact,'diff_paths',side_effect=ValueError('missing')):self.assertEqual(x.admit(self.root,self.env,self.dump)['mode'],'full')
  (self.root/'Package.swift').write_text('//changed');self.assertEqual(x.admit(self.root,self.env,self.dump)['mode'],'full')
 def test_failures_do_not_write_success(self):
  kind,unit=self.mode();env={**self.env,'PRODUCT_SCOPE_ENABLED':'false'}
  def fail(cmd,**kwargs):raise subprocess.CalledProcessError(1,cmd)
  with self.assertRaises(subprocess.CalledProcessError):x.execute(self.root,env,kind,unit,'macOS',self.root/'tmp',self.root/'receipts',fail,self.dump)
  self.assertFalse(list((self.root/'receipts').glob('*')))
 def test_missing_forged_stale_or_duplicate_receipts_fail(self):
  kind,unit=self.mode();receipts=self.root/'receipts'
  with self.assertRaises(OSError):x.verify(self.root,self.env,kind,[unit],'macOS',self.root/'tmp',receipts,self.dump)
  proof=x.execute(self.root,self.env,kind,unit,'macOS',self.root/'tmp',receipts,self.runner,self.dump);path=x.receipt_path(receipts,kind,unit,'macOS')
  for key,value in [('result','skipped'),('decision','forged'),('commands',[['true']])]:
   path.write_text(json.dumps({**proof,key:value}))
   with self.assertRaises(ValueError):x.verify(self.root,self.env,kind,[unit],'macOS',self.root/'tmp',receipts,self.dump)
  with self.assertRaises(ValueError):x.execute(self.root,self.env,kind,unit,'macOS',self.root/'tmp',receipts,self.runner,self.dump)
 def test_executable_source_mode_full(self):
  (self.root/'Sources'/TARGET/'Change.swift').chmod(0o755);head=self.commit();self.event['pull_request']['head']['sha']=head;self.path.write_text(json.dumps(self.event));self.env['GITHUB_SHA']=head;self.assertEqual(x.admit(self.root,self.env,self.dump)['mode'],'full')
 def test_untracked_inputs_and_untracked_lock_force_full(self):
  injected=self.root/'Sources'/TARGET/'Injected.swift';injected.write_text('struct Injected {}')
  self.assertEqual(x.admit(self.root,self.env,self.dump)['mode'],'full');injected.unlink()
  self.git('rm','--cached','Package.resolved');self.git('commit','-qm','untrack lock');head=self.git('rev-parse','HEAD');self.event['pull_request']['head']['sha']=head;self.path.write_text(json.dumps(self.event));self.env['GITHUB_SHA']=head
  self.assertEqual(x.admit(self.root,self.env,self.dump)['mode'],'full')
 def test_unsupported_units_never_execute(self):
  with self.assertRaises(ValueError):x.recipe(self.root,{},'unknown','bad','macOS',self.root/'tmp')
if __name__=='__main__':unittest.main()
