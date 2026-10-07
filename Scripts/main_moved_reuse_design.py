"""Offline design model only: never authorizes CI reuse or marks checks green.

Production must obtain every field from immutable Git/API/artifact observations,
not a PR-supplied JSON document. Even an equal snapshot returns only a candidate
for authoritative revalidation. Existing CI gates do not invoke this module.
"""
import re

CATEGORIES={'source','config','lock','toolchain','workflow','tests','fixtures','generated','resources','consumers'}
SHA=re.compile(r'[0-9a-f]{40}')
DIGEST=re.compile(r'[0-9a-f]{64}')


def valid_snapshot(value):
    if not isinstance(value,dict) or set(value)!={'repository','pr','pr_head','synthetic_merge','base','product_closure','test_closure','inputs'}:
        raise ValueError('incomplete comparison snapshot')
    if not isinstance(value['repository'],str) or not value['repository'] or type(value['pr']) is not int or value['pr']<1:
        raise ValueError('invalid PR identity')
    if any(not isinstance(value[key],str) or not SHA.fullmatch(value[key]) for key in ('pr_head','synthetic_merge','base')):
        raise ValueError('exact immutable Git anchors required')
    for key in ('product_closure','test_closure'):
        names=value[key]
        if not isinstance(names,list) or not names or names!=sorted(set(names)) or any(not isinstance(name,str) or not name for name in names):
            raise ValueError('complete canonical dependency/test closure required')
    if not isinstance(value['inputs'],dict) or set(value['inputs'])!=CATEGORIES or any(not isinstance(digest,str) or not DIGEST.fullmatch(digest) for digest in value['inputs'].values()):
        raise ValueError('all effective-input categories need a content digest')


def assess(current,validated,run,artifact,trust):
    """Return candidate/full; there is intentionally no allow/reuse-success state."""
    try:
        valid_snapshot(current);valid_snapshot(validated)
        for key in ('repository','pr','pr_head','product_closure','test_closure','inputs'):
            if current[key]!=validated[key]:raise ValueError('different effective '+key)
        if not isinstance(trust,dict) or set(trust)!={'repository','workflow_path','workflow_content_sha256','app_id','latest_run_id','latest_attempt'}:
            raise ValueError('missing authoritative trust anchors')
        if not isinstance(run,dict) or set(run)!={'repository','id','attempt','status','conclusion','app_id','event','workflow_path','workflow_content_sha256','head_sha','pr_head','base_sha'}:
            raise ValueError('incomplete source run provenance')
        if any(type(run[key]) is not int or run[key]<1 for key in ('id','attempt','app_id')):
            raise ValueError('invalid source run identity')
        if run['repository']!=current['repository'] or trust['repository']!=current['repository']:
            raise ValueError('foreign source repository')
        if run['status']!='completed' or run['conclusion']!='success' or run['event']!='pull_request':
            raise ValueError('source run did not finish the trusted PR validation')
        for key in ('workflow_path','workflow_content_sha256','app_id'):
            if run[key]!=trust[key]:raise ValueError('untrusted '+key)
        if run['id']!=trust['latest_run_id'] or run['attempt']!=trust['latest_attempt']:
            raise ValueError('superseded source run/attempt')
        if (run['head_sha'],run['pr_head'],run['base_sha'])!=(validated['synthetic_merge'],validated['pr_head'],validated['base']):
            raise ValueError('run does not bind the validated synthetic merge inputs')
        if not isinstance(artifact,dict) or set(artifact)!={'repository','run_id','attempt','head_sha','workflow_content_sha256','payload_sha256','observed_payload_sha256','expired'}:
            raise ValueError('incomplete artifact provenance')
        if artifact['expired'] is not False or any(artifact[key]!=run[run_key] for key,run_key in [('repository','repository'),('run_id','id'),('attempt','attempt'),('head_sha','head_sha'),('workflow_content_sha256','workflow_content_sha256')]):
            raise ValueError('artifact provenance does not bind the successful attempt')
        if not isinstance(artifact['payload_sha256'],str) or not DIGEST.fullmatch(artifact['payload_sha256']) or artifact['payload_sha256']!=artifact['observed_payload_sha256']:
            raise ValueError('artifact payload integrity mismatch')
        return {'decision':'candidate-for-authoritative-revalidation','reason':'effective input digests match across base movement','reuse_authorized':False}
    except (ValueError,TypeError,KeyError) as error:
        return {'decision':'full-validation','reason':str(error),'reuse_authorized':False}
