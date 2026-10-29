"""Dependency range, supply-chain boundary and OSS consistency negative controls."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('operations', ROOT / 'Scripts/check-public-operations.py')
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
GENERATED = shutil.ignore_patterns('.git', '.build', 'build', '.gradle', 'node_modules', 'output', '__pycache__')


class PublicOperationsTests(unittest.TestCase):
    def test_current_contract(self): p.validate(ROOT)

    def test_corrupted_operations_are_rejected(self):
        changes = [('.github/workflows/ci.yml', '- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1', '- uses: actions/checkout@v7'),
                   ('.github/workflows/ci.yml', '- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1', '- uses: actions/checkout@' + 'a' * 40),('.github/workflows/dependabot-auto-merge.yml', 'sparse-checkout: Scripts', 'sparse-checkout: Scripts\n          allow-unsafe-pr-checkout: ${{ true }}'),('.github/actions/consumer-cache/action.yml', '55cc8345863c7cc4c66a329aec7e433d2d1c52a9', 'a' * 40),
                   ('.github/actions/consumer-cache/action.yml', '55cc8345863c7cc4c66a329aec7e433d2d1c52a9', 'v6'),('.github/dependabot.yml', '"weekly"', '"daily"'),
                   ('.github/dependabot.yml', '"minor",', '"major",'),
                   ('.github/dependabot.yml', '"github.com/swiftlang/swift-syntax"', '"none"'),
                   ('Package.resolved', '"604.0.0"', '"605.0.0"'),
                   ('Package.resolved', '"5.0.0"', '"6.0.0"'),
                   ('Package.resolved', '"1.8.0"', '"1.5.0"'),
                   ('.spi.yml', 'https://innosquadcorp.github.io/InnoNetwork/', 'https://invalid.example/'),
                   ('docs/public-docc-products.txt', 'InnoNetworkTrust\n', ''),
                   ('docs/site/index.html', './InnoNetworkMacroSupport/documentation/innonetworkmacrosupport', './missing-macro-support'),
                   ('.github/workflows/dependabot-auto-merge.yml', 'ref: ${{ github.workflow_sha }}', 'ref: ${{ github.event.pull_request.head.sha }}'),
                   ('.github/workflows/dependabot-auto-merge.yml', 'ref: ${{ github.workflow_sha }}', 'ref: refs/heads/main'),
                   ('.github/workflows/dependabot-auto-merge.yml', '    needs: [inspect, bot-ready]', '    needs: inspect'),
                   ('.github/workflows/dependabot-auto-merge.yml', " || needs.bot-ready.result == 'failure'", ''),
                   ('.github/workflows/dependabot-auto-merge.yml', "needs.bot-ready.result == 'failure'", "needs.bot-ready.result == 'cancelled'"),
                   ('.github/workflows/dependabot-auto-merge.yml', "if: ${{ steps.gate.outputs.arm_receipt != '' }}", 'if: always()'),
                   ('.github/workflows/dependabot-auto-merge.yml', 'persist-credentials: false', 'persist-credentials: true'),
                   ('.github/workflows/dependabot-auto-merge.yml', '      checks: read', '      checks: write'),
                   ('.github/workflows/dependabot-review-notice.yml', 'permissions: {}', 'permissions: write-all'),
                   ('.github/workflows/dependabot-rebase.yml', '      pull-requests: read', '      pull-requests: write'),
                   ('.github/workflows/dependabot-rebase.yml', 'persist-credentials: false', 'persist-credentials: true'),
                   ('.github/workflows/dependabot-rebase.yml', "vars.DEPENDABOT_AUTO_MERGE_ENABLED }}", "vars.DEPENDABOT_AUTO_MERGE_ENABLED }}\n          LEAK: ${{ secrets.DEPENDABOT_COMMAND_TOKEN }}"),
                   ('.github/workflows/dependabot-rebase.yml', "dependabot-rebase.yml@refs/heads/main'", "dependabot-rebase.yml@refs/heads/feature'"),
                   ('.github/workflows/release-validation.yml', '  contents: read', '  contents: write')]
        for path, old, new in changes:
            with self.subTest(path=path, old=old), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)/'repo'
                shutil.copytree(ROOT, root, ignore=GENERATED)
                file = root/path; text=file.read_text(); self.assertIn(old,text);file.write_text(text.replace(old,new,1))
                with self.assertRaises((ValueError, KeyError)): p.validate(root)

    def test_yaml_workflow_and_composite_extensions_are_checked(self):
        for path in ['.github/workflows/future.yaml', '.github/actions/future/action.yaml']:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)/'repo'
                shutil.copytree(ROOT, root, ignore=GENERATED)
                file = root/path; file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('steps:\n  - uses: actions/checkout@v7\n')
                with self.assertRaises(ValueError): p.action_pins(root)

    def test_generated_dependency_manifests_do_not_expand_owned_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'repo'
            shutil.copytree(ROOT, root, ignore=GENERATED)
            cached = root / 'Examples/Consumer/.build/checkouts/Dependency/Package.swift'
            cached.parent.mkdir(parents=True)
            cached.write_text('url: "https://example.invalid/dependency"')
            p.dependabot(root)
            owned = root / 'Examples/Consumer/Package.swift'
            owned.write_text(cached.read_text())
            with self.assertRaisesRegex(ValueError, 'new remote manifest'):
                p.dependabot(root)

    def test_native_dependency_inventory_keeps_all_safety_controls(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'repo'
            shutil.copytree(ROOT, root, ignore=GENERATED)
            path = root / '.github/dependabot.yml'
            original = json.loads(path.read_text())
            for ecosystem, change in [
                    ('gradle', lambda item: item.update(directories=['/'])),
                    ('npm', lambda item: item.update(directories=['/Platforms/Web'])),
                    ('gradle', lambda item: item['groups']['android-minor-patch'].update({'update-types': ['major']})),
                    ('npm', lambda item: item.update(ignore=[{'dependency-name': '*'}])),
                    ('npm', lambda item: item['schedule'].update(interval='daily')),
                    ('swift', lambda item: item['groups']['swift-minor-patch'].pop('exclude-patterns'))]:
                with self.subTest(ecosystem=ecosystem, change=change):
                    config = json.loads(json.dumps(original))
                    change(next(item for item in config['updates'] if item['package-ecosystem'] == ecosystem))
                    path.write_text(json.dumps(config))
                    with self.assertRaises(ValueError):
                        p.dependabot(root)
            config = json.loads(json.dumps(original))
            config['updates'].append(config['updates'][-1])
            path.write_text(json.dumps(config))
            with self.assertRaises(ValueError):
                p.dependabot(root)
            path.write_text(json.dumps(original))
            generated = root / 'Platforms/Web/node_modules/third-party/package.json'
            generated.parent.mkdir(parents=True)
            generated.write_text('{}')
            p.dependabot(root)
            owned = root / 'SmokeTests/NewConsumer/package.json'
            owned.parent.mkdir(parents=True)
            owned.write_text('{}')
            with self.assertRaisesRegex(ValueError, 'owned manifest inventory'):
                p.dependabot(root)
