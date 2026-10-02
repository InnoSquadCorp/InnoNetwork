#!/usr/bin/env python3
"""Repository-local dependency coherence and privileged workflow boundaries (offline)."""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = 'Tools/openapi-to-innonetwork'
PERMISSIONS = {
    'inspect': {'contents': 'read', 'actions': 'read', 'checks': 'read', 'pull-requests': 'read'},
    'ready-plan': {'contents': 'read', 'actions': 'read', 'checks': 'read', 'pull-requests': 'read'},
    'ready-refresh': {'contents': 'read', 'actions': 'write', 'checks': 'read', 'pull-requests': 'read'},
    'bot-ready': {'contents': 'write', 'actions': 'read', 'checks': 'read', 'pull-requests': 'write'},
    'post-merge-plan': {'contents': 'read', 'actions': 'read', 'pull-requests': 'read'},
    'post-merge': {'contents': 'read', 'actions': 'write', 'pull-requests': 'read'},
}


def require(value, reason):
    if not value:
        raise ValueError(reason)


def dependabot(root):
    config = json.loads((root / '.github/dependabot.yml').read_text())
    require(config.get('version') == 2, 'Dependabot schema version changed')
    updates = config.get('updates', [])
    require(len(updates) == 2, 'exact Actions and Swift update inventory required')
    by_kind = {u.get('package-ecosystem'): u for u in updates}
    require(set(by_kind) == {'github-actions', 'swift'}, 'wrong Dependabot ecosystem inventory')
    for ecosystem, minute, limit, prefix, group, label in [
        ('github-actions', '09:00', 5, 'chore(ci)', 'actions-minor-patch', 'github-actions'),
        ('swift', '09:30', 3, 'chore(deps)', 'swift-minor-patch', 'swift')]:
        item = by_kind[ecosystem]
        require(item.get('schedule') == {'interval': 'weekly', 'day': 'monday', 'time': minute, 'timezone': 'Asia/Seoul'}, 'weekly schedule drift')
        require(item.get('open-pull-requests-limit') == limit, 'version PR limit drift')
        require(item.get('commit-message') == {'prefix': prefix}, 'commit prefix drift')
        require(item.get('labels') == ['dependencies', label, 'release-validation'], 'dependency labels drift')
        groups = item.get('groups', {})
        require(set(groups) == {group}, 'low-risk group inventory drift')
        expected = {'patterns': ['*'], 'update-types': ['minor', 'patch']}
        if ecosystem == 'swift':
            expected['exclude-patterns'] = ['github.com/swiftlang/swift-syntax']
            require(item.get('directories') == ['/', '/' + SAMPLE] and 'directory' not in item, 'live Swift manifest inventory drift')
            live = sorted(str(p.parent.relative_to(root)) for p in list((root / 'Examples').rglob('Package.swift')) + list((root / 'Tools').rglob('Package.swift')) if 'url:' in p.read_text())
            require(live == [SAMPLE], 'new remote manifest needs explicit policy review')
        else:
            require(item.get('directory') == '/' and 'directories' not in item, 'Actions directory drift')
        require(groups[group] == expected, 'major/toolchain updates must remain individual, not ignored')
        require(not item.get('ignore') and not item.get('allow') and not item.get('exclude-paths'), 'dependency updates must not be silently excluded')


def coherence(root):
    manifest = (root / 'Package.swift').read_text()
    require(manifest.startswith('// swift-tools-version: 6.2'), 'minimum Swift tools contract changed')
    lock = json.loads((root / 'Package.resolved').read_text())
    pins = lock.get('pins', [])
    require(lock.get('version') == 3 and len({p['identity'] for p in pins}) == len(pins), 'invalid/duplicate root lock')
    by_identity = {p['identity']: p for p in pins}
    for pin in pins:
        require(pin.get('kind') == 'remoteSourceControl' and re.fullmatch(r'[0-9a-f]{40}', pin['state'].get('revision', '')), 'immutable remote revision required')
    declarations = re.findall(r'\.package\(\s*url: "([^"]+)",\s*\.(upToNextMajor|upToNextMinor)\(from: "([0-9.]+)"\)\s*\)', manifest)
    require(len(declarations) == 4, 'root dependency constraint inventory changed')
    for url, kind, low in declarations:
        identity = url.rstrip('/').rsplit('/', 1)[1].removesuffix('.git').lower()
        pin = by_identity[identity]
        require(pin['location'] == url, 'manifest/lock source mismatch: ' + identity)
        version = tuple(map(int, pin['state']['version'].split('.')))
        minimum = tuple(map(int, low.split('.')))
        require(len(version) == len(minimum) == 3 and version >= minimum, 'lock is below manifest floor')
        width = 1 if kind == 'upToNextMajor' else 2
        require(version[:width] == minimum[:width], 'lock is outside manifest range: ' + identity)
    # Local consumers intentionally resolve the root manifest, without a second
    # independently pinned root or copied SwiftSyntax constraint.
    for manifest in (root / 'Examples').glob('*/Package.swift'):
        text = manifest.read_text()
        require('.package(name: "InnoNetwork", path: "../.."' in text and 'url:' not in text, 'example resolution drift')
    spi = json.loads((root / '.spi.yml').read_text())
    require(spi == {'version': 1, 'external_links': {'documentation': 'https://innosquadcorp.github.io/InnoNetwork/'}}, 'SPI docs URL drift')
    require('https://innosquadcorp.github.io/InnoNetwork/' in (root / 'README.md').read_text(), 'README docs link drift')
    products = (root / 'docs/public-docc-products.txt').read_text().splitlines()
    exported = re.findall(r'\.library\(\s*name: "([^"]+)"', (root / 'Package.swift').read_text())
    require(set(products) == set(exported) and len(products) == len(set(products)), 'DocC/public product inventory drift')


