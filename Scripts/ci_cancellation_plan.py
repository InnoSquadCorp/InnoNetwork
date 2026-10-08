"""Reference cancellation-key model; executable default-on headers are now wired.

The workflow wiring preserves metadata proof coordination and excludes
stateful/release writers while enabling scoped PR job cancellation by default.
"""
import hashlib
import json
import re


def plan(repository, workflow, subject_kind, subject, product, lane, matrix=None, purpose='validation'):
    """Stable workload identity: never a commit SHA, run ID, or run attempt."""
    values=[repository,workflow,subject,product,lane]
    if any(not isinstance(value,str) or not value or any(ord(c)<32 for c in value) for value in values):
        raise ValueError('explicit stable workload identity required')
    if subject_kind not in ('pull_request','branch','tag'):
        raise ValueError('subject must distinguish PR, branch and tag')
    if purpose not in ('validation','metadata','release','publish','stateful-writer'):
        raise ValueError('unknown work purpose')
    if not isinstance(matrix or {},dict) or any(not isinstance(k,str) for k in (matrix or {})):
        raise ValueError('matrix must identify the complete cell')
    def safe(value):
        if isinstance(value,(str,int,bool)) or value is None:return
        if isinstance(value,list):
            for child in value:safe(child)
            return
        if isinstance(value,dict) and all(isinstance(key,str) for key in value):
            for child in value.values():safe(child)
            return
        raise ValueError('unsupported matrix cell value')
    safe(matrix or {})
    identity={'repository':repository,'workflow':workflow,'subject_kind':subject_kind,'subject':subject,'product':product,'lane':lane,'matrix':matrix or {},'purpose':purpose}
    canonical=json.dumps(identity,sort_keys=True,separators=(',',':'),ensure_ascii=True)
    digest=hashlib.sha256(canonical.encode()).hexdigest()
    label=re.sub('[^a-z0-9_-]+','-',(repository+'-'+workflow+'-'+product+'-'+lane).lower())[:120]
    return {'group':'scoped-ci-v1-'+label+'-'+digest,'cancel_in_progress':purpose=='validation',
            'identity':identity,'activation':'default-on workflow wiring in ci-job-concurrency.json; explicit disabled override'}
