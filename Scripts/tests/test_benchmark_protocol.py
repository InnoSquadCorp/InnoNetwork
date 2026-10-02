"""Small executable fixtures for bounded collection and preserved verdicts; no Swift builds."""
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import benchmark_protocol as p


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.missing = self.root / "intentionally-missing.json"
        self.binaries = {}
        for side, ops in (("base", 300000000), ("head", 210000000)):
            path = self.root / side
            path.write_text(f'''#!{sys.executable}
import json, pathlib, sys
args=sys.argv[1:]
output=pathlib.Path(args[args.index('--json-path')+1]); output.parent.mkdir(parents=True,exist_ok=True)
output.write_text(json.dumps({{"version":2,"results":[{{"group":"events","name":"task-event-fanout-single","iterations":300000,"elapsedSeconds":300000/{ops},"operationsPerSecond":{ops}}}]}}))
print('fixture complete')
''')
            path.chmod(0o755)
            self.binaries[side] = {"path":str(path), "sha256":p.sha256(path)}
        self.manifest = {"schema":1, "lane":"runtime", "binaries":self.binaries}

    def test_fixed_controls_show_same_binary_zero_and_real_regression_in_both_orders(self):
        output = self.root / "controls"
        self.assertEqual(p.diagnostics(self.manifest, output, self.missing), 0)
        evidence = json.loads((output/'diagnostics.json').read_text())
        self.assertEqual(evidence['status'], 'complete')
        self.assertEqual(len(evidence['samples']), 24)
        self.assertEqual(len(p.diagnostic_schedule()),24)
        self.assertEqual(evidence['planned_sample_count'],24)
        for label in ('AA','BB'):
            self.assertEqual(evidence['comparisons'][label][0]['deltaPercent'], 0)
        for label in ('AB','BA'):
            self.assertEqual(evidence['comparisons'][label][0]['deltaPercent'], -30)
        self.assertIn('never replaces', evidence['purpose'])
        for label,pair,position,side in p.diagnostic_schedule():
            record=json.loads((output/f'{label}-{pair}-{position}-process.json').read_text())
            self.assertEqual(record['argv'][0], self.binaries[side]['path'])
            self.assertEqual(record['binary_sha256_before'], self.binaries[side]['sha256'])
            self.assertEqual(record['binary_sha256_after'], self.binaries[side]['sha256'])
            self.assertEqual(record['exit_code'],0)
            self.assertLess(record['before']['monotonic_ns'],record['after']['monotonic_ns'])
            self.assertEqual(record['argv'][1:4], ['--quick','--only','events'])
            self.assertIn('whole child process',record['process_usage']['scope'])
        result=p.build_comparison_report([p.load_report(output/f'AB-{i}-1.json') for i in range(1,4)],
            [p.load_report(output/f'AB-{i}-2.json') for i in range(1,4)], {p.EVENT},20)
        self.assertEqual(len(result['baseline']['guardFailures']),1)

    def test_actual_argv_cwd_and_bounded_process_resource_metadata(self):
        record=self.root/'build.json';out=self.root/'stdout.log'
        argv=[sys.executable,'-c','print("actual argv preserved")']
        self.assertEqual(p.execute(argv,record,cwd=self.root,stdout_path=out,timeout_seconds=2),0)
        data=p.load_report(record)
        self.assertEqual(data['argv'],argv);self.assertEqual(data['cwd'],str(self.root))
        self.assertEqual(data['status'],'completed')
        self.assertIn('actual argv preserved',out.read_text())
        self.assertGreaterEqual(data['process_usage']['user_cpu_seconds'],0)

    def test_nonzero_launch_and_timeout_never_become_success(self):
        for argv,expected,status in [([sys.executable,'-c','raise SystemExit(7)'],7,'process-failed'),
                ([str(self.root/'missing')],2,'launch-failed'),
                ([sys.executable,'-c','import time; time.sleep(5)'],124,'timeout')]:
            record=self.root/'failed.json'
            self.assertEqual(p.execute(argv,record,timeout_seconds=0.05),expected)
            self.assertEqual(p.load_report(record)['status'],status)
        self.assertNotIn('diagnostics.json',[x.name for x in self.root.iterdir()])

    def test_timeout_terminates_the_child_process_group(self):
        pid_file=self.root/'pid';record=self.root/'timeout.json'
        code=f'import os,pathlib,time; pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(5)'
        self.assertEqual(p.execute([sys.executable,'-c',code],record,timeout_seconds=0.2),124)
        pid=int(pid_file.read_text())
        with self.assertRaises(ProcessLookupError): os.kill(pid,0)

    def test_exited_leader_cannot_leave_a_term_ignoring_descendant(self):
        def alive(pid):
            result = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
            # Orphan zombies awaiting the OS reaper cannot execute any work.
            return bool(result.stdout.strip()) and not result.stdout.lstrip().startswith('Z')
        for mode, expected, status in [('timeout',124,'timeout'),
                                      ('interrupt',143,'interrupted'),
                                      ('exit',2,'unfinished-descendants')]:
            with self.subTest(mode=mode):
                pid_file=self.root/(mode+'-descendant.pid');group_file=self.root/(mode+'-group.pid')
                descendant=(f'import os,pathlib,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                            f'pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(30)')
                leader=f'''import os,pathlib,signal,subprocess,sys,time
pathlib.Path({str(group_file)!r}).write_text(str(os.getpid()))
subprocess.Popen([sys.executable,'-c',{descendant!r}])
while not pathlib.Path({str(pid_file)!r}).exists(): time.sleep(0.005)
if {mode!r} == 'interrupt': os.kill(os.getppid(),signal.SIGTERM)
if {mode!r} != 'exit': time.sleep(30)
'''
                started=time.monotonic()
                try:
                    self.assertEqual(p.execute([sys.executable,'-c',leader],self.root/'group.json',timeout_seconds=0.4),expected)
                    self.assertLess(time.monotonic()-started,4.75)
                    self.assertEqual(p.load_report(self.root/'group.json')['status'],status)
                    self.assertNotEqual(int(group_file.read_text()),os.getpgrp())
                    deadline=time.monotonic()+1
                    while alive(int(pid_file.read_text())) and time.monotonic()<deadline: time.sleep(0.01)
                    self.assertFalse(alive(int(pid_file.read_text())))
                finally:
                    if group_file.exists():
                        try: os.killpg(int(group_file.read_text()),signal.SIGKILL)
                        except ProcessLookupError: pass

    def test_interruption_preserves_signal_and_does_not_continue_controls(self):
        record=self.root/'interrupted.json'
        result=p.execute([sys.executable,'-c','import os,signal,time; os.kill(os.getppid(),signal.SIGTERM); time.sleep(5)'],record,timeout_seconds=2)
        self.assertEqual(result,143)
        self.assertEqual(p.load_report(record)['status'],'interrupted')

    def test_changed_binary_existing_baseline_or_wrong_event_workload_rejected(self):
        output=self.root/'sample.json';record=self.root/'sample-process.json'
        self.missing.write_text('{}')
        with self.assertRaisesRegex(ValueError,'intentionally missing'):
            p.sample(self.manifest,'base',output,self.missing,record)
        self.missing.unlink()
        Path(self.binaries['base']['path']).write_text('changed binary')
        with self.assertRaisesRegex(ValueError,'changed before'):
            p.sample(self.manifest,'base',output,self.missing,record)
        with mock.patch.object(p,'sample',return_value=124) as sample:
            self.assertEqual(p.diagnostics(self.manifest,self.root/'failed-controls',self.missing),124)
            self.assertEqual(sample.call_count,1)
            self.assertEqual(p.load_report(self.root/'failed-controls/diagnostics.json')['status'],'incomplete')

    def test_no_output_stale_output_impossible_duration_and_wrong_workload_are_rejected(self):
        output=self.root/'sample.json';record=self.root/'process.json'
        binary=Path(self.binaries['base']['path'])
        cases=[("pass",'no report'),
            ("import json,pathlib; pathlib.Path(OUTPUT).write_text(json.dumps({'version':2,'results':[{'group':'events','name':'task-event-fanout-single','iterations':1,'elapsedSeconds':0.001,'operationsPerSecond':1000}]}))",'wrong workload'),
            ("import json,pathlib; pathlib.Path(OUTPUT).write_text(json.dumps({'version':2,'results':[{'group':'events','name':'task-event-fanout-single','iterations':300000,'elapsedSeconds':1000,'operationsPerSecond':300}]}))",'impossible duration')]
        for body,label in cases:
            output.write_text('{"version":2,"results":[]}')
            binary.write_text('#!'+sys.executable+'\n'+body.replace('OUTPUT',repr(str(output)))+'\n')
            self.manifest['binaries']['base']['sha256']=p.sha256(binary)
            with self.subTest(case=label),self.assertRaises((OSError,ValueError)):
                p.sample(self.manifest,'base',output,self.missing,record,only_events=True)
        self.assertFalse(p.load_report(record).get('report_sha256'))

    def test_diagnostic_budget_is_fixed_and_exhaustion_launches_nothing(self):
        for invalid in (-1,0,361,True):
            with self.assertRaises(ValueError):
                p.diagnostics(self.manifest,self.root/'controls',self.missing,budget_seconds=invalid)
        with mock.patch.object(p.time,'monotonic',side_effect=[0,361,361]),mock.patch.object(p,'sample') as sample:
            self.assertEqual(p.diagnostics(self.manifest,self.root/'expired',self.missing),124)
            sample.assert_not_called()
        schedule=p.diagnostic_schedule()
        for label in ('AA','BB','AB','BA'):
            self.assertEqual(len([row for row in schedule if row[0]==label]),6)
        self.assertEqual(p.DIAGNOSTIC_BUDGET_SECONDS,360)
        self.assertEqual(p.DIAGNOSTIC_SAMPLE_TIMEOUT_SECONDS,45)

    def test_manifest_rejects_unsuccessful_build_or_different_harness(self):
        directory=self.root/'protocol';directory.mkdir()
        for side in ('base','head'):
            p.write_json(directory/f'{side}-build.json',{'status':'completed','exit_code':0,'argv':['xcrun','swift','build']})
        identities={'base':{'measured_harness_sha256':'a'},'head':{'measured_harness_sha256':'b'}}
        with mock.patch.object(p,'host_identity',return_value={'fixture':True}), \
                mock.patch.object(p,'source_identity',side_effect=lambda root,rev:identities[rev]):
            with self.assertRaisesRegex(ValueError,'different harness'):
                p.manifest(directory,{'base':'base','head':'head'},{'base':'base','head':'head'},
                    {k:v['path'] for k,v in self.binaries.items()},'runtime')
        p.write_json(directory/'head-build.json',{'status':'timeout','exit_code':124})
        with self.assertRaisesRegex(ValueError,'successful captured builds'):
            p.manifest(directory,{}, {}, {}, 'runtime')

    def test_primary_selector_and_output_are_preserved(self):
        output=self.root/'full.json';record=self.root/'full-process.json'
        self.assertEqual(p.sample(self.manifest,'base',output,self.missing,record),0)
        self.assertNotIn('--only',p.load_report(record)['argv'])
        json_lane=copy.deepcopy(self.manifest);json_lane['lane']='json'
        self.assertEqual(p.sample(json_lane,'head',output,self.missing,record),0)
        args=p.load_report(record)['argv'];self.assertEqual(args[args.index('--only')+1],'json')

    def test_comparison_receipt_binds_invocation_head_inputs_output_and_verdict(self):
        from compare_benchmark_runs import comparison_receipt
        row={'version':2,'results':[{'group':'events','name':'task-event-fanout-single',
             'iterations':300000,'elapsedSeconds':1,'operationsPerSecond':300000}]}
        paths={side:[self.root/f'{side}-{i}.json' for i in range(1,4)] for side in ('base','head')}
        for side in paths:
            for path in paths[side]: p.write_json(path,row)
        report=p.build_comparison_report([row]*3,[row]*3,{p.EVENT},20)
        output=self.root/'results.json';p.write_json(output,report)
        receipt=comparison_receipt(report,output,paths['base'],paths['head'],'current','a'*40)
        p.write_json(self.root/'protocol/comparison.json',receipt)
        p.verify_comparison(self.root,'current','a'*40,0)
        for invocation,head,status in [('old','a'*40,0),('current','b'*40,0),('current','a'*40,1)]:
            with self.assertRaises(ValueError): p.verify_comparison(self.root,invocation,head,status)
        paths['base'][0].write_text(paths['base'][0].read_text()+'\n')
        with self.assertRaises(ValueError): p.verify_comparison(self.root,'current','a'*40,0)
        p.write_json(paths['base'][0],row)
        output.write_text(output.read_text()+'\n')
        with self.assertRaises(ValueError): p.verify_comparison(self.root,'current','a'*40,0)


if __name__=='__main__': unittest.main()
