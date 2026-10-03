"""Independent YAML inventory and original protection/readonly release parity."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('merge_policy', ROOT / 'Scripts/dependabot-merge-policy.py')
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)


def workflows():
    names = ['ci.yml', 'release.yml', 'release-validation.yml']
    return json.loads(subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
        'puts ARGV.to_h { |p| [File.basename(p), YAML.safe_load(File.read(p), aliases: false)] }.to_json',
        *[str(ROOT / '.github/workflows' / n) for n in names]], text=True))


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.docs = workflows()

    def test_original_lanes_commands_and_matrix_remain_intact(self):
        old = json.loads((Path(__file__).parent/'fixtures/legacy-ci-contract.json').read_text())['jobs']
        for name, contract in old.items():
            current = self.docs['ci.yml']['jobs'][name]
            for key, value in contract.items():
                if name == 'consumer-smoke' and key == 'name':
                    self.assertTrue(current[key].endswith("'Consumer Smoke' }}"))
                elif key != 'steps': self.assertEqual(current.get(key), value, (name, key))
            for expected in contract['steps']:
                matching = [s for s in current['steps'] if s.get('name') == expected['name']]
                self.assertEqual(len(matching), 1)
                self.assertEqual({k:v for k,v in matching[0].items() if k in ['name','run','if','continue-on-error','working-directory']}, expected)

    def test_codeql_stays_uncached_with_every_native_validation_gate(self):
        job = self.docs['ci.yml']['jobs']['codeql']
        self.assertEqual(job['permissions'], {'contents':'read', 'actions':'read', 'security-events':'write'})
        self.assertEqual([step['name'] for step in job['steps']],
                         ['Checkout', 'Select Xcode', 'Initialize CodeQL', 'Build', 'Perform CodeQL Analysis'])
        for step in job['steps']:
            self.assertNotIn('if', step)
            self.assertNotIn('continue-on-error', step)
            self.assertNotIn('cache', step.get('uses', ''))
            self.assertNotIn('ci-cache.py', step.get('run', ''))
        self.assertEqual(job['if'], 'fromJSON(needs.ci-plan.outputs.plan).jobs.codeql')
        self.assertIn('codeql', self.docs['ci.yml']['jobs']['ci-required']['needs'])

    def test_readonly_candidate_preserves_all_release_validation_commands(self):
        release = self.docs['release.yml']['jobs']
        candidate = self.docs['release-validation.yml']['jobs']
        self.assertEqual(set(candidate), {'validate-release', 'validate-platform-builds'})
        for name, current in candidate.items():
            old = release[name]
            for key in ['name', 'runs-on', 'timeout-minutes', 'permissions', 'strategy']:
                self.assertEqual(current.get(key), old.get(key))
            for step in old['steps']:
                if step['name'] in ['Validate release ref', 'Validate release candidate']: continue
                found = [s for s in current['steps'] if s.get('name') == step['name']]
                self.assertEqual(len(found), 1)
                for key in ['run','if','continue-on-error','working-directory']:
                    self.assertEqual(found[0].get(key), step.get(key))
        self.assertEqual(self.docs['ci.yml']['jobs']['release-candidate']['with'], {'publish':False})
        proof = next(s for s in candidate['validate-release']['steps'] if s['name']=='Validate immutable CI candidate')
        self.assertIn('test "$PUBLISH" = \'false\'', proof['run'])
        self.assertIn('test "$(git rev-parse HEAD)" = "$EXPECTED_SHA"', proof['run'])

    def test_every_concrete_job_and_named_step_matches_coordinator(self):
        actual = {}
        def expand(document, prefix=''):
            for key, job in document['jobs'].items():
                name = job.get('name', key)
                if key == 'ci-required': name = 'CI Required'
                if key == 'consumer-smoke': name = 'Consumer Smoke'
                if 'uses' in job:
                    expand(self.docs[job['uses'].rsplit('/',1)[1]], prefix+name+' / ')
                    continue
                matrix = job.get('strategy',{}).get('matrix',{})
                if 'include' in matrix: rows = matrix['include']
                elif 'xcode' in matrix: rows = [{'xcode':x} for x in matrix['xcode']]
                elif 'language' in matrix: rows = [{'language':x} for x in matrix['language']]
                else:
                    self.assertFalse(matrix, 'new matrix needs explicit inventory')
                    rows = [{}]
                for row in rows:
                    def render(text):
                        for key,value in row.items():
                            if isinstance(value,dict):
                                for field,v in value.items(): text=text.replace('${{ matrix.'+key+'.'+field+' }}',str(v))
                            else: text=text.replace('${{ matrix.'+key+' }}',str(value))
                        self.assertNotIn('${{ matrix.',text)
                        return text
                    label=prefix+render(name)
                    if row and '${{ matrix.' not in name: label+=' ('+', '.join(str(v) for v in row.values())+')'
                    self.assertNotIn(label,actual)
                    actual[label]=[render(s['name']) for s in job['steps'] if 'name' in s]
        expand(self.docs['ci.yml'])
        self.assertEqual(actual,p.CORE)
        plan_spec = importlib.util.spec_from_file_location('plan', ROOT / 'Scripts/ci-policy.py')
        plan = importlib.util.module_from_spec(plan_spec); plan_spec.loader.exec_module(plan)
        ci = self.docs['ci.yml']['jobs']
        self.assertEqual(set(ci), set(plan.JOBS) | {'ci-plan', 'ci-required'})
        self.assertEqual(set(ci['ci-required']['needs']), set(plan.JOBS) | {'ci-plan'})
        self.assertEqual(ci['ci-plan']['if'], "${{ !(github.event_name == 'pull_request' && (((github.event.action == 'labeled' || github.event.action == 'unlabeled') && github.event.label.name && github.event.label.name != 'release-validation' && github.event.label.name != 'concurrency-review') || (github.event.action == 'edited' && !github.event.changes.base))) }}")
        self.assertEqual(ci['ci-required']['if'], '${{ always() }}')
        for name in plan.JOBS:
            if name == 'policy': continue
            guard = ci[name]['if']
            expected = 'fromJSON(needs.ci-plan.outputs.plan).jobs.' + name
            reused = {'lint', 'dead-code', 'parallel-tests', 'apple-platform-build-smoke', 'thread-sanitizer'}
            if name in reused:
                self.assertEqual(guard, "needs.ci-plan.outputs." + name + " == 'true'")
            else:
                self.assertEqual(guard, "${{ always() && !(github.event_name == 'pull_request' && (((github.event.action == 'labeled' || github.event.action == 'unlabeled') && github.event.label.name && github.event.label.name != 'release-validation' && github.event.label.name != 'concurrency-review') || (github.event.action == 'edited' && !github.event.changes.base))) && " + expected + ' }}' if name == 'consumer-smoke' else expected)

        for name,job in self.docs['ci.yml']['jobs'].items():
            for step in job.get('steps',[]):
                if step.get('uses','').startswith('actions/checkout@'):
                    self.assertIs(step.get('with',{}).get('persist-credentials'),False)


if __name__ == '__main__': unittest.main()
