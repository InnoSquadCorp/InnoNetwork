"""Small executable fixtures for bounded collection and preserved verdicts; no Swift builds."""
import copy
import contextlib
import io
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
        self.root = Path(self.temp.name).resolve()
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

    def complete_identity_fixture(self):
        value = copy.deepcopy(self.manifest)
        source = {
            "commit": "a" * 40,
            "actual_tracked_file_sha256": {
                "Sources/InnoNetworkDownload/DownloadTaskPersistence.swift": "a" * 64,
                "Benchmarks/InnoNetworkBenchmarks/main.swift": "b" * 64,
                "Package.swift": "c" * 64, "Package.resolved": "d" * 64,
            },
            "measured_harness_sha256": "b" * 64, "manifest_sha256": "c" * 64, "lock_sha256": "d" * 64,
            "git_objects": {name: "a" * 40 for name in ("Sources", "Benchmarks", "Package.swift", "Package.resolved")},
        }
        value["sources"] = {side: copy.deepcopy(source) for side in ("base", "head")}
        value["sources"]["head"]["commit"] = "b" * 40
        value["builds"] = {side: {
            "status": "completed", "exit_code": 0, "cwd": str(self.root / side),
            "argv": ["xcrun", "swift", "build", "-c", "release", "--disable-default-traits",
                     "--product", "InnoNetworkBenchmarks", "--scratch-path", str(self.root / side / ".build"),
                     "--cache-path", str(self.root / "cache"), "-Xswiftc", "-DTEST"],
            "build_environment": {key: {"present": False, "sha256": None} for key in p.BUILD_ENVIRONMENT_KEYS},
        } for side in ("base", "head")}
        return value

    def test_identity_equal_recorded_inputs_do_not_claim_equal_binaries(self):
        value = self.complete_identity_fixture()
        original = copy.deepcopy(value)
        comparison = p.compare_identities(value)
        self.assertEqual(comparison['measured_inputs']['status'], 'equivalent')
        self.assertEqual(comparison['git_objects']['status'], 'equivalent')
        self.assertEqual(comparison['binary_bytes']['status'], 'different')
        build = comparison['build']['checks']
        self.assertEqual(build['recorded_argv']['status'], 'different')
        self.assertEqual(build['working_directory']['status'], 'different')
        self.assertEqual(build['argv_ignoring_storage_paths']['status'], 'equivalent')
        self.assertEqual(build['recorded_environment']['status'], 'equivalent')
        self.assertEqual(value, original)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            p.emit_identity_comparison(comparison)
        self.assertIn('recorded measured inputs=equivalent', output.getvalue())
        self.assertIn('binary bytes=different', output.getvalue())
        self.assertIn('do not diagnose persistence/compaction', output.getvalue())
        self.assertIn('Primary 20% gate remains unchanged', output.getvalue())
        value['binaries']['head']['sha256'] = value['binaries']['base']['sha256']
        self.assertEqual(p.compare_identities(value)['binary_bytes']['status'], 'equivalent')

    def test_each_measured_source_manifest_lock_and_harness_change_is_visible(self):
        cases = [
            ('Sources/InnoNetworkDownload/DownloadTaskPersistence.swift', None),
            ('Package.swift', 'manifest_sha256'), ('Package.resolved', 'lock_sha256'),
            ('Benchmarks/InnoNetworkBenchmarks/main.swift', 'measured_harness_sha256'),
        ]
        for path, field in cases:
            with self.subTest(path=path):
                value = self.complete_identity_fixture()
                value['sources']['head']['actual_tracked_file_sha256'][path] = 'f' * 64
                if field:
                    value['sources']['head'][field] = 'f' * 64
                measured = p.compare_identities(value)['measured_inputs']
                self.assertEqual(measured['status'], 'different')
                self.assertEqual(measured['checks']['actual_tracked_file_sha256']['different_keys'], [path])
                if field:
                    self.assertEqual(measured['checks'][field]['status'], 'different')
        for side in ('base', 'head'):
            value = self.complete_identity_fixture()
            value['sources'][side]['actual_tracked_file_sha256']['Sources/New.swift'] = 'f' * 64
            self.assertEqual(p.compare_identities(value)['measured_inputs']['status'], 'different')

    def test_git_object_differences_are_separate_from_measured_harness_bytes(self):
        value = self.complete_identity_fixture()
        value['sources']['base']['git_objects']['Benchmarks'] = 'f' * 40
        comparison = p.compare_identities(value)
        self.assertEqual(comparison['measured_inputs']['status'], 'equivalent')
        self.assertEqual(comparison['git_objects'], {'status': 'different', 'different_keys': ['Benchmarks']})

    def test_build_flags_and_allowlisted_environment_changes_are_not_normalized_away(self):
        for flags in (['-Xswiftc', '-DCHANGED'], ['-c', 'debug'], ['--traits', 'Changed'],
                      ['-Xcc', '-O0'], ['-Xlinker', '-dead_strip'], ['--sdk', '/different-sdk']):
            with self.subTest(flags=flags):
                value = self.complete_identity_fixture()
                value['builds']['head']['argv'] += flags
                self.assertEqual(p.compare_identities(value)['build']['checks']['argv_ignoring_storage_paths']['status'], 'different')
        value = self.complete_identity_fixture()
        value['builds']['head']['build_environment']['SWIFTFLAGS'] = {'present': True, 'sha256': 'f' * 64}
        self.assertEqual(p.compare_identities(value)['build']['checks']['recorded_environment'],
                         {'status': 'different', 'different_keys': ['SWIFTFLAGS']})
        # Empty-but-set flags are distinct from unset flags; invalid metadata
        # on both sides must never be declared equivalent merely by equality.
        for invalid in ({'present': True, 'sha256': None}, {'present': False, 'sha256': 'f' * 64},
                        {'present': 1, 'sha256': 'f' * 64}):
            for side in ('base', 'head'):
                value['builds'][side]['build_environment']['SWIFTFLAGS'] = invalid
            self.assertEqual(p.compare_identities(value)['build']['checks']['recorded_environment']['status'], 'unknown')
        for flag in ('-Xswiftc', '-Xcc', '-Xcxx', '-Xlinker'):
            args = ['swift', 'build', flag, '--scratch-path', flag, '/compiler-argument']
            self.assertEqual(p.build_argv_without_storage_paths(args), args)
        self.assertEqual(p.build_argv_without_storage_paths(['swift', 'build', '--scratch-path=/a', '--cache-path=/b']),
                         ['swift', 'build', '--scratch-path=<storage-path>', '--cache-path=<storage-path>'])

    def test_missing_or_malformed_identity_evidence_is_unknown_not_equivalent(self):
        for field in ('actual_tracked_file_sha256', 'measured_harness_sha256', 'manifest_sha256', 'lock_sha256'):
            for invalid in (None, '', {}, 'bad-hash'):
                with self.subTest(field=field, invalid=invalid):
                    value = self.complete_identity_fixture()
                    for side in ('base', 'head'):
                        value['sources'][side][field] = invalid
                    self.assertEqual(p.compare_identities(value)['measured_inputs']['status'], 'unknown')
        for section, key, group, check in (
            ('sources', 'git_objects', None, 'git_objects'), ('binaries', 'sha256', None, 'binary_bytes'),
            ('builds', 'argv', 'build', 'argv_ignoring_storage_paths'),
            ('builds', 'cwd', 'build', 'working_directory'),
            ('builds', 'build_environment', 'build', 'recorded_environment'),
        ):
            value = self.complete_identity_fixture()
            del value[section]['head'][key]
            comparison = p.compare_identities(value)
            result = comparison[group]['checks'][check] if group else comparison[check]
            self.assertEqual(result['status'], 'unknown', (section, key))
        for argv in ([], ['swift', 'build', '-Xswiftc'], ['swift', 'build', '--scratch-path'],
                     ['swift', 'build', '--cache-path=']):
            self.assertIsNone(p.build_argv_without_storage_paths(argv))
        for path in ('Package.swift', 'Package.resolved', 'Benchmarks/InnoNetworkBenchmarks/main.swift',
                     'Sources/InnoNetworkDownload/DownloadTaskPersistence.swift'):
            value = self.complete_identity_fixture()
            for side in ('base', 'head'):
                del value['sources'][side]['actual_tracked_file_sha256'][path]
            self.assertEqual(p.compare_identities(value)['measured_inputs']['status'], 'unknown')

    def test_old_manifest_remains_loadable_but_does_not_imply_known_inputs(self):
        path = self.root / 'old-manifest.json'
        p.write_json(path, self.manifest)
        loaded = p.load_manifest(path)
        self.assertEqual(loaded, self.manifest)
        self.assertEqual(p.compare_identities(loaded)['measured_inputs']['status'], 'unknown')
        self.assertEqual(p.compare_identities(loaded)['build']['checks']['recorded_environment']['status'], 'unknown')
        loaded['builds'] = {side: {'build_environment': {key: '' for key in p.BUILD_ENVIRONMENT_KEYS}}
                            for side in ('base', 'head')}
        self.assertEqual(p.compare_identities(loaded)['build']['checks']['recorded_environment']['status'], 'unknown')

    def test_build_cli_captures_only_allowlisted_environment_before_execution(self):
        private = {'PATH': '/private/build/path-never-recorded', 'SWIFTFLAGS': '-DSECRET=swift-secret-never-recorded',
                   'CFLAGS': '-DSECRET=c-secret-never-recorded', 'UNRELATED_SECRET': 'token-never-recorded'}
        with mock.patch.dict(os.environ, {**private, 'SWIFT_FLAGS': ''}, clear=True):
            self.assertEqual(p.main(['build', '--directory', str(self.root), '--side', 'base',
                                     '--cwd', str(self.root), '--', sys.executable, '-c', 'pass']), 0)
        record = p.load_report(self.root / 'base-build.json')
        self.assertEqual(set(record['build_environment']), set(p.BUILD_ENVIRONMENT_KEYS))
        for key in ('PATH', 'SWIFTFLAGS', 'CFLAGS'):
            self.assertEqual(record['build_environment'][key],
                             {'present': True, 'sha256': p.hashlib.sha256(private[key].encode()).hexdigest()})
        self.assertEqual(record['build_environment']['CXXFLAGS'], {'present': False, 'sha256': None})
        self.assertEqual(record['build_environment']['SWIFT_FLAGS'],
                         {'present': True, 'sha256': p.hashlib.sha256(b'').hexdigest()})
        for literal in private.values():
            self.assertNotIn(literal, json.dumps(record))
        self.assertNotIn('UNRELATED_SECRET', record['build_environment'])

    def test_manifest_persists_and_emits_additive_identity_evidence(self):
        value = self.complete_identity_fixture()
        directory = self.root / 'protocol'
        for side in ('base', 'head'):
            p.write_json(directory / f'{side}-build.json', value['builds'][side])
        output = io.StringIO()
        with mock.patch.object(p, 'host_identity', return_value={'fixture': True}), \
                mock.patch.object(p, 'source_identity', side_effect=lambda root, rev: value['sources'][rev]), \
                contextlib.redirect_stdout(output):
            saved = p.manifest(directory, {'base': 'base', 'head': 'head'}, {'base': 'base', 'head': 'head'},
                               {side: binary['path'] for side, binary in self.binaries.items()}, 'runtime')
        self.assertEqual(p.load_manifest(directory / 'manifest.json'), saved)
        self.assertEqual(saved['schema'], 1)
        self.assertEqual(saved['identity_comparison']['measured_inputs']['status'], 'equivalent')
        self.assertEqual(saved['identity_comparison']['binary_bytes']['status'], 'different')
        self.assertIn('binary bytes=different', output.getvalue())

    def test_identical_inputs_do_not_replace_compaction_guard_failure_or_receipt(self):
        identifier = ('persistence', 'append-log-compaction')
        def report(ops):
            return {'version': 2, 'results': [{'group': identifier[0], 'name': identifier[1],
                    'iterations': 100, 'elapsedSeconds': 100 / ops, 'operationsPerSecond': ops}]}
        base, head = report(1000), report(710.4)
        compared = p.build_comparison_report([base] * 3, [head] * 3, {identifier}, 20)
        original = copy.deepcopy(compared)
        self.assertEqual(len(compared['baseline']['guardFailures']), 1)
        identity = p.compare_identities(self.complete_identity_fixture())
        self.assertEqual(identity['measured_inputs']['status'], 'equivalent')
        output = self.root / 'results.json'
        p.write_json(output, compared)
        paths = {side: [self.root / f'{side}-{i}.json' for i in range(1, 4)] for side in ('base', 'head')}
        for side, row in (('base', base), ('head', head)):
            for path in paths[side]:
                p.write_json(path, row)
        receipt = p.comparison_receipt(compared, output, paths['base'], paths['head'], 'current', 'a' * 40)
        p.write_json(self.root / 'protocol/comparison.json', receipt)
        p.verify_comparison(self.root, 'current', 'a' * 40, 1)
        with self.assertRaises(ValueError):
            p.verify_comparison(self.root, 'current', 'a' * 40, 0)
        self.assertEqual(compared, original)
        self.assertEqual(receipt['exit_code'], 1)

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

    def test_exited_group_permission_race_retries_after_reaping(self):
        child = mock.Mock(pid=os.getpgrp() + 100000)
        with mock.patch.object(p.os, 'killpg', side_effect=[PermissionError(), ProcessLookupError()]):
            self.assertFalse(p.child_group_exists(child))
        self.assertEqual(child.poll.call_count, 2)
        with mock.patch.object(p.os, 'killpg', side_effect=PermissionError()):
            with self.assertRaises(PermissionError): p.child_group_exists(child)

    def test_cleanup_error_preserves_verdict_record_and_signal_handlers(self):
        before = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}
        for exit_code in (0, 7):
            record = self.root / 'cleanup-error.json'
            with mock.patch.object(p, 'child_group_exists', side_effect=PermissionError('denied')):
                result = p.execute([sys.executable, '-c', f'raise SystemExit({exit_code})'], record)
            self.assertEqual(result, exit_code or 2)
            self.assertIn('denied', p.load_report(record)['cleanup_error'])
            self.assertEqual({s: signal.getsignal(s) for s in before}, before)

    def test_stream_close_error_preserves_verdict_record_and_handlers(self):
        before = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}
        for exit_code in (0, 7):
            record = self.root / 'close-error.json'
            stream = mock.Mock()
            stream.close.side_effect = OSError('close failed')
            original_open = Path.open
            output = self.root / 'stdout.txt'
            def open_path(path, *args, **kwargs):
                return stream if path == output else original_open(path, *args, **kwargs)
            with mock.patch.object(Path, 'open', open_path), \
                    mock.patch.object(p.subprocess, 'Popen') as popen, \
                    mock.patch.object(p, 'child_group_exists', return_value=False):
                popen.return_value.wait.return_value = exit_code
                result = p.execute(['test-child'], record, stdout_path=output)
            saved = p.load_report(record)
            self.assertEqual(result, exit_code or 2)
            self.assertEqual(saved['exit_code'], result)
            self.assertEqual(saved['status'], 'process-failed' if exit_code else 'cleanup-failed')
            self.assertEqual(saved['stream_close_error'], 'close failed')
            self.assertEqual({s: signal.getsignal(s) for s in before}, before)

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
