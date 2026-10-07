#!/usr/bin/env python3
"""Execute default-on native product builds with full fallback and exact skip receipts.

Only ordinary PRs may narrow builds. Tests, release workflows and manifests are
never rewritten. Missing or uncertain proof runs original full commands; explicit false disables selection.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

_spec = importlib.util.spec_from_file_location('product_impact', Path(__file__).with_name('ci-product-impact.py'))
impact = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(impact)
FLOW_PLATFORMS = ('macOS', 'iOS', 'tvOS', 'watchOS', 'visionOS')
ROUTER_CONSUMERS = {
    'InnoRouterMacroFirstSmoke': {'InnoRouter'},
    'InnoRouterDeveloperToolsSmoke': {'InnoRouter', 'InnoRouterInspector', 'InnoRouterTesting'},
}
ROUTER_DESTINATIONS = {
    'iOS': 'generic/platform=iOS Simulator', 'iPadOS': 'generic/platform=iOS Simulator',
    'Mac-Catalyst': 'generic/platform=macOS,variant=Mac Catalyst', 'macOS': 'platform=macOS',
    'tvOS': 'generic/platform=tvOS Simulator', 'watchOS': 'generic/platform=watchOS Simulator',
    'visionOS': 'generic/platform=visionOS Simulator',
}
SHA = re.compile(r'[0-9a-f]{40}')


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True, stderr=subprocess.PIPE).strip()


def regular_source_diff(root, base, head):
    # A suffix alone cannot admit symlinks, executable modes or unresolved/type
    # changes into a narrow source build. Parse Git's NUL-framed raw records.
    raw = subprocess.check_output(['git', '-C', str(root), 'diff', '--raw', '--no-abbrev',
                                   '--no-renames', '-z', base+'...'+head], stderr=subprocess.PIPE)
    fields = raw.decode('utf-8', errors='strict').split('\0')
    if fields.pop() != '' or len(fields) % 2:
        raise ValueError('malformed source mode evidence')
    for descriptor, path in zip(fields[::2], fields[1::2]):
        match = re.fullmatch(r':(100644|000000) (100644|000000) [0-9a-f]{40} [0-9a-f]{40} ([AMD])', descriptor)
        if not match or not path:
            raise ValueError('nonregular/executable/type-changed source requires full builds')


def identity(root):
    sha = git(root, 'rev-parse', 'HEAD')
    if not SHA.fullmatch(sha): raise ValueError('invalid checkout SHA')
    return sha


def admit(root, env, check_output=subprocess.check_output):
    root = Path(root).resolve()
    sha = identity(root)
    base = {'mode': 'full', 'reason': 'product rollout disabled or non-PR event', 'sha': sha,
            'base': None, 'head': None, 'products': [], 'targets': [], 'affected_targets': [], 'graph_sha256': None,
            'manifest_sha256': hashlib.sha256((root/'Package.swift').read_bytes()).hexdigest()}
    if env.get('PRODUCT_SCOPE_ENABLED', '').lower() not in ('', 'true') or env.get('GITHUB_EVENT_NAME') != 'pull_request':
        return base
    try:
        event = json.loads(Path(env['GITHUB_EVENT_PATH']).read_text())
        pr = event['pull_request']
        if event.get('action') not in ('opened', 'synchronize', 'reopened', 'edited', 'labeled', 'unlabeled'):
            raise ValueError('unrecognized PR action')
        labels = pr['labels']
        if not isinstance(labels, list) or any(not isinstance(x, dict) or not isinstance(x.get('name'), str) for x in labels):
            raise ValueError('invalid PR labels')
        author = pr['user']['login']
        if not isinstance(author, str) or not author or author == 'dependabot[bot]' or any(x['name'].lower() == 'release-validation' for x in labels):
            raise ValueError('bot/release validation stays full')
        if event['action'] == 'edited' and not event.get('changes', {}).get('base'):
            raise ValueError('metadata event cannot select build scope')
        if env.get('GITHUB_SHA') != sha:
            raise ValueError('checkout is not exact event candidate')
        base_sha, head_sha = pr['base']['sha'], pr['head']['sha']
        if not all(SHA.fullmatch(x or '') for x in (base_sha, head_sha)):
            raise ValueError('missing exact PR anchors')
        # GitHub PR builds use either the exact head or its exact two-parent
        # test merge. Never project a scope onto a different checkout tree.
        parents = git(root, 'show', '-s', '--format=%P', sha).split()
        if sha != head_sha and parents != [base_sha, head_sha]:
            raise ValueError('candidate does not match PR head or exact merge parents')
        if git(root, 'status', '--porcelain', '--untracked-files=no'):
            raise ValueError('tracked checkout changed before scope admission')
        graph_path = root/'Scripts/ci-product-graph.json'
        graph = json.loads(graph_path.read_text())
        impact.validate(graph)
        roots = {value.rstrip('/') if value.endswith('/') else value.rsplit('/',1)[0] for target in graph['targets'].values() for value in target['inputs']}
        roots.update(value['path'] for value in graph['consumers'].values())
        if git(root,'ls-files','--others','--exclude-standard','--',*sorted(roots)):
            raise ValueError('untracked generated/source/consumer inputs require full builds')
        if graph['manifest_sha256'] != base['manifest_sha256']:
            raise ValueError('manifest graph drift')
        paths = impact.diff_paths(root, base_sha, head_sha)
        regular_source_diff(root, base_sha, head_sha)
        plan = impact.select(graph, paths, base['manifest_sha256'])
        if plan['mode'] != 'scoped-build-plan' or not plan['affected_products']:
            raise ValueError('shared/unknown/test-only change requires full builds')
        if not (root/'Package.resolved').is_file():
            raise ValueError('missing committed dependency lock')
        git(root,'ls-files','--error-unmatch','Package.resolved')
        # SwiftPM itself verifies the reviewed map before any narrow execution.
        # dump-package does not build/test, and no manifest is modified.
        dump = json.loads(check_output(['xcrun', 'swift', 'package', '--package-path', str(root), 'dump-package'], text=True))
        impact.verify_dump(graph, dump)
        return {**base, 'mode': 'scoped', 'reason': 'exact PR graph verified by SwiftPM',
                'base': base_sha, 'head': head_sha, 'products': plan['affected_products'],
                'affected_targets': plan['affected_targets'],
                'targets': sorted({name for product in plan['affected_products'] for name in graph['products'][product]}),
                'graph_sha256': hashlib.sha256(graph_path.read_bytes()).hexdigest()}
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        return {**base, 'reason': 'full fallback: '+str(error)}


def recipe(root, admission, kind, unit, platform, temporary):
    root, temporary = Path(root).resolve(), Path(temporary).resolve()
    if platform != 'macOS': raise ValueError('unreviewed platform')
    if kind == 'network-build':
        if unit != 'package': raise ValueError('unreviewed package build')
        if admission['mode'] == 'scoped':
            commands = [['xcrun','swift','build','--target',target,'--force-resolved-versions'] for target in admission['targets']]
            if not commands: raise ValueError('empty product build cannot succeed')
            return {'decision':'run-scoped','commands':commands}
        return {'decision':'run-full','commands':[['xcrun','swift','build']]}
    examples = {'SampleApp': {'InnoDI'}, 'SwiftUIExample': {'InnoDISwiftUI'}, 'PreviewInjectionExample': {'InnoDISwiftUI'}}
    if kind != 'di-example' or unit not in examples: raise ValueError('unreviewed example')
    directory = str(root/'Examples'/unit)
    if admission['mode'] == 'scoped' and not set(admission['products']) & examples[unit]:
        return {'decision':'skip-unaffected','commands':[],'cwd':directory}
    flags=['-Xswiftc','-strict-concurrency=complete','-Xswiftc','-warnings-as-errors']
    commands=[['swift','build',*flags],['swift','test',*flags]]
    if unit=='SampleApp': commands.append(['swift','run','--skip-build','SampleApp'])
    return {'decision':'run-full' if admission['mode']=='full' else 'run-selected-consumer','commands':commands,'cwd':directory}


def receipt_path(directory, kind, unit, platform):
    if kind not in ('network-build','di-example') or not re.fullmatch(r'[A-Za-z0-9-]+', unit) or not re.fullmatch(r'[A-Za-z0-9-]+', platform):
        raise ValueError('invalid receipt identity')
    return Path(directory)/(kind+'-'+platform+'-'+unit+'.json')


def execute(root, env, kind, unit, platform, temporary, receipts, run=subprocess.run, check_output=subprocess.check_output):
    path=receipt_path(receipts,kind,unit,platform)
    if path.exists(): raise ValueError('receipt already exists; stale success cannot be reused')
    admission=admit(root,env,check_output)
    selected=recipe(root,admission,kind,unit,platform,temporary)
    if selected['decision']=='run-scoped' and not selected['commands']:
        raise ValueError('empty native product command set')
    for command in selected['commands']:
        run(command,cwd=selected.get('cwd',root),check=True)
    proof={'schema':1,'kind':kind,'unit':unit,'platform':platform,'admission':admission,
           **selected,'result':'success','test_scope':'unchanged full test gates remain required'}
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('x') as stream:json.dump(proof,stream,sort_keys=True);stream.write('\n')
    print(json.dumps(proof,sort_keys=True))
    return proof


def verify(root,env,kind,units,platform,temporary,receipts,check_output=subprocess.check_output):
    if not units or len(units)!=len(set(units)): raise ValueError('empty or duplicate required build receipt')
    admission=admit(root,env,check_output)
    for unit in units:
        selected=recipe(root,admission,kind,unit,platform,temporary)
        proof=json.loads(receipt_path(receipts,kind,unit,platform).read_text())
        expected={'schema':1,'kind':kind,'unit':unit,'platform':platform,'admission':admission,
                  **selected,'result':'success','test_scope':'unchanged full test gates remain required'}
        if proof!=expected: raise ValueError('unexplained build skip, stale receipt or changed plan: '+unit)
    print('Verified exact planned build/skip outcomes for '+', '.join(units))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('build','verify'))
    parser.add_argument('--root',type=Path,default=Path('.'))
    parser.add_argument('--kind',choices=('network-build','di-example'),required=True)
    parser.add_argument('--units',nargs='+',required=True)
    parser.add_argument('--platform',required=True)
    parser.add_argument('--temporary',type=Path,required=True)
    parser.add_argument('--receipts',type=Path,required=True)
    args=parser.parse_args()
    if args.action=='build':
        if len(args.units)!=1:raise ValueError('build exactly one reviewed unit per step')
        execute(args.root.resolve(),os.environ,args.kind,args.units[0],args.platform,args.temporary,args.receipts)
    else:verify(args.root.resolve(),os.environ,args.kind,args.units,args.platform,args.temporary,args.receipts)

if __name__=='__main__':main()
