#!/usr/bin/env python3
"""Regression tests for the offline seven-language adoption contract."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('readmes', ROOT / 'Scripts/check_current_readmes.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CurrentReadmeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns('.git', '.build', '__pycache__'))

    def mutate(self, name, before, after):
        path = self.root / name
        text = path.read_text(encoding='utf-8')
        self.assertIn(before, text)
        path.write_text(text.replace(before, after), encoding='utf-8')

    def test_current_guides_pass(self):
        self.assertEqual(MODULE.validate(self.root), [])

    def test_missing_translation_fails(self):
        (self.root / 'README.ru.md').unlink()
        self.assertTrue(MODULE.validate(self.root))

    def test_missing_contract_fails(self):
        self.mutate('README.ko.md', 'NetworkFailure', 'OtherFailure')
        self.assertTrue(any('missing shared contract NetworkFailure' in e for e in MODULE.validate(self.root)))

    def test_swift_example_drift_fails(self):
        self.mutate('README.es.md', 'GetUser(id: 42)', 'GetUser(id: 99)')
        self.assertTrue(any('Swift examples differ' in e for e in MODULE.validate(self.root)))

    def test_broken_link_fails(self):
        self.mutate('README.ja.md', '](LICENSE)', '](missing-license.md)')
        self.assertTrue(any('broken local link' in e for e in MODULE.validate(self.root)))

    def test_missing_section_fails(self):
        self.mutate('README.de.md', '## Migration', 'Migration')
        self.assertTrue(any('nine shared guide sections' in e for e in MODULE.validate(self.root)))


if __name__ == '__main__':
    unittest.main()