def workflow_boundaries(root):
    source = (root / '.github/workflows/dependabot-auto-merge.yml').read_text()
    jobs_text = source.split('\njobs:\n', 1)[1]
    jobs = {m[1]: m[2] for m in re.finditer(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', jobs_text, re.M | re.S)}
    require(set(jobs) == set(PERMISSIONS), 'unexpected coordinator job')
    for name, expected in PERMISSIONS.items():
        job = jobs[name]
        if name in {'ready-refresh', 'bot-ready'}:
            require(re.search(r'^    strategy:\n      fail-fast: false\n      matrix:', job, re.M),
                    name + ': independent PR matrix must not fail fast')
        block = re.search(r'^    permissions:\n((?:^      [\w-]+: (?:read|write|none)\n)+)', job, re.M)
        require(block is not None, name + ': missing explicit dedicated permissions')
        found = dict(re.findall(r'^      ([\w-]+): (read|write|none)$', block[1], re.M))
        require(found == expected, name + ': permissions expanded or missing')
        if name in {'ready-refresh', 'bot-ready', 'post-merge'}:
            require('      cancel-in-progress: false' in job and '      queue: max' in job,
                    name + ': serialized writers must retain pending work')
        trusted_ref = 'ref: ${{ github.workflow_sha }}' if name == 'inspect' else 'ref: refs/heads/main'
        require(job.count(trusted_ref) == 1 and job.count('persist-credentials: false') == 1 and job.count('sparse-checkout: Scripts') == 1, name + ': trusted checkout contract missing')
        if name == 'inspect':
            require('name: Resolve authoritative API targets from ${{ github.workflow_sha }}' in job,
                    'inspector must expose immutable native source attribution')
        require("github.ref == 'refs/heads/main'" in job and "github.workflow_ref == 'InnoSquadCorp/InnoNetwork/.github/workflows/dependabot-auto-merge.yml@refs/heads/main'" in job, name + ': trusted execution guard missing')
    for unsafe in ['pull_request.head', 'secrets.', 'download-artifact', 'cache@', 'gh pr merge', 'pip install', 'npm install', 'continue-on-error']:
        require(unsafe not in source, 'unsafe privileged coordinator input: ' + unsafe)
    reporter = (root / '.github/workflows/dependabot-ready.yml').read_text()
    require('pull_request_target:\n    branches: [main]' in reporter and 'run-name:' in reporter and 'Ready v1 pr:' in reporter,
            'native reporter requires trusted event binding')
    require('ref: ${{ github.workflow_sha }}' in reporter and 'persist-credentials: false' in reporter and
            'sparse-checkout: Scripts' in reporter, 'native reporter must checkout immutable trusted source')
    require(reporter.count('    name: Dependabot Merge Ready') == 1 and '\n    if:' not in reporter,
            'Ready must be exactly one unconditional native job')
    require('        if: always()' in reporter and 'run: test "$READY" = \'true\'' in reporter,
            'Ready must fail closed on an absent verdict')
    for unsafe in [': write', 'secrets.', 'download-artifact', 'cache@', 'pip install', 'npm install', 'continue-on-error']:
        require(unsafe not in reporter, 'unsafe native reporter input: ' + unsafe)
    notice = (root / '.github/workflows/dependabot-review-notice.yml').read_text()
    require('permissions: {}' in notice and 'uses:' not in notice and 'secrets.' not in notice and 'GH_TOKEN' not in notice, 'review notice must be inert and zero-permission')
    for path in ['release-validation.yml', 'docc-pages.yml']:
        workflow = (root / '.github/workflows' / path).read_text()
        require(not re.search(r'^\s+(?:contents|actions|checks|pull-requests|pages|id-token):\s*write', workflow, re.M), path + ': validation token must remain read-only')
        require('secrets: inherit' not in workflow and 'persist-credentials: true' not in workflow, path + ': credential inheritance forbidden')


def action_pins(root):
    # Do not freeze particular action versions: future majors remain eligible.
    # Require one immutable version per action repository across every workflow
    # and local composite, including newly added candidate/publisher jobs.
    pins = {}
    files = [path for suffix in ('yml', 'yaml')
             for path in list((root / '.github/workflows').glob('*.' + suffix)) +
             list((root / '.github/actions').rglob('action.' + suffix))]
    for path in files:
        text = path.read_text()
        require(not re.search(r'^\s*allow-unsafe-pr-checkout:', text, re.M), 'unsafe privileged checkout opt-in forbidden')
        for source in re.findall(r'^\s*(?:-\s+)?uses:\s*(\S+)', text, re.M):
            if source.startswith('./'):
                continue
            match = re.fullmatch(r'([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:/[A-Za-z0-9_./-]+)?@([0-9a-f]{40})', source)
            require(match is not None, 'external action must use an immutable SHA: ' + source)
            pins.setdefault(match[1], set()).add(match[2])
    require(all(len(values) == 1 for values in pins.values()), 'action version drift across workflow/composite copies')


def validate(root):
    dependabot(root)
    coherence(root)
    workflow_boundaries(root)
    action_pins(root)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        validate(args.root)
    except (ValueError, KeyError, OSError, TypeError) as error:
        print('[public-operations] ' + str(error), file=sys.stderr)
        sys.exit(1)
    print('[public-operations] Dependency grouping, lock coherence and token boundaries passed')
