"""Preserve real deployed-route checks; fake HTTP transport covers 404/error paths."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DeployedRouteSmokeTests(unittest.TestCase):
    def test_root_every_product_and_failure_are_blocking(self):
        workflow = json.loads(subprocess.check_output(['ruby','-ryaml','-rjson','-e',
            'puts YAML.safe_load(File.read(ARGV[0]), aliases: false).to_json',
            str(ROOT/'.github/workflows/docs-publish.yml')],text=True))
        job = workflow['jobs']['smoke-docs']
        self.assertEqual(job['permissions'], {'contents':'read'})
        self.assertEqual(job['needs'], 'deploy-docs')
        checkout = job['steps'][0]
        self.assertEqual(checkout['with']['ref'], '${{ github.workflow_sha }}')
        self.assertFalse(checkout['with']['persist-credentials'])
        self.assertEqual(checkout['with']['sparse-checkout'], 'docs/public-docc-products.txt')
        step = next(s for s in job['steps'] if s.get('name') == 'Smoke deployed DocC URLs')
        self.assertNotIn('continue-on-error', step)
        self.assertIn('--retry 12 --retry-delay 5 --retry-all-errors',step['run'])
        self.assertIn('--connect-timeout 10 --max-time 30',step['run'])
        base = 'https://innosquadcorp.github.io/InnoNetwork'
        expected = [base+'/'] + [base+'/'+p+'/documentation/'+p.lower()+'/' for p in (ROOT/'docs/public-docc-products.txt').read_text().splitlines()]
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            curl = tmp/'curl'
            curl.write_text('#!/bin/bash\nurl="${@: -1}"\nprintf "%s\\n" "$url" >> "$URL_LOG"\n[[ "$url" != "$FAIL_URL" ]] || exit 22\n')
            curl.chmod(0o755)
            for failure in ['', expected[0], expected[3]]:
                log = tmp/'urls';log.write_text('')
                result = subprocess.run(['bash','-c',step['run']],cwd=ROOT,
                    env=dict(os.environ,PATH=str(tmp)+':'+os.environ['PATH'],SITE_URL=base,URL_LOG=str(log),FAIL_URL=failure),capture_output=True,text=True)
                visited = log.read_text().splitlines()
                if failure:
                    self.assertNotEqual(result.returncode,0)
                    self.assertEqual(visited, expected[:expected.index(failure)+1])
                else:
                    self.assertEqual(result.returncode,0,result.stderr)
                    self.assertEqual(visited,expected)
