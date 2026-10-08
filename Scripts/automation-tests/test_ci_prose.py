"""Real Git negative controls for compiler-free documentation CI."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
spec=importlib.util.spec_from_file_location('ci_policy_prose_test',SCRIPTS/'ci-policy.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

class ProseTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.env={**os.environ,'GIT_AUTHOR_NAME':'CI Test','GIT_COMMITTER_NAME':'CI Test','GIT_AUTHOR_EMAIL':'ci@example.invalid','GIT_COMMITTER_EMAIL':'ci@example.invalid'}
        self.git('init','-q','-b','main')
        for path,text in {'README.md':'# Title\n\nProse before\n\n```swift\nlet value = 1\n```\n','CHANGELOG.md':'version one\n','.github/FUNDING.yml':'github: innosquad\n','Sources/Thing.swift':'struct Thing {}\n'}.items():
            target=self.root/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(text)
        self.git('add','.');self.git('commit','-qm','base');self.base=self.git('rev-parse','HEAD')
    def tearDown(self):self.tmp.cleanup()
    def git(self,*args):return subprocess.check_output(['git','-C',str(self.root),'-c','commit.gpgsign=false',*args],env=self.env,text=True).strip()
    def plan(self,changes,labels=()):
        for path,text in changes.items():(self.root/path).write_text(text)
        self.git('add','.');self.git('commit','-qm','head');head=self.git('rev-parse','HEAD')
        self.event={'action':'synchronize','pull_request':{'base':{'sha':self.base},'head':{'sha':head},'labels':[{'name':n} for n in labels],'user':{'login':'developer'}}}
        paths=p.changed_paths(self.root,self.base,head)
        result=p.apply_prose(p.make_plan('pull_request',self.event,paths),self.root,self.event,paths)
        p.validate_plan(result);return result
    def needs(self,plan):return {'ci-plan':{'result':'success'},**{job:{'result':'success' if yes else 'skipped'} for job,yes in plan['jobs'].items()}}
    def test_prose_only_no_compiler_jobs(self):
        plan=self.plan({'README.md':(self.root/'README.md').read_text().replace('Prose before','Prose after')})
        self.assertEqual([j for j,v in plan['jobs'].items() if v],['policy']);self.assertIn('prose_only',plan)
        p.evaluate(plan,self.needs(plan),root=self.root,event=self.event)
        p.prose_module().check_files(self.root,plan['prose_only'])
    def test_funding_only_static(self):
        plan=self.plan({'.github/FUNDING.yml':'github: innosquad\ncustom: https://example.invalid/sponsor\n'})
        self.assertIn('prose_only',plan);p.evaluate(plan,self.needs(plan),root=self.root,event=self.event)
    def test_changed_executable_fence_full(self):
        plan=self.plan({'README.md':(self.root/'README.md').read_text().replace('value = 1','value = 2')})
        self.assertNotIn('prose_only',plan)
        self.assertGreater(sum(plan['jobs'].values()),5)
    def test_mixed_changes_not_prose(self):
        plan=self.plan({'README.md':'changed prose\n','Sources/Thing.swift':'struct Changed {}\n'})
        self.assertNotIn('prose_only',plan);self.assertGreater(sum(plan['jobs'].values()),1)
    def test_release_metadata_full(self):
        plan=self.plan({'CHANGELOG.md':'version two\n'})
        self.assertNotIn('prose_only',plan);self.assertGreater(sum(plan['jobs'].values()),5)
    def test_release_label_full(self):
        plan=self.plan({'.github/FUNDING.yml':'github: changed\n'},['release-validation'])
        self.assertNotIn('prose_only',plan);self.assertGreater(sum(plan['jobs'].values()),5)
    def test_forged_blob_evidence_rejected(self):
        plan=self.plan({'.github/FUNDING.yml':'github: changed\n'});plan['prose_only']['files'][0]['after']='0'*40
        with self.assertRaises(ValueError):p.evaluate(plan,self.needs(plan),root=self.root,event=self.event)
    def test_missing_revalidation_context_rejected(self):
        plan=self.plan({'.github/FUNDING.yml':'github: changed\n'})
        with self.assertRaises(ValueError):p.evaluate(plan,self.needs(plan))
    def test_unselected_success_and_selected_skip_rejected(self):
        plan=self.plan({'.github/FUNDING.yml':'github: changed\n'})
        for key,value in [('policy','skipped'),(next(j for j in p.JOBS if j!='policy'),'success')]:
            needs=self.needs(plan);needs[key]['result']=value
            with self.assertRaises(ValueError):p.evaluate(plan,needs,root=self.root,event=self.event)
    def test_signature_rejects_unclosed_indented_html_directive_changes(self):
        helper=p.prose_module()
        with self.assertRaises(ValueError):helper.executable_signature('```swift\nx\n')
        for before,after in [('    x','    y'),('<script>x</script>','<script>y</script>'),('@Metadata { x }','@Metadata { y }')]:
            self.assertNotEqual(helper.executable_signature(before),helper.executable_signature(after))
    def test_foreign_revision_rejected(self):
        plan=self.plan({'.github/FUNDING.yml':'github: changed\n'});event=copy.deepcopy(self.event);event['pull_request']['head']['sha']='1'*40
        with self.assertRaises(ValueError):p.evaluate(plan,self.needs(plan),root=self.root,event=event)
    def test_added_source_cannot_be_omitted_from_evidence(self):
        plan=self.plan({'.github/FUNDING.yml':'github: changed\n'})
        self.git('checkout','-q',self.base);(self.root/'Sources/Thing.swift').write_text('struct Different {}\n');(self.root/'.github/FUNDING.yml').write_text('github: changed\n');self.git('add','.');self.git('commit','-qm','mixed')
        head=self.git('rev-parse','HEAD');self.event['pull_request']['head']['sha']=head;plan['prose_only']['head']=head
        with self.assertRaises(ValueError):p.evaluate(plan,self.needs(plan),root=self.root,event=self.event)

if __name__=='__main__':unittest.main()
