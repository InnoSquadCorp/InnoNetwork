"""Dry-run selection only. Does not authenticate, call APIs, or cancel a run."""
import re
from datetime import datetime
SHA=re.compile(r'[0-9a-f]{40}')
PENDING={'queued','in_progress','waiting','pending','requested'}
PROTECTED=re.compile(r'(?:release|publish|deploy|dependabot|auto-merge|ready|review-notice|perf-history)',re.I)


def select(event, runs, expected_repository, expected_repository_id, allowed_workflows, allow_previous_heads=False, enforce_merge_window=False):
    """Consume trusted webhook + freshly fetched PR/run metadata, never PR code.

    No association, pagination completeness, or authoritative recheck is guessed.
    The caller must re-fetch each chosen run and the merged PR immediately before
    any future cancellation. This function intentionally performs no write.
    """
    if not isinstance(event,dict) or event.get('action')!='closed':raise ValueError('closed webhook required')
    repo=event.get('repository',{});pr=event.get('pull_request',{})
    if not isinstance(repo,dict) or (repo.get('full_name'),repo.get('id'))!=(expected_repository,expected_repository_id):raise ValueError('foreign webhook repository')
    if type(expected_repository_id) is not int or expected_repository_id<1:raise ValueError('verified repository id required')
    if not isinstance(pr,dict) or pr.get('merged') is not True or pr.get('state')!='closed':raise ValueError('merged PR required')
    number=pr.get('number');head=pr.get('head',{});base=pr.get('base',{})
    if type(number) is not int or number<1 or event.get('number')!=number:raise ValueError('exact PR number required')
    if not isinstance(head,dict) or not SHA.fullmatch(head.get('sha','')) or not isinstance(base,dict) or base.get('repo',{}).get('id')!=expected_repository_id:raise ValueError('verified PR head/base ownership required')
    if not isinstance(runs,list) or not isinstance(allowed_workflows,set) or not allowed_workflows:raise ValueError('verified complete run inventory and workflow allowlist required')
    if any(not path.startswith('.github/workflows/') or PROTECTED.search(path) for path in allowed_workflows):raise ValueError('protected workflow cannot enter cleanup allowlist')
    def timestamp(value):
        if not isinstance(value,str): raise ValueError('missing authoritative run/merge timestamp')
        parsed=datetime.fromisoformat(value.replace('Z','+00:00'))
        if parsed.tzinfo is None: raise ValueError('timestamp must be timezone aware')
        return parsed
    if enforce_merge_window:
        opened,merged=timestamp(pr.get('created_at')),timestamp(pr.get('merged_at'))
        if opened>merged: raise ValueError('invalid PR merge interval')
    candidates=[];seen=set()
    for run in runs:
        if not isinstance(run,dict):raise ValueError('invalid run metadata')
        identity=run.get('id')
        if type(identity) is not int or identity<1 or identity in seen:raise ValueError('missing/duplicate run identity')
        seen.add(identity)
        if (run.get('repository',{}).get('full_name'),run.get('repository',{}).get('id'))!=(expected_repository,expected_repository_id):continue
        if run.get('event')!='pull_request' or run.get('status') not in PENDING or run.get('conclusion') is not None:continue
        run_head=run.get('head_sha')
        if not isinstance(run_head,str) or not SHA.fullmatch(run_head) or run.get('path') not in allowed_workflows:continue
        if not allow_previous_heads and run_head!=head['sha']:continue
        associations=run.get('pull_requests')
        if not isinstance(associations,list) or len(associations)!=1:continue
        link=associations[0]
        if not isinstance(link,dict) or link.get('number')!=number:continue
        if link.get('head',{}).get('sha')!=run_head or link.get('base',{}).get('repo',{}).get('id')!=expected_repository_id:continue
        if type(run.get('run_attempt')) is not int or run['run_attempt']<1:continue
        if enforce_merge_window:
            try:
                if not opened <= timestamp(run.get('created_at')) <= merged: continue
                # Do not override an intentional rerun started after this merge.
                if run['run_attempt']>1 and timestamp(run.get('run_started_at'))>merged: continue
            except (ValueError,TypeError):
                continue
        candidates.append({'run_id':identity,'attempt':run['run_attempt'],'workflow':run['path'],'head_sha':run_head,'merged_pr_head':head['sha'],'pr':number})
    return {'dry_run':True,'repository':expected_repository,'pr':number,'candidates':sorted(candidates,key=lambda item:item['run_id']),
            'writes_performed':False,'requires_fresh_authoritative_recheck':True}
