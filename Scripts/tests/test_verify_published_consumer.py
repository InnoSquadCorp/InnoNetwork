"""Offline command/identity controls; fake xcrun is never Apple execution evidence."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHA = 'a' * 40


class PublicConsumerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        (self.root / 'Scripts').mkdir(parents=True)
        self.script = self.root / 'Scripts/verify_published_consumer.sh'
        shutil.copy(ROOT / 'Scripts/verify_published_consumer.sh', self.script)
        self.bin = Path(self.temp.name) / 'bin'
        self.bin.mkdir()
        self.log = Path(self.temp.name) / 'commands.jsonl'
        fake = self.bin / 'xcrun'
        fake.write_text('#!' + sys.executable + '\n' + '''import json, os, pathlib, re, sys
args=sys.argv[1:]
with open(os.environ['CALL_LOG'],'a') as stream: stream.write(json.dumps({'args':args,'git_global':os.environ.get('GIT_CONFIG_GLOBAL'),'git_count':os.environ.get('GIT_CONFIG_COUNT')})+'\\n')
if args == ['swift','--version']:
    print('Apple Swift version 6.4 (offline fixture)');sys.exit(0)
root=pathlib.Path(args[args.index('--package-path')+1])
manifest=(root/'Package.swift').read_text()
profile='core-only' if 'traits: []' in manifest else 'default'
with open(os.environ['CALL_LOG'],'a') as stream: stream.write(json.dumps({'profile':profile,'manifest':manifest,'root':str(root),'source':(root/'Sources/ReleaseConsumer/ReleaseConsumer.swift').read_text()})+'\\n')
if args[1]=='package':
    version=re.search(r'exact: "([^"]+)"',manifest)
    revision=re.search(r'revision: "([^"]+)"',manifest)
    state={'revision':revision[1] if revision else os.environ['EXPECTED_SHA']}
    if version: state['version']=version[1]
    mode=os.environ.get('FAIL_MODE')
    if mode=='wrong-sha':state['revision']='b'*40
    if mode=='wrong-version':state['version']='6.0.0'
    if mode=='branch':state['branch']='main'
    pin={'identity':'innonetwork','kind':'remoteSourceControl','location':'https://github.com/InnoSquadCorp/InnoNetwork.git','state':state}
    if mode=='wrong-source':pin['location']='https://github.com/foreign/InnoNetwork.git'
    pins=[pin,pin] if mode=='duplicate' else ([] if mode=='missing' else [pin])
    if mode=='resolve-error':sys.exit(9)
    (root/'Package.resolved').write_text(json.dumps({'version':3,'pins':pins}))
elif args[1]=='run':
    if os.environ.get('FAIL_MODE')=='run-error':sys.exit(8)
    if os.environ.get('FAIL_MODE')=='lock-race':
        lock=json.loads((root/'Package.resolved').read_text());lock['pins'][0]['state']['revision']='c'*40
        (root/'Package.resolved').write_text(json.dumps(lock))
    print('fixture execution only')
else:raise SystemExit('unexpected command')
''')
        fake.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        TMPDIR=str(Path(self.temp.name)), CALL_LOG=str(self.log), EXPECTED_SHA=SHA)
        for name in ('INNONETWORK_LOCAL_PATH', 'SWIFTPM_MIRROR_CONFIG', 'GIT_CONFIG_PARAMETERS',
                     'GIT_CONFIG', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
                     'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_INDEX_FILE', 'GIT_NAMESPACE', 'GIT_TEMPLATE_DIR'):
            self.env.pop(name, None)

    def run_fixture(self, selection='6.1.0', sha=SHA, **overrides):
        return subprocess.run(['bash', str(self.script), selection, sha], cwd=self.root,
                              env={**self.env, **overrides}, capture_output=True, text=True, timeout=20)

    def records(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_tag_runs_both_isolated_profiles_and_verifies_exact_pin(self):
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        records = self.records()
        commands = [r['args'] for r in records if 'args' in r]
        self.assertEqual(len(commands), 5)
        roots = set()
        for args in commands[1:]:
            root = args[args.index('--package-path') + 1]
            roots.add(root)
            for flag in ('--cache-path', '--config-path', '--security-path', '--scratch-path'):
                self.assertTrue(args[args.index(flag) + 1].startswith(root + '/'))
            if args[1] == 'run':
                self.assertIn('--force-resolved-versions', args)
                self.assertIn('release', args)
        self.assertEqual(len(roots), 2)
        self.assertTrue(all(not Path(root).exists() for root in roots))
        self.assertEqual({r['profile'] for r in records if 'profile' in r}, {'default', 'core-only'})
        for record in records:
            if 'manifest' in record:
                self.assertIn('exact: "6.1.0"', record['manifest'])
                self.assertNotIn('.package(path:', record['manifest'])
                self.assertIn('AnyResponseDecoder<EmptyResponse>.noContent()', record['source'])
            if 'args' in record:
                self.assertEqual((record['git_global'], record['git_count']), ('/dev/null', '0'))
        receipt = json.loads((self.root / f'.build/published-consumer/published-tag/{SHA}/result.json').read_text())
        self.assertTrue(receipt['public_tag_verified'])
        self.assertEqual(receipt['version'], '6.1.0')
        self.assertEqual(receipt['revision'], SHA)

    def test_candidate_can_prevalidate_source_but_never_claim_a_published_tag(self):
        result = self.run_fixture('--candidate')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = json.loads((self.root / f'.build/published-consumer/candidate-revision/{SHA}/result.json').read_text())
        self.assertFalse(receipt['public_tag_verified'])
        self.assertIsNone(receipt['version'])
        for record in self.records():
            if 'manifest' in record:
                self.assertIn('revision: "' + SHA + '"', record['manifest'])
                self.assertNotIn('exact:', record['manifest'])

    def test_bad_identity_and_process_failures_never_leave_success_receipt(self):
        for failure in ('wrong-sha', 'wrong-version', 'wrong-source', 'branch', 'duplicate', 'missing',
                        'resolve-error', 'run-error', 'lock-race'):
            with self.subTest(failure=failure):
                result = self.run_fixture(FAIL_MODE=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / f'.build/published-consumer/published-tag/{SHA}/result.json').exists())

    def test_inputs_and_source_overrides_fail_before_swift_execution(self):
        for selection, sha in [('v6.1.0', SHA), ('6.01.0', SHA), ('main', SHA), ('6.1.0;echo injected', SHA),
                               ('6.1.0', 'main'), ('6.1.0', 'A' * 40)]:
            with self.subTest(selection=selection, sha=sha):
                self.assertNotEqual(self.run_fixture(selection, sha).returncode, 0)
        for name in ('INNONETWORK_LOCAL_PATH', 'SWIFTPM_MIRROR_CONFIG', 'GIT_CONFIG_PARAMETERS',
                     'GIT_CONFIG', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
                     'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_INDEX_FILE', 'GIT_NAMESPACE', 'GIT_TEMPLATE_DIR'):
            self.assertNotEqual(self.run_fixture(**{name:'/tmp/untrusted'}).returncode, 0)
        self.assertFalse(self.log.exists())

    def test_legacy_git_url_rewrite_cannot_claim_public_tag_availability(self):
        rewrite = "'url.file:///tmp/nonpublic/.insteadof'='https://github.com/'"
        # Exercise real Git's legacy input without changing any configuration.
        git = subprocess.run(
            ['git', 'config', '--get-regexp', r'^url\..*\.insteadof$'], cwd=self.root,
            env={**self.env, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                 'GIT_CONFIG_COUNT': '0', 'GIT_CONFIG_PARAMETERS': rewrite},
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(git.returncode, 0, git.stderr)
        self.assertIn('file:///tmp/nonpublic/', git.stdout)
        result = self.run_fixture(GIT_CONFIG_PARAMETERS=rewrite)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('GIT_CONFIG_PARAMETERS must not override the public source', result.stderr)
        self.assertNotIn(rewrite, result.stderr)
        self.assertFalse(self.log.exists())


if __name__ == '__main__':
    unittest.main()
