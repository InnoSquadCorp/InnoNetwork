"""Read-only, opt-in proof for complete-input-equivalent main advancement.

Every Git validation input, including documentation contracts, must remain
byte-identical. A different commit/base identity alone is not an input change.
Changed prose still needs fresh affected documentation proof; unknown cases fail.
"""
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import zipfile


def require(value,message):
    if not value:raise ValueError(message)


def module(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'));value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


def tree(api,route,sha):
    value=api.get(route+'git/trees/'+sha+'?recursive=1')
    require(value.get('sha')==sha and value.get('truncated') is False and isinstance(value.get('tree'),list),'complete immutable Git tree required')
    entries={}
    for entry in value['tree']:
        if entry.get('type')=='tree':continue
        path=entry.get('path');mode=entry.get('mode');oid=entry.get('sha');kind=entry.get('type')
        require(isinstance(path,str) and path and not path.startswith('/') and not any(x in ('','..','.') for x in path.split('/')) and '\\' not in path and path not in entries,'invalid or duplicate input path')
        require(mode in ('100644','100755','120000','160000') and kind in ('blob','commit') and re.fullmatch('[0-9a-f]{40}',oid or ''),'unknown Git input')
        entries[path]=(mode,kind,oid)
    return entries


def blob(api,route,sha):
    value=api.get(route+'git/blobs/'+sha)
    require(value.get('sha')==sha and value.get('encoding')=='base64' and type(value.get('size')) is int and value['size']<=2_000_000,'bounded immutable blob required')
    data=base64.b64decode(value['content'],validate=False)
    require(len(data)==value['size'] and hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==sha,'blob content does not match Git identity')
    return data.decode('utf-8','strict')


def prove_inputs(api,route,base,head,source,current_main):
    require(all(isinstance(x,str) and re.fullmatch('[0-9a-f]{40}',x) for x in (base,head,source,current_main)),'exact Git anchors required')
    old=api.get(route+'git/commits/'+source)
    require(old.get('sha')==source and [p.get('sha') for p in old.get('parents',[])]==[base,head],'validated checkout parents differ')
    relation=api.get(route+'compare/'+base+'...'+current_main)
    require(relation.get('status') in ('ahead','identical') and relation.get('merge_base_commit',{}).get('sha')==base,'main did not advance from validated base')
    return old


def prove(api,route,number,base,head,source,current_main):
    old=prove_inputs(api,route,base,head,source,current_main)
    reference=api.get(route+f'git/ref/pull/{number}/merge')
    current=reference.get('object',{}).get('sha')
    require(isinstance(current,str) and re.fullmatch('[0-9a-f]{40}',current),'current synthetic merge unavailable')
    merged=api.get(route+'git/commits/'+current)
    require(merged.get('sha')==current and [p.get('sha') for p in merged.get('parents',[])]==[current_main,head],'synthetic merge has not caught up with authoritative main')
    old_tree=old.get('tree',{}).get('sha');new_tree=merged.get('tree',{}).get('sha')
    require(all(isinstance(x,str) and re.fullmatch('[0-9a-f]{40}',x) for x in (old_tree,new_tree)),'missing merge tree')
    before=tree(api,route,old_tree);after=tree(api,route,new_tree)
    require(set(before)==set(after),'input added/deleted/renamed; full validation required')
    changed=[];normalized=[]
    for path in sorted(before):
        left,right=before[path],after[path]
        if left==right:normalized.append([path,*left]);continue
        # Plain text is consumed by literal docs contracts and DocC too. An
        # unchanged code-fence signature is NOT proof those gates still pass.
        # Do not accept changed prose without fresh affected-gate evidence.
        raise ValueError('validation input changed; fresh affected gate required: '+path)
    digest=hashlib.sha256(json.dumps(normalized,separators=(',',':'),ensure_ascii=True).encode()).hexdigest()
    return {'base':base,'current_main':current_main,'head':head,'validated_checkout':source,'current_merge':current,'effective_inputs_sha256':digest,'ignored_prose_paths':changed}


def artifact(api,route,run,definition,variables_json):
    name=f'ci-plan-{definition}-{run["run_attempt"]}'
    values=api.pages(route+f'actions/runs/{run["id"]}/artifacts','artifacts')
    found=[item for item in values if item.get('name')==name]
    require(len(found)==1,'missing/duplicate source selection artifact')
    item=found[0];binding=item.get('workflow_run',{})
    require(item.get('expired') is False and binding.get('id')==run['id'] and binding.get('head_sha')==run['head_sha'],'foreign or expired source artifact')
    digest=item.get('digest','')
    require(isinstance(digest,str) and re.fullmatch('sha256:[0-9a-f]{64}',digest),'source artifact digest unavailable')
    data=api.archive(route+f'actions/artifacts/{item["id"]}/zip')
    require(hashlib.sha256(data).hexdigest()==digest.split(':',1)[1],'artifact download integrity mismatch')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names=archive.namelist();require(sorted(names)==['ci-evidence-config.json','ci-plan.json'],'source artifact lacks complete execution configuration')
        info=archive.getinfo('ci-plan.json');require(info.file_size<=2_000_000 and not info.is_dir(),'oversized selection artifact')
        plan=json.loads(archive.read(info))
        config_info=archive.getinfo('ci-evidence-config.json');require(config_info.file_size<10_000,'oversized execution config')
        require(json.loads(archive.read(config_info))==configuration(variables_json),'repository runtime variables changed')
    policy=module('ci-policy');policy.validate_plan(plan)
    require(plan.get('event')=='pull_request','artifact is not PR validation evidence')
    return {'artifact_id':item['id'],'artifact_digest':digest}


def recheck(api,route,number,proof):
    require(api.get(route+'git/ref/heads/main').get('object',{}).get('sha')==proof['current_main'],'main moved again during equivalence proof')
    require(api.get(route+f'git/ref/pull/{number}/merge').get('object',{}).get('sha')==proof['current_merge'],'synthetic merge changed during equivalence proof')


def configuration(raw):
    value=json.loads(raw)
    require(isinstance(value,dict) and all(isinstance(k,str) and isinstance(v,str) for k,v in value.items()),'complete repository variable snapshot required')
    return {'schema':1,'repository_variables_sha256':hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()}


def main():
    import argparse,os
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('command',choices=['record-config']);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    data=configuration(os.environ.get('CI_INPUT_VARIABLES',''))
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(data,sort_keys=True)+'\n')
if __name__=='__main__':main()
