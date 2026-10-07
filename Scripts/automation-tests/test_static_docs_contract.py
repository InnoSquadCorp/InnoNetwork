"""Real compiler-free documentation contracts and compiler boundary controls."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class StaticDocsContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns('.git', '.build', '__pycache__'))
        binary = Path(self.temp.name) / 'bin'
        binary.mkdir()
        self.marker = Path(self.temp.name) / 'compiler-called'
        for name in ('swift', 'swiftc', 'xcrun'):
            p = binary / name
            p.write_text('#!/bin/sh\necho called >> "$COMPILER_MARKER"\nexit 93\n')
            p.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(binary) + ':' + os.environ['PATH'], 'COMPILER_MARKER': str(self.marker)}

    def run_check(self, *args):
        return subprocess.run(['bash', 'Scripts/check_docs_contract_sync.sh', *args], cwd=self.root,
                              env=self.env, capture_output=True, text=True)

    def test_static_contract_runs_without_compiler(self):
        result = self.run_check('--static-only')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.marker.exists())

    def test_required_prose_is_not_silently_ignored(self):
        for file, literal in [('README.md', 'Examples: [Examples/README.md](Examples/README.md)'),
                              ('docs/CI_DoC.md', 'Dependency Review')]:
            with self.subTest(file=file):
                path = self.root / file
                original = path.read_text()
                self.assertIn(literal, original)
                path.write_text(original.replace(literal, 'Removed contract text'))
                result = self.run_check('--static-only')
                path.write_text(original)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(self.marker.exists())

    def test_default_contract_still_requires_compiler(self):
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.marker.exists(), result.stdout + result.stderr)

    def test_unknown_mode_rejected(self):
        self.assertEqual(self.run_check('--skip-validation').returncode, 64)
        self.assertFalse(self.marker.exists())


if __name__ == '__main__':
    unittest.main()
