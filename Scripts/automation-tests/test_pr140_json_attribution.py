"""The opt-in attribution experiment must not replace or publish a CI verdict."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/benchmarks.yml'
HELPER = ROOT / 'Scripts/run_pr140_json_attribution.sh'


def validate(workflow, helper):
    def require(condition):
        if not condition:
            raise ValueError('unsafe PR140 attribution contract')

    jobs = dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)',
                           workflow.split('\njobs:\n', 1)[1], re.M | re.S))
    require(set(jobs) == {'run-benchmarks', 'pr140-json-diagnostic', 'append-trend'})
    require('        type: boolean\n        required: false\n        default: false' in workflow)
    require("    if: github.event_name != 'workflow_dispatch' || !inputs.pr140_json_diagnostic\n" in jobs['run-benchmarks'])
    require("    if: success() && !inputs.pr140_json_diagnostic && (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch')\n" in jobs['append-trend'])
    require('options: [attribution, threeway]' in workflow and 'default: attribution' in workflow)
    diagnostic = jobs['pr140-json-diagnostic']
    require("    if: github.event_name == 'workflow_dispatch' && inputs.pr140_json_diagnostic\n" in diagnostic)
    permissions = re.search(r'^    permissions:\n((?:^      [\w-]+: \w+\n)+)', diagnostic, re.M)
    require(permissions is not None and permissions[1] == '      contents: read\n')
    for marker in ['    timeout-minutes: 50', 'persist-credentials: false',
                   'xcrun swift --version', 'Xcode_26.0.1.app',
                   "'^Apple Swift version 6[.]2([ .]|$)'",
                   'attribution) bash Scripts/run_pr140_json_attribution.sh ;;',
                   'threeway) python3 Scripts/run_pr140_json_threeway.py ;;',
                   'name: pr140-json-attribution-${{ github.run_id }}-${{ github.run_attempt }}',
                   'path: .build/pr140-json-attribution/', 'if-no-files-found: error']:
        require(marker in diagnostic)
    for unsafe in ['secrets.', 'continue-on-error', 'contents: write', 'append_benchmark_trend',
                   'git push', 'workflow_dispatch', '--regression-reason']:
        require(unsafe not in helper)
    require('secrets.' not in diagnostic and 'continue-on-error' not in diagnostic)
    require('base=e74f322dc46b660e02c22fb601d8e5e79b0c02a8\n' in helper)
    require('candidate=955841b398b96b1bf012c9c06c815e10d345109d\n' in helper)
    require('test "$orchestration" = "$GITHUB_SHA"' in helper)
    require('merge-base --is-ancestor "$base" "$candidate"' in helper)
    require('for path in Sources Benchmarks Scripts/run_same_runner_benchmarks.sh' in helper)
    require('output_dir="$repo_root/.build/pr140-json-attribution"' in helper)
    require(helper.count('bash "$candidate_root/Scripts/run_same_runner_benchmarks.sh"') == 1)
    require(helper.endswith('  --scope json --base-revision "$base" --output-dir "$output_dir" \\\n  --max-regression-percent 20\n'))


class AttributionTests(unittest.TestCase):
    def test_current_contract(self):
        validate(WORKFLOW.read_text(), HELPER.read_text())

    def test_unsafe_workflow_changes_are_rejected(self):
        source, helper = WORKFLOW.read_text(), HELPER.read_text()
        for old, new in [
            ('default: false', 'default: true'),
            ("if: success() && !inputs.pr140_json_diagnostic", 'if: success()'),
            ("if: github.event_name == 'workflow_dispatch' && inputs.pr140_json_diagnostic", 'if: always()'),
            ('path: .build/pr140-json-attribution/', 'path: .build/benchmarks/'),
            ('contents: read', 'contents: write'),
            ("if: github.event_name != 'workflow_dispatch' || !inputs.pr140_json_diagnostic", 'if: false'),
            ('name: pr140-json-attribution-${{', 'name: innonetwork-benchmarks-${{'),
        ]:
            with self.subTest(old=old), self.assertRaises(ValueError):
                validate(source.replace(old, new), helper)

    def test_unsafe_helper_changes_are_rejected(self):
        workflow, source = WORKFLOW.read_text(), HELPER.read_text()
        for old, new in [
            ('--max-regression-percent 20', '--max-regression-percent 30'),
            ('base=e74f322dc46b660e02c22fb601d8e5e79b0c02a8', 'base=main'),
            ('candidate=955841b398b96b1bf012c9c06c815e10d345109d', 'candidate=HEAD'),
            ('--scope json', '--scope runtime'),
            ('test "$orchestration" = "$GITHUB_SHA"', 'true'),
        ]:
            with self.subTest(old=old), self.assertRaises(ValueError):
                validate(workflow, source.replace(old, new))


if __name__ == '__main__':
    unittest.main()
