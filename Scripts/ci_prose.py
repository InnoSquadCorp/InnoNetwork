"""Exact-blob evidence for a deliberately conservative prose-only PR lane."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

SHA = re.compile(r'[0-9a-f]{40}')
RELEASE = re.compile(r'(?:^|[/_.-])(?:changelog|releasing|release|releases|version|versions|api[-_]stability)(?:[/_.-]|$)', re.I)


def candidate(path):
    if path == '.github/FUNDING.yml':
        return True
    if not isinstance(path, str) or not path.endswith('.md') or RELEASE.search(path):
        return False
    if any(part in ('', '.', '..') for part in path.split('/')) or path.startswith('/') or '\\' in path:
        return False
    return '/' not in path or path.startswith(('docs/', 'Docs/')) or (path.startswith('Sources/') and '.docc/' in path)


def executable_signature(text):
    """Conservative: all fenced/indented blocks and directive/HTML lines matter."""
    result, fence, block = [], None, []
    for line in text.splitlines():
        marker = re.match(r'^\s{0,3}(`{3,}|~{3,})(.*)$', line)
        if fence:
            block.append(line)
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= fence[1] and not marker[2].strip():
                result.append('\n'.join(block)); fence=None; block=[]
        elif marker:
            fence=(marker[1][0],len(marker[1])); block=[line]
        elif re.match(r'^\s*(?:<[A-Za-z/!?]|@[A-Za-z])', line):
            # Opaque HTML/directive bodies can span lines. Without a complete
            # Markdown/DocC parser, any change to such a document is non-prose.
            # Single-line compile-marker comments remain independently hashed.
            if line.lstrip().startswith('<!--') and '-->' in line:
                result.append(line)
            else:
                result.append('opaque-document:' + text)
        elif line.startswith(('    ', '\t')):
            result.append(line)
    if fence:
        raise ValueError('unclosed Markdown code fence')
    return hashlib.sha256('\n'.join(result).encode()).hexdigest()


def git(root, *args):
    return subprocess.check_output(['git','-C',str(root),*args])


def blob(root, commit, path):
    record=git(root,'ls-tree','-z',commit,'--',path).decode().split('\0')
    if len(record)!=2 or record[-1] or '\t' not in record[0]:raise ValueError('missing exact blob')
    info,name=record[0].split('\t',1)
    mode,kind,oid=info.split()
    if name!=path or mode!='100644' or kind!='blob':raise ValueError('non-regular documentation file')
    content=git(root,'cat-file','blob',oid).decode('utf-8','strict')
    if '\x00' in content:raise ValueError('binary documentation')
    return oid,content


def inspect(root, base, head, paths):
    if not SHA.fullmatch(base or '') or not SHA.fullmatch(head or '') or not paths or len(paths)!=len(set(paths)):
        return {}
    if not all(candidate(path) for path in paths):return {}
    try:
        merge=git(root,'merge-base',base,head).decode().strip()
        files=[]
        for path in sorted(paths):
            before,old=blob(root,merge,path); after,new=blob(root,head,path)
            if path=='.github/FUNDING.yml':
                # Funding metadata cannot smuggle YAML tags, aliases or expressions.
                for text in (old,new):
                    if re.search(r'(^|\s)[&*!]|\$\{\{|\x00',text):raise ValueError('unsupported funding metadata')
                signature='funding'
            else:
                signature=executable_signature(old)
                if signature!=executable_signature(new):return {}
            files.append({'path':path,'before':before,'after':after,'signature':signature})
        return {'schema':1,'base':base,'head':head,'merge_base':merge,'files':files}
    except (ValueError,UnicodeError,OSError,subprocess.CalledProcessError):
        return {}


def validate(proof, paths):
    if not isinstance(proof,dict) or set(proof)!={'schema','base','head','merge_base','files'} or type(proof['schema']) is not int or proof['schema']!=1:
        raise ValueError('invalid prose evidence schema')
    if any(not isinstance(proof[key],str) or not SHA.fullmatch(proof[key]) for key in ('base','head','merge_base')):
        raise ValueError('invalid prose evidence commit')
    if not isinstance(proof['files'],list) or not proof['files']:raise ValueError('empty prose evidence')
    names=[]
    for entry in proof['files']:
        if not isinstance(entry,dict) or set(entry)!={'path','before','after','signature'}:raise ValueError('invalid prose blob evidence')
        if not candidate(entry['path']) or any(not isinstance(entry[key],str) or not SHA.fullmatch(entry[key]) for key in ('before','after')):raise ValueError('invalid prose blob')
        if entry['signature']!='funding' and not re.fullmatch(r'[0-9a-f]{64}',entry['signature'] or ''):raise ValueError('invalid prose signature')
        names.append(entry['path'])
    if names!=sorted(set(paths)) or len(names)!=len(paths):raise ValueError('prose evidence must cover every changed path')


def revalidate(root,event,proof,paths):
    validate(proof,paths)
    pr=event.get('pull_request',{})
    base=pr.get('base',{}).get('sha'); head=pr.get('head',{}).get('sha')
    if (base,head)!=(proof['base'],proof['head']):raise ValueError('prose evidence belongs to another PR revision')
    # Recompute actual paths, not an attacker-supplied subset.
    raw=git(root,'diff','--name-status','-z','--no-renames',base+'...'+head).decode('utf-8','strict').split('\0')
    if not raw or raw.pop()!='' or len(raw)%2:raise ValueError('invalid prose change inventory')
    actual=[]
    for index in range(0,len(raw),2):
        if raw[index]!='M':raise ValueError('prose lane requires regular modified files')
        actual.append(raw[index+1])
    if sorted(actual)!=sorted(paths) or inspect(root,base,head,actual)!=proof:raise ValueError('prose evidence does not match immutable Git changes')


def check_files(root,proof):
    """Cheap content checks only; never invokes Swift, Xcode, or package resolution."""
    validate(proof,[entry['path'] for entry in proof['files']])
    for entry in proof['files']:
        path=root/entry['path']
        if not path.is_file() or path.is_symlink():raise ValueError('missing documentation checkout')
        text=path.read_text(encoding='utf-8')
        if '\x00' in text or '<<<<<<< ' in text or '>>>>>>> ' in text:raise ValueError('invalid documentation content')
        if entry['path'].endswith('.md'):executable_signature(text)
    print('Prose/FUNDING static checks passed; no compiler invoked.')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan-json',required=True)
    parser.add_argument('--root',type=Path,default=Path('.'))
    args=parser.parse_args(); check_files(args.root,json.loads(args.plan_json)['prose_only'])

if __name__=='__main__':main()
