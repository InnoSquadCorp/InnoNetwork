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
        changes = [('.github/workflows/ci.yml', '- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1', '- uses: actions/checkout@v7'),
                   ('.github/workflows/ci.yml', '- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1', '- uses: actions/checkout@' + 'a' * 40),('.github/workflows/dependabot-auto-merge.yml', 'sparse-checkout: Scripts', 'sparse-checkout: Scripts\n          allow-unsafe-pr-checkout: ${{ true }}'),('.github/actions/consumer-cache/action.yml', '55cc8345863c7cc4c66a329aec7e433d2d1c52a9', 'a' * 40),
                   ('.github/actions/consumer-cache/action.yml', '55cc8345863c7cc4c66a329aec7e433d2d1c52a9', 'v6'),('.github/dependabot.yml', '"weekly"', '"daily"'),
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

    def test_yaml_workflow_and_composite_extensions_are_checked(self):
        for path in ['.github/workflows/future.yaml', '.github/actions/future/action.yaml']:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)/'repo'
                shutil.copytree(ROOT, root, ignore=shutil.ignore_patterns('.git', '.build', '__pycache__'))
                file = root/path; file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('steps:\n  - uses: actions/checkout@v7\n')
                with self.assertRaises(ValueError): p.action_pins(root)
