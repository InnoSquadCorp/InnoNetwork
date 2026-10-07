"""Actual workflow scope, default-semantics, product partition and negative controls."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
SCRIPTS=next(ROOT/f for f in ('Tools','Scripts','scripts') if (ROOT/f/'ci-job-concurrency.json').exists())
def module(name):
    spec=importlib.util.spec_from_file_location(name,SCRIPTS/(name+'.py'));result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
w=module('job_cancellation_wiring');pk=module('ci_product_key')
CONFIG=json.loads((SCRIPTS/'ci-job-concurrency.json').read_text())
def yaml(path):return json.loads(subprocess.check_output(['ruby','-ryaml','-rjson','-e','puts YAML.safe_load(File.read(ARGV[0])).to_json',str(path)]))
from test_ci_event_routing import expression_value

class JobCancellationWiringTests(unittest.TestCase):
    def test_actual_workflows_match_reviewed_job_scopes_and_matrix(self):
        for path,entry in CONFIG['workflows'].items():
            with self.subTest(workflow=path):w.validate_workflow(yaml(ROOT/path),entry,CONFIG,Path(path).name)
    def test_scope_failures_and_aggregate_writer_changes_reject(self):
        for path,entry in CONFIG['workflows'].items():
            data=yaml(ROOT/path)
            if entry['original_concurrency'] is not None:
                bad=copy.deepcopy(data);bad['concurrency']['cancel-in-progress']=True
                with self.assertRaises(ValueError):w.validate_workflow(bad,entry,CONFIG,Path(path).name)
            for job in entry['jobs']:
                for field,value in [('group','shared-all-prs'),('cancel-in-progress',True)]:
                    bad=copy.deepcopy(data);bad['jobs'][job]['concurrency'][field]=value
                    with self.assertRaises(ValueError):w.validate_workflow(bad,entry,CONFIG,Path(path).name)
            for job in entry['excluded_jobs']:
                bad=copy.deepcopy(data);bad['jobs'][job]['concurrency']={'group':'unsafe','cancel-in-progress':True}
                with self.assertRaises(ValueError):w.validate_workflow(bad,entry,CONFIG,Path(path).name)
    def test_outer_feature_off_is_exact_previous_admission(self):
        values={'vars.INNO_JOB_CANCELLATION':'','github.event_name':'pull_request','github.run_id':42,'github.run_attempt':1,
                'github.event.action':'synchronize','github.event.label.name':'','github.event.changes.base':''}
        for entry in CONFIG['workflows'].values():
            old=entry['original_concurrency']
            if old is None:continue
            for action,label,base in [('synchronize','',''),('labeled','documentation',''),('edited','',''),('edited','',{'ref':1})]:
                v={**values,'github.event.action':action,'github.event.label.name':label,'github.event.changes.base':base}
                self.assertEqual(bool(expression_value(w.inner(w.outer_cancel(old['cancel-in-progress'])),v)),bool(expression_value(w.inner(old['cancel-in-progress']),v)))
                self.assertFalse(expression_value(w.inner(w.outer_cancel(old['cancel-in-progress'])),{**v,'vars.INNO_JOB_CANCELLATION':'enabled'}))
            suffix=w.outer_group(old['group'])[len(old['group']):]
            self.assertEqual(expression_value(w.inner(suffix),values),'')
            self.assertEqual(expression_value(w.inner(suffix),{**values,'vars.INNO_JOB_CANCELLATION':'enabled'}),'-jobs-42-1')
    def test_metadata_jobs_never_cancel_validation_and_scoped_missing_key_under_cancels(self):
        values={'vars.INNO_JOB_CANCELLATION':'enabled','github.event_name':'pull_request','github.event.action':'labeled',
                'github.event.label.name':'documentation','github.event.changes.base':''}
        self.assertFalse(expression_value(w.active(CONFIG['metadata']),values))
        ordinary={**values,'github.event.action':'synchronize'}
        self.assertTrue(expression_value(w.active(CONFIG['metadata']),ordinary))
        scoped=w.active(CONFIG['metadata'],['EXAMPLE_PRODUCT_CI'],'needs.ci-plan.outputs.product-key')
        self.assertFalse(expression_value(scoped,{**ordinary,'vars.EXAMPLE_PRODUCT_CI':'true','needs.ci-plan.outputs.product-key':''}))
        self.assertTrue(expression_value(scoped,{**ordinary,'vars.EXAMPLE_PRODUCT_CI':'true','needs.ci-plan.outputs.product-key':'p-proof'}))
        self.assertTrue(expression_value(scoped,{**ordinary,'vars.EXAMPLE_PRODUCT_CI':'false','needs.ci-plan.outputs.product-key':''}))
    def test_collision_identity_isolated_and_active_key_ignores_run_order(self):
        inputs=['repo','ci.yml','tests',45,'main','ordinary',{'product':'A','platform':'macOS'}]
        base=w.workload_key(*inputs,run=1)
        self.assertEqual(base,w.workload_key(*inputs,run=2))
        for index,value in enumerate(['other','other.yml','lint',46,'develop','release',{'product':'B','platform':'macOS'}]):
            changed=list(inputs);changed[index]=value;self.assertNotEqual(base,w.workload_key(*changed))
        for field in ('enabled','metadata','product_mode'):
            kw={field:False if field=='enabled' else True}
            self.assertNotEqual(w.workload_key(*inputs,run=1,**kw),w.workload_key(*inputs,run=2,**kw))
    def test_metadata_wait_keeps_the_exact_verifier_and_bounds(self):
        for path,entry in CONFIG['workflows'].items():
            for job,old in entry['metadata_gates'].items():
                data=yaml(ROOT/path);step=next(s for s in data['jobs'][job]['steps'] if s.get('name')=='Verify prior validation for metadata')
                self.assertTrue(step['run'].endswith('-- '+old['command']))
                self.assertIn('/metadata_wait.py -- ',step['run'])
                bad=copy.deepcopy(data);next(s for s in bad['jobs'][job]['steps'] if s.get('name')==step['name'])['run']='true'
                with self.assertRaises(ValueError):w.validate_workflow(bad,entry,CONFIG,Path(path).name)
    def test_lane_labels_are_part_of_each_stable_identity(self):
        for path,entry in CONFIG['workflows'].items():
            for name,item in entry['jobs'].items():
                fields=w.job_fields(Path(path).name,name,CONFIG['metadata'],item['axes'],item['product_flags'],item.get('product_key'),CONFIG['lane_labels'])
                for label in CONFIG['lane_labels']:self.assertIn("contains(github.event.pull_request.labels.*.name, '"+label+"')",fields['group'])

class ProductCancellationKeyTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);self.root=Path(temporary.name)
        self.env={**os.environ,'GIT_AUTHOR_NAME':'Fixture','GIT_COMMITTER_NAME':'Fixture','GIT_AUTHOR_EMAIL':'fixture@example.invalid','GIT_COMMITTER_EMAIL':'fixture@example.invalid'}
        self.git('init','-q','-b','main');(self.root/SCRIPTS.name).mkdir()
        shutil.copyfile(ROOT/'Package.swift',self.root/'Package.swift');shutil.copyfile(SCRIPTS/'ci-product-graph.json',self.root/SCRIPTS.name/'ci-product-graph.json')
        self.graph=json.loads((SCRIPTS/'ci-product-graph.json').read_text())
        targets=[t for t in self.graph['targets'].values() if t['kind']=='regular' and (t.get('inputs',[t.get('path','')+'/'])[0]).startswith('Sources/')]
        self.input=targets[-1].get('inputs',[targets[-1].get('path','')+'/'])[0];self.base=self.commit()
    def git(self,*args):return subprocess.check_output(['git','-C',str(self.root),'-c','commit.gpgsign=false',*args],env=self.env,text=True).strip()
    def commit(self):self.git('add','-A');self.git('commit','-qm','fixture');return self.git('rev-parse','HEAD')
    def make_key(self):
        head=self.git('rev-parse','HEAD');event={'pull_request':{'base':{'sha':self.base},'head':{'sha':head}}}
        return pk.key_for(self.root,event,{'GITHUB_EVENT_NAME':'pull_request','GITHUB_SHA':head})
    def test_real_git_same_workload_key_stable_across_candidate_shas(self):
        path=self.root/(self.input+'Scope.swift');path.parent.mkdir(parents=True);path.write_text('struct Scope {}\n');self.commit()
        first=self.make_key();self.assertRegex(first,r'^p-[0-9a-f]{64}$')
        path.write_text('struct Scope { let x = 1 }\n');self.commit();self.assertEqual(first,self.make_key())
    def test_unknown_mixed_missing_and_nonregular_evidence_never_share_a_key(self):
        (self.root/'Unknown.swift').write_text('struct Unknown {}\n');self.commit();self.assertEqual(self.make_key(),'')
        self.git('reset','--hard',self.base)
        path=self.root/(self.input+'Scope.swift');path.parent.mkdir(parents=True);path.write_text('struct Scope {}\n');path.chmod(0o755);self.commit();self.assertEqual(self.make_key(),'')
        self.assertEqual(pk.key_for(self.root,{},{}),'')

if __name__=='__main__':unittest.main()
