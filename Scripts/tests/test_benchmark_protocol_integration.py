"""End-to-end shell protocol using tiny fake xcrun/binaries, never a Swift benchmark."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]


class ProtocolIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)/'repository';self.root.mkdir()
        self.bin=Path(self.temp.name)/'bin';self.bin.mkdir()
        def write(path,text):
            p=self.root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)
        write('Package.swift','// swift-tools-version: 6.2\n')
        write('Package.resolved','{}\n')
        write('Sources/InnoNetwork/JSON/PreservedJSON.swift','// fixture\n')
        write('Benchmarks/InnoNetworkBenchmarks/main.swift','// measured fixture harness\n')
        write('Benchmarks/guarded-benchmarks.txt','events/task-event-fanout-single\n')
        write('Benchmarks/json-guarded-benchmarks.txt','json/parse-preserved\n')
        write('Benchmarks/Baselines/default.json',json.dumps({'results':[{'group':'events','name':'task-event-fanout-single'}]}))
        (self.root/'Scripts').mkdir()
        for name in ('run_same_runner_benchmarks.sh','benchmark_protocol.py','compare_benchmark_runs.py',
                     'run_with_guarded_benchmarks.py','guarded_benchmarks.py','render_benchmark_comment.py','_benchmark_report.py'):
            shutil.copyfile(ROOT/'Scripts'/name,self.root/'Scripts'/name)
        self.git('init','-q');self.git('config','user.email','fixture@example.invalid');self.git('config','user.name','Protocol Fixture')
        self.git('add','.');self.git('commit','-qm','base');self.base=self.git('rev-parse','HEAD')
        write('Benchmarks/Baselines/source-revision.txt',self.base+'\n')
        write('Benchmarks/Baselines/json-source-revision.txt',self.base+'\n')
        self.git('add','.');self.git('commit','-qm','candidate')
        self.output=self.root/'.build/evidence'
        self.env=dict(os.environ,PATH=str(self.bin)+os.pathsep+os.environ['PATH'],RUNNER_TEMP=str(Path(self.temp.name)/'scratch'))
        self.env.pop('INNO_GUARDED_BENCHMARK_CONTRACT_ROOT',None);self.env.pop('INNO_BENCHMARK_SCOPE',None)
        xcrun=self.bin/'xcrun'
        binary='''#!PYTHON
import json,os,pathlib,sys
side=SIDE
args=sys.argv[1:]
mode=args[args.index('--only')+1] if '--only' in args else 'runtime'
if mode!='events' and os.environ.get('FAKE_PRIMARY_EXIT'): raise SystemExit(int(os.environ['FAKE_PRIMARY_EXIT']))
if mode=='events' and os.environ.get('FAKE_DIAG_EXIT'): raise SystemExit(int(os.environ['FAKE_DIAG_EXIT']))
if mode=='json': group,name,count='json','parse-preserved',20000
else: group,name,count='events','task-event-fanout-single',300000
ops=210000000 if side=='head' and os.environ.get('FAKE_FAIL_LANE')==('json' if mode=='json' else 'runtime') else 300000000
value={'version':2,'results':[{'group':group,'name':name,'iterations':count,'elapsedSeconds':count/ops,'operationsPerSecond':ops}]}
output=pathlib.Path(args[args.index('--json-path')+1]);output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(value))
'''.replace('PYTHON',sys.executable)
        xcrun.write_text(f'''#!{sys.executable}
import os,pathlib,sys
args=sys.argv[1:]
if args[:2]==['swift','--version']:print('Apple Swift version 6.2 (fixture)')
elif args[:2]==['--find','swift']:print('/fixture/swift')
elif args[:2]==['swift','build']:
    scratch=pathlib.Path(args[args.index('--scratch-path')+1])
    if '--show-bin-path' in args: print(scratch)
    else:
        if os.environ.get('FAKE_BUILD_EXIT'):raise SystemExit(int(os.environ['FAKE_BUILD_EXIT']))
        if scratch.name.endswith('-json') and os.environ.get('FAKE_JSON_BUILD_EXIT'):raise SystemExit(int(os.environ['FAKE_JSON_BUILD_EXIT']))
        scratch.mkdir(parents=True,exist_ok=True)
        binary=scratch/'InnoNetworkBenchmarks';binary.write_text({binary!r}.replace('SIDE',repr('base' if scratch.name.startswith('base-') else 'head')));binary.chmod(0o755)
else:print('fixture-sdk')
''');xcrun.chmod(0o755)
        for name,output in [('xcodebuild','Xcode fixture'),('xcode-select','/fixture/Developer'),('sw_vers','fixture-os')]:
            path=self.bin/name;path.write_text('#!/bin/sh\nprintf "%s\\n" "'+output+'"\n');path.chmod(0o755)

    def git(self,*args):return subprocess.check_output(['git','-C',str(self.root),*args],text=True).strip()

    def run_protocol(self,**env):
        return subprocess.run(['bash','Scripts/run_same_runner_benchmarks.sh','--output-dir',str(self.output),
            '--base-revision',self.base,'--max-regression-percent','20'],cwd=self.root,env={**self.env,**env},
            capture_output=True,text=True,timeout=30)

    def test_all_phases_collect_with_exact_command_and_source_binding(self):
        result=self.run_protocol();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        identity=json.loads((self.output/'protocol/manifest.json').read_text())
        self.assertEqual(identity['sources']['base']['commit'],self.base)
        self.assertEqual(identity['sources']['head']['commit'],self.git('rev-parse','HEAD'))
        for side in ('base','head'):
            self.assertIn('--disable-default-traits',identity['builds'][side]['argv'])
            self.assertIn('--cache-path',identity['builds'][side]['argv'])
            self.assertTrue(identity['sources'][side]['actual_tracked_file_sha256'])
        self.assertEqual(json.loads((self.output/'protocol/diagnostics/diagnostics.json').read_text())['planned_sample_count'],24)
        self.assertTrue((self.output/'json/results.json').is_file())
        self.assertEqual(json.loads((self.output/'protocol/guard-status.json').read_text()),
            {'runtime_guard_exit':0,'json_guard_exit':0,'diagnostic_exit':0,'diagnostics_replace_primary_verdict':False})

    def test_each_primary_guard_failure_survives_successful_diagnostics(self):
        for lane in ('runtime','json'):
            with self.subTest(lane=lane):
                result=self.run_protocol(FAKE_FAIL_LANE=lane)
                self.assertEqual(result.returncode,1,result.stdout+result.stderr)
                receipt=json.loads((self.output/'protocol/guard-status.json').read_text())
                self.assertEqual(receipt[lane+'_guard_exit'],1)
                self.assertEqual(receipt['diagnostic_exit'],0)
                self.assertTrue((self.output/'json/results.json').is_file())

    def test_build_or_primary_process_failure_aborts_before_diagnostics(self):
        for key in ('FAKE_BUILD_EXIT','FAKE_PRIMARY_EXIT','FAKE_JSON_BUILD_EXIT'):
            with self.subTest(key=key):
                shutil.rmtree(self.output,ignore_errors=True)
                result=self.run_protocol(**{key:'1'})
                self.assertNotEqual(result.returncode,0)
                self.assertFalse((self.output/'protocol/diagnostics').exists())

    def test_stale_json_comparison_cannot_mask_an_execution_failure(self):
        first=self.run_protocol();self.assertEqual(first.returncode,0,first.stderr)
        shutil.rmtree(self.output/'protocol/diagnostics')
        second=self.run_protocol(FAKE_JSON_BUILD_EXIT='1')
        self.assertNotEqual(second.returncode,0)
        self.assertFalse((self.output/'json/protocol/comparison.json').exists())
        self.assertFalse((self.output/'protocol/diagnostics').exists())

    def test_invalid_guard_contract_cannot_relabel_stale_output_as_fresh(self):
        for lane,guard in [('runtime','guarded-benchmarks.txt'),('json','json-guarded-benchmarks.txt')]:
            with self.subTest(lane=lane):
                first=self.run_protocol();self.assertEqual(first.returncode,0,first.stderr)
                shutil.rmtree(self.output/'protocol/diagnostics')
                contract=self.root/'Benchmarks'/guard;original=contract.read_text()
                contract.write_text('invalid\n')
                try:
                    second=self.run_protocol()
                    self.assertEqual(second.returncode,2,second.stdout+second.stderr)
                    destination=self.output if lane=='runtime' else self.output/'json'
                    self.assertFalse((destination/'results.json').exists())
                    self.assertFalse((destination/'protocol/comparison.json').exists())
                    self.assertFalse((self.output/'protocol/diagnostics').exists())
                finally: contract.write_text(original)

    def test_diagnostic_failure_does_not_overwrite_the_primary_regression(self):
        result=self.run_protocol(FAKE_FAIL_LANE='runtime',FAKE_DIAG_EXIT='9')
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        receipt=json.loads((self.output/'protocol/guard-status.json').read_text())
        self.assertEqual(receipt['runtime_guard_exit'],1);self.assertEqual(receipt['diagnostic_exit'],9)
        controls=json.loads((self.output/'protocol/diagnostics/diagnostics.json').read_text())
        self.assertEqual(len(controls['samples']),1)
        self.assertEqual(controls['status'],'incomplete')


if __name__=='__main__':unittest.main()
