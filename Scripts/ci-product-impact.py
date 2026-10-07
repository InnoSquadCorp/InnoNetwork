#!/usr/bin/env python3
"""Plan target/product impact only; never execute, prune manifests or weaken CI."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def valid_path(path):
    return isinstance(path, str) and bool(path) and not path.startswith('/') and not any(ord(c) < 32 or ord(c) == 127 for c in path) and '\\' not in path and all(p not in ('', '.', '..') for p in path.rstrip('/').split('/'))


def validate(graph):
    if set(graph) != {'schema', 'manifest_sha256', 'targets', 'products', 'full_targets', 'consumers'} or type(graph['schema']) is not int or graph['schema'] != 1:
        raise ValueError('invalid reviewed graph schema')
    if not re.fullmatch(r'[0-9a-f]{64}', graph['manifest_sha256']):
        raise ValueError('invalid manifest digest')
    targets = graph['targets']
    if not targets or not isinstance(targets, dict):
        raise ValueError('empty target graph')
    seen = set()
    for name, target in targets.items():
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]*', name) or set(target) != {'inputs', 'kind', 'dependencies'}:
            raise ValueError('invalid target')
        if target['kind'] not in ('regular', 'test', 'executable', 'macro', 'plugin', 'binaryTarget'):
            raise ValueError('unknown target kind')
        if not target['inputs'] or not all(valid_path(path) for path in target['inputs']):
            raise ValueError('invalid target inputs')
        for path in target['inputs']:
            if path in seen: raise ValueError('ambiguous target input')
            seen.add(path)
        if len(set(target['dependencies'])) != len(target['dependencies']) or not set(target['dependencies']) <= set(targets):
            raise ValueError('unknown dependency')
    def visit(name, stack):
        if name in stack: raise ValueError('cyclic target dependency')
        for child in targets[name]['dependencies']: visit(child, stack | {name})
    for name in targets: visit(name, set())
    if not graph['products'] or any(not names or not set(names) <= set(targets) for names in graph['products'].values()):
        raise ValueError('unknown product target')
    if not set(graph['full_targets']) <= set(targets): raise ValueError('unknown shared target')
    for consumer in graph['consumers'].values():
        if set(consumer) != {'path', 'products'} or not valid_path(consumer['path']) or not consumer['products'] or not set(consumer['products']) <= set(graph['products']):
            raise ValueError('invalid consumer')


def closure(graph, names):
    result = set(names)
    while True:
        more = result | {child for name in result for child in graph['targets'][name]['dependencies']}
        if more == result: return result
        result = more


def select(graph, paths, manifest_digest=None):
    validate(graph)
    if not isinstance(paths, list) or any(not valid_path(path) for path in paths): raise ValueError('invalid changed paths')
    changed, reasons = set(), []
    if not paths: reasons.append('empty or unavailable diff')
    if manifest_digest is not None and manifest_digest != graph['manifest_sha256']: reasons.append('manifest digest changed')
    for path in paths:
        matches = [name for name, target in graph['targets'].items() if any(path.startswith(p) if p.endswith('/') else path == p for p in target['inputs'])]
        if len(matches) != 1 or not path.endswith('.swift') or re.search(r'(^|/)(?:Fixtures|Generated|Resources)(?:/|$)|\.(?:pb|generated)\.swift$', path, re.I):
            reasons.append('unknown/shared/resource/generated/consumer path: ' + path)
        else: changed.add(matches[0])
    if changed & set(graph['full_targets']): reasons.append('shared core or compiler-plugin contract')
    affected = set(changed)
    while True:
        more = affected | {name for name, target in graph['targets'].items() if set(target['dependencies']) & affected}
        if more == affected: break
        affected = more
    if reasons: affected = set(graph['targets'])
    products = sorted(name for name, names in graph['products'].items() if set(names) & affected)
    tests = sorted(name for name in affected if graph['targets'][name]['kind'] == 'test')
    test_closure = closure(graph, tests)
    test_products = sorted(name for name, names in graph['products'].items() if set(names) & test_closure)
    consumers = sorted(name for name, data in graph['consumers'].items() if set(data['products']) & set(products))
    native_targets = sorted({name for product in products for name in graph['products'][product]} | {name for name in affected if graph['targets'][name]['kind'] == 'executable'})
    return {'schema': 1, 'mode': 'full' if reasons else 'scoped-build-plan', 'reasons': reasons,
            'changed_paths': sorted(set(paths)), 'changed_targets': sorted(changed), 'affected_targets': sorted(affected),
            'affected_products': products, 'affected_tests': tests, 'test_dependency_closure': sorted(test_closure),
            'test_dependency_products': test_products, 'consumers': consumers,
            'native_build_commands': [['swift', 'build', '--target', name, '--scratch-path', '.build/impact/' + name, '--jobs', '1'] for name in native_targets if graph['targets'][name]['kind'] != 'plugin'],
            'test_command': ['swift', 'test', '--scratch-path', '.build/impact/full-tests', '--jobs', '1', '--no-parallel'],
            'test_compilation_scope': 'full package; no --filter compile-scope claim',
            'execution': 'planning only; existing required/platform/release gates unchanged'}


def diff_paths(root, base, head):
    if not all(re.fullmatch(r'[0-9a-f]{40}', value or '') for value in (base, head)): raise ValueError('exact commit SHAs required')
    raw = subprocess.check_output(['git', '-C', str(root), 'diff', '--name-status', '-z', '--find-renames', base+'...'+head], stderr=subprocess.PIPE)
    parts = raw.decode('utf-8', errors='strict').split('\0')
    if parts.pop() != '': raise ValueError('truncated diff')
    paths=[]
    while parts:
        status=parts.pop(0)
        if not re.fullmatch(r'(?:[ADMT]|[RC][0-9]{1,3})',status): raise ValueError('invalid diff status')
        count=2 if status[0] in 'RC' else 1
        if len(parts)<count: raise ValueError('truncated renamed paths')
        paths.extend(parts[:count]);del parts[:count]
    return paths


def verify_dump(graph, dump):
    """Optional offline check against an Apple Swift 6.3/6.4 dump-package file."""
    validate(graph)
    targets={target['name']:target for target in dump['targets']}
    if set(targets)!=set(graph['targets']): raise ValueError('SwiftPM target inventory differs')
    for name, expected in graph['targets'].items():
        target=targets[name]
        if target['type']!=expected['kind']: raise ValueError('SwiftPM target type differs: '+name)
        path=target.get('path') or ('Tests/' if target['type']=='test' else 'Plugins/' if target['type']=='plugin' else 'Sources/')+name
        inputs=([path+'/'+source for source in target['sources']] if target.get('sources') else [path+'/'])
        if sorted(inputs)!=sorted(expected['inputs']): raise ValueError('SwiftPM target inputs differ: '+name)
        dependencies=set()
        for item in target['dependencies']:
            if set(item)=={'product'}: continue
            key='target' if 'target' in item else 'byName'
            if set(item)!={key}: raise ValueError('unknown dependency representation')
            dependencies.add(item[key][0])
        if dependencies!=set(expected['dependencies']): raise ValueError('SwiftPM dependencies differ: '+name)
    products={product['name']:product['targets'] for product in dump['products']}
    if products!=graph['products']: raise ValueError('SwiftPM product inventory differs')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path('.'))
    parser.add_argument('--graph',type=Path,default=Path(__file__).with_name('ci-product-graph.json'))
    parser.add_argument('--base');parser.add_argument('--head')
    parser.add_argument('--output',type=Path);parser.add_argument('--verify-dump',type=Path)
    args=parser.parse_args();graph=json.loads(args.graph.read_text())
    if args.verify_dump:
        verify_dump(graph,json.loads(args.verify_dump.read_text()));print('Reviewed target graph matches SwiftPM dump.');return
    try: paths=diff_paths(args.root,args.base,args.head)
    except (ValueError,OSError,UnicodeError,subprocess.CalledProcessError): paths=[]
    digest=hashlib.sha256((args.root/'Package.swift').read_bytes()).hexdigest()
    plan=select(graph,paths,digest)
    plan.update(base=args.base,head=args.head,manifest_sha256=digest)
    payload=json.dumps(plan,indent=2)+'\n'
    if args.output: args.output.write_text(payload)
    print(payload,end='')

if __name__=='__main__': main()
