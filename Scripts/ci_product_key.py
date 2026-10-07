#!/usr/bin/env python3
"""Compile-free cancellation partition only; never authorizes a build/test skip."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

SHA=re.compile(r'[0-9a-f]{40}')


def git(root,*args):
    return subprocess.check_output(['git','-C',str(root),*args],text=True,stderr=subprocess.PIPE).strip()


def key_for(root,event,env):
    try:
        if env.get('GITHUB_EVENT_NAME')!='pull_request':return ''
        root=Path(root).resolve();sha=git(root,'rev-parse','HEAD');pr=event['pull_request']
        base,head=pr['base']['sha'],pr['head']['sha']
        if any(not SHA.fullmatch(x or '') for x in (sha,base,head)) or env.get('GITHUB_SHA')!=sha:return ''
        if sha!=head and git(root,'show','-s','--format=%P',sha).split()!=[base,head]:return ''
        if git(root,'status','--porcelain','--untracked-files=no'):return ''
        scripts=Path(__file__).resolve().parent
        # Test fixtures may provide a different root but retain the reviewed
        # implementation from this repository's scripts directory.
        graph_path=root/scripts.name/'ci-product-graph.json'
        graph=json.loads(graph_path.read_text())
        digest=hashlib.sha256((root/'Package.swift').read_bytes()).hexdigest()
        if graph['manifest_sha256']!=digest:return ''
        helper=scripts/'ci-product-impact.py'
        if not helper.exists():helper=scripts/'ci_product_scope.py'
        spec=importlib.util.spec_from_file_location('product_key_graph',helper)
        impact=importlib.util.module_from_spec(spec);spec.loader.exec_module(impact)
        validator=getattr(impact,'validate',None) or impact.validate_graph
        validator(graph)
        roots = sorted({entry['path'] if 'path' in entry else value.rstrip('/')
                        for entry in graph['targets'].values()
                        for value in entry.get('inputs', [entry.get('path', '')])} |
                       {entry['path'] for entry in graph.get('consumers', {}).values()})
        if subprocess.check_output(['git','-C',str(root),'ls-files','--others','--exclude-standard','--',*roots]):return ''
        paths=(getattr(impact,'diff_paths',None) or impact.changed_paths)(root,base,head)
        if not paths:return ''
        for path in paths:
            owners=[]
            for name,target in graph['targets'].items():
                inputs=target.get('inputs',[target.get('path','')+'/'])
                if any(path.startswith(p) if p.endswith('/') else path==p for p in inputs):owners.append(name)
            if len(owners)!=1 or not path.endswith('.swift') or re.search(r'(^|/)(Fixtures|Generated|Resources)(/|$)|\.(pb|generated)\.swift$',path,re.I):return ''
        raw=subprocess.check_output(['git','-C',str(root),'diff','--raw','--no-abbrev','--no-renames','-z',base+'...'+head],stderr=subprocess.PIPE)
        fields=raw.decode('utf-8',errors='strict').split('\0')
        if fields.pop()!='' or len(fields)%2:return ''
        if any(not re.fullmatch(r':(100644|000000) (100644|000000) [0-9a-f]{40} [0-9a-f]{40} [AMD]',x) for x in fields[::2]):return ''
        if 'inputs' in next(iter(graph['targets'].values())):plan=impact.select(graph,paths,digest)
        else:plan=impact.select(graph,paths)
        products=plan.get('affected_products',plan.get('products',[]))
        targets=plan['affected_targets']
        if not targets:return ''
        workload={'products':sorted(products),'targets':sorted(targets),
                  'dependencies':{name:sorted(graph['targets'][name]['dependencies']) for name in sorted(targets)}}
        # No candidate SHA/base/head/run identity enters this stable workload key.
        return 'p-'+hashlib.sha256(json.dumps(workload,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    except (ValueError,KeyError,TypeError,OSError,subprocess.CalledProcessError):
        return ''


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--event',required=True,type=Path)
    args=parser.parse_args()
    try:event=json.loads(args.event.read_text())
    except (ValueError,OSError):event={}
    key=key_for(Path('.'),event,os.environ)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'],'a') as stream:stream.write('product-key='+key+'\n')
    print('Cancellation product partition: '+(key or 'unavailable; scoped jobs stay run-unique and non-cancelling'))

if __name__=='__main__':main()
