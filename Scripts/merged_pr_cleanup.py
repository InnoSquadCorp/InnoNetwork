#!/usr/bin/env python3
"""Trusted merged-PR cleanup executor. Defaults to read-only dry-run.

The trusted default-branch workflow explicitly requests writes by default.
Every candidate is authoritatively rechecked immediately before POST /cancel.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request


def selector():
    spec=importlib.util.spec_from_file_location('cleanup_selector',Path(__file__).with_name('merged_pr_cleanup_plan.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('unexpected GitHub API redirect')


class API:
    def __init__(self,repository,token):
        if not token or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repository):raise ValueError('repository and token required')
        self.repository=repository;self.token=token
    def request(self,method,path):
        prefix='repos/'+self.repository
        if not (path==prefix or path.startswith(prefix+'/')) or method not in ('GET','POST'):
            raise ValueError('foreign API operation')
        if method=='POST' and not re.fullmatch(re.escape(prefix)+r'/actions/runs/[1-9][0-9]*/cancel',path):
            raise ValueError('only exact workflow cancellation is supported')
        request=urllib.request.Request('https://api.github.com/'+path,method=method,
            headers={'Authorization':'Bearer '+self.token,'Accept':'application/vnd.github+json','X-GitHub-Api-Version':'2026-03-10'},data=b'' if method=='POST' else None)
        with urllib.request.build_opener(NoRedirect).open(request,timeout=30) as response:
            if response.status != (202 if method=='POST' else 200): raise ValueError('unexpected GitHub API status')
            raw=response.read(8*1024*1024+1)
            if len(raw)>8*1024*1024:raise ValueError('oversized API response')
            return json.loads(raw) if raw else {}


def validate_context(event,context,config):
    repo=config['repository'];default=event.get('repository',{}).get('default_branch')
    if not isinstance(default,str) or not default or context.get('event_name')!='pull_request_target':raise ValueError('trusted closed target event required')
    if context.get('repository')!=repo or context.get('ref')!='refs/heads/'+default:
        raise ValueError('trusted default-branch context required')
    if context.get('workflow_ref')!=repo+'/.github/workflows/merged-pr-cleanup.yml@refs/heads/'+default:
        raise ValueError('untrusted workflow source')
    sha=context.get('source_sha')
    if not isinstance(sha,str) or not re.fullmatch('[0-9a-f]{40}',sha) or context.get('checkout_sha')!=sha:
        raise ValueError('checkout must equal immutable trusted workflow source')
    if config.get('schema')!=1 or config.get('status')!='reviewed-cleanup-policy-v1':raise ValueError('reviewed cleanup config required')
    return repo


def inventory(api,repo,created_at,merged_at,allowed_workflows,head_branch):
    if not isinstance(head_branch,str) or not head_branch:raise ValueError('authoritative PR head branch required')
    interval=urllib.parse.quote(created_at+'..'+merged_at,safe='')
    branch=urllib.parse.quote(head_branch,safe='')
    all_runs=[]
    for workflow in sorted(allowed_workflows):
        if not re.fullmatch(r'\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml',workflow):
            raise ValueError('reviewed workflow filename required')
        filename=urllib.parse.quote(workflow.rsplit('/',1)[1],safe='')
        workflow_runs=[];total=None
        for page in range(1,12):
            data=api.request('GET',f'repos/{repo}/actions/workflows/{filename}/runs?event=pull_request&branch={branch}&created={interval}&per_page=100&page={page}')
            count=data.get('total_count');runs=data.get('workflow_runs')
            if type(count) is not int or count<0 or count>1000 or not isinstance(runs,list):raise ValueError('incomplete or capped workflow inventory')
            if total is not None and total!=count:raise ValueError('workflow inventory changed during pagination')
            total=count;workflow_runs.extend(runs)
            if len(workflow_runs)==count:break
            if not runs or len(workflow_runs)>count:raise ValueError('truncated workflow inventory')
        else:raise ValueError('workflow pagination limit exceeded')
        all_runs.extend(workflow_runs)
    return all_runs


def execute(event,context,config,api,apply=False):
    repo=validate_context(event,context,config)
    if apply and context.get('enable_writes')!='enabled':raise ValueError('cleanup writes are not enabled')
    metadata=api.request('GET','repos/'+repo)
    repo_id=metadata.get('id')
    if metadata.get('full_name')!=repo or type(repo_id) is not int or metadata.get('default_branch')!=event['repository']['default_branch']:
        raise ValueError('repository authority changed')
    number=event.get('number')
    if type(number) is not int or number<1:raise ValueError('invalid PR number')
    current=api.request('GET',f'repos/{repo}/pulls/{number}')
    trusted={**event,'repository':metadata,'pull_request':current}
    allowed=set(config['merged_pr_pull_request_workflow_allowlist'])
    # Validate authoritative merged state before listing any runs or writing.
    selector().select(trusted,[],repo,repo_id,allowed,True,True)
    if current.get('head',{}).get('sha')!=event.get('pull_request',{}).get('head',{}).get('sha'):
        raise ValueError('closed event head no longer matches authoritative PR')
    runs=inventory(api,repo,current['created_at'],current['merged_at'],allowed,current.get('head',{}).get('ref'))
    plan=selector().select(trusted,runs,repo,repo_id,allowed,True,True)
    report={'dry_run':not apply,'repository':repo,'pr':number,'candidates':plan['candidates'],'cancellation_requested':[],'already_finished_or_changed':[]}
    if not apply:return report
    for candidate in plan['candidates']:
        latest_pr=api.request('GET',f'repos/{repo}/pulls/{number}')
        if latest_pr.get('head',{}).get('sha')!=current['head']['sha']:raise ValueError('PR head raced before cancellation')
        fresh_event={**trusted,'pull_request':latest_pr}
        fresh_run=api.request('GET',f'repos/{repo}/actions/runs/{candidate["run_id"]}')
        fresh=selector().select(fresh_event,[fresh_run],repo,repo_id,allowed,True,True)['candidates']
        if fresh!=[candidate]:
            report['already_finished_or_changed'].append(candidate['run_id']);continue
        try:
            api.request('POST',f'repos/{repo}/actions/runs/{candidate["run_id"]}/cancel')
            report['cancellation_requested'].append(candidate['run_id'])
        except urllib.error.HTTPError as error:
            if error.code==409:
                latest=api.request('GET',f'repos/{repo}/actions/runs/{candidate["run_id"]}')
                if latest.get('status')=='completed':report['already_finished_or_changed'].append(candidate['run_id']);continue
            raise
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--event',type=Path,required=True);parser.add_argument('--apply',action='store_true');args=parser.parse_args()
    config=json.loads(Path(__file__).with_name('ci-cleanup-workflows.json').read_text());event=json.loads(args.event.read_text())
    root=Path(__file__).resolve().parents[1]
    context={'event_name':os.environ.get('GITHUB_EVENT_NAME'),'repository':os.environ.get('GITHUB_REPOSITORY'),'ref':os.environ.get('GITHUB_REF'),
        'workflow_ref':os.environ.get('GITHUB_WORKFLOW_REF'),'source_sha':os.environ.get('CLEANUP_SOURCE_SHA'),
        'checkout_sha':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),'enable_writes':os.environ.get('CLEANUP_ENABLE_WRITES')}
    report=execute(event,context,config,API(config['repository'],os.environ.get('GH_TOKEN')),args.apply)
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
