"""Dependency range, supply-chain boundary and OSS consistency negative controls."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('operations', ROOT / 'Scripts/check-public-operations.py')
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)


class PublicOperationsTests(unittest.TestCase):
    def test_current_contract(self): p.validate(ROOT)

    def test_corrupted_operations_are_rejected(self):
        changes = [('.github/dependabot.yml', '"weekly"', '"daily"'),
                   ('.github/dependabot.yml', '"minor",', '"major",'),
                   ('.github/dependabot.yml', '"github.com/swiftlang/swift-syntax"', '"none"'),
                   ('Package.resolved', '"603.0.2"', '"604.0.0"'),
                   ('Package.resolved', '"1.6.0"', '"1.5.0"'),
                   ('.spi.yml', 'https://innosquadcorp.github.io/InnoNetwork/', 'https://invalid.example/'),
                   ('docs/public-docc-products.txt', 'InnoNetworkTrust\n', ''),
                   ('.github/workflows/dependabot-auto-merge.yml', 'ref: refs/heads/main', 'ref: ${{ github.event.pull_request.head.sha }}'),
                   ('.github/workflows/dependabot-auto-merge.yml', 'persist-credentials: false', 'persist-credentials: true'),
                   ('.github/workflows/dependabot-auto-merge.yml', '      checks: write', '      checks: read'),
                   ('.github/workflows/dependabot-review-notice.yml', 'permissions: {}', 'permissions: write-all'),
                   ('.github/workflows/release-validation.yml', '  contents: read', '  contents: write')]
        for path, old, new in changes:
            with self.subTest(path=path, old=old), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)/'repo'
                shutil.copytree(ROOT, root, ignore=shutil.ignore_patterns('.git', '.build', '__pycache__'))
                file = root/path; text=file.read_text(); self.assertIn(old,text);file.write_text(text.replace(old,new,1))
                with self.assertRaises((ValueError, KeyError)): p.validate(root)
