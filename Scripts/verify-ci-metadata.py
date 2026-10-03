"""Revalidate native CI evidence for a metadata event; never synthesize a pass.

Only the latest real validation of this exact PR head, base, workflow definition
and validation-label set is accepted. All transport is read-only and bounded.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys
from urllib.request import Request, build_opener, HTTPRedirectHandler

CONFIG = {'repository': 'InnoSquadCorp/InnoNetwork', 'workflow': '.github/workflows/ci.yml', 'labels': ['release-validation', 'concurrency-review'], 'checks': ['CI Required']}
FLAGS = ('release-validation', 'run-asan', 'concurrency-review')
FORMAT = (r'CI validation v2 pr:([1-9][0-9]*) head:([0-9a-f]{40}) '
          r'base:([0-9a-f]{40}) source:([0-9a-f]{40}) '
          r'release:(true|false) asan:(true|false) concurrency:(true|false)')
TITLE = re.compile(FORMAT)
METADATA_PREFIX = 'CI metadata-only v1 '
VERIFY_STEP = 'Verify prior validation for metadata'


def require(value, message):
    if not value:
        raise ValueError(message)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('unexpected GitHub API redirect')


class API:
    def __init__(self, repository, token):
        self.prefix = 'repos/' + repository + '/'
        self.token = token

    def get(self, route):
        require(route.startswith(self.prefix) and not any(c in route for c in '\r\n'), 'foreign API route')
        request = Request('https://api.github.com/' + route,
                          headers={'Authorization': 'Bearer ' + self.token,
                                   'Accept': 'application/vnd.github+json',
                                   'X-GitHub-Api-Version': '2022-11-28'})
        with build_opener(NoRedirect).open(request, timeout=30) as response:
            payload = response.read(8_000_001)
        require(len(payload) <= 8_000_000, 'oversized GitHub response')
        return json.loads(payload)

    def pages(self, route, key):
        result = []
        for page in range(1, 21):
            data = self.get(route + ('&' if '?' in route else '?') + f'per_page=100&page={page}')
            items = data[key]
            require(isinstance(items, list), 'malformed API page')
            result.extend(items)
            if len(items) < 100:
                require(len(result) == data['total_count'], 'incomplete API inventory')
                return result
        raise ValueError('excessive API pagination')


def flags(pr):
    labels = pr.get('labels')
    require(isinstance(labels, list) and all(isinstance(x, dict) and isinstance(x.get('name'), str) for x in labels),
            'missing validation labels')
    names = {x['name'].lower() for x in labels}
    return tuple(str(label in names and label in CONFIG['labels']).lower() for label in FLAGS)


def binding(pr):
    return (pr['number'], pr['head']['sha'], pr['base']['sha'], flags(pr))


def prove(api, event, env, check_name='CI Required'):
    repo = CONFIG['repository']
    route = 'repos/' + repo + '/'
    require(env.get('GITHUB_REPOSITORY') == repo and env.get('GITHUB_EVENT_NAME') == 'pull_request',
            'metadata proof is PR-only in this repository')
    pr = event['pull_request']
    number, head, base, labels = binding(pr)
    require(type(number) is int and number > 0 and
            all(re.fullmatch('[0-9a-f]{40}', value) for value in (head, base)), 'invalid PR identity')
    require(env.get('GITHUB_REF') == f'refs/pull/{number}/merge', 'not the native PR merge ref')
    action = event.get('action')
    require((action == 'edited' and not event.get('changes', {}).get('base')) or
            (action in {'labeled', 'unlabeled'} and isinstance(event.get('label', {}).get('name'), str) and
             event['label']['name'] and event['label']['name'].lower() not in CONFIG['labels']),
            'validation-affecting events cannot reuse a metadata verdict')
    require(check_name in CONFIG['checks'], 'unknown required check')
    current = api.get(route + f'pulls/{number}')
    require(current.get('state') == 'open' and binding(current) == binding(pr), 'PR changed before validation')
    require(current['base']['repo']['full_name'] == repo, 'foreign base repository')
    own_id = int(env['GITHUB_RUN_ID'])
    own = api.get(route + f'actions/runs/{own_id}')
    source = env['GITHUB_SHA']
    require(own.get('head_sha') == head and own.get('path') == CONFIG['workflow'] and
            own.get('event') == 'pull_request' and own.get('repository', {}).get('full_name') == repo,
            'current run is not bound to the PR')
    require(own.get('run_attempt') == int(env['GITHUB_RUN_ATTEMPT']), 'current attempt changed')
    workflow = own['workflow_id']
    merge = api.get(route + 'git/commits/' + source)
    require(merge.get('sha') == source and [p['sha'] for p in merge.get('parents', [])] == [base, head],
            'checkout does not combine the current base and head')
    runs = api.pages(route + f'actions/workflows/{workflow}/runs?head_sha={head}', 'workflow_runs')
    validations = [r for r in runs if r.get('id') != own_id and
                   not str(r.get('display_title', '')).startswith(METADATA_PREFIX)]
    require(validations, 'no real validation exists for this head')
    require(all(type(r.get('run_number')) is int and r['run_number'] > 0 for r in validations), 'invalid run ordering')
    listed = max(validations, key=lambda r: r['run_number'])
    run = api.get(route + f"actions/runs/{listed['id']}")
    match = TITLE.fullmatch(run.get('display_title', ''))
    require(match is not None, 'latest validation lacks immutable PR binding')
    n, h, b, definition, *bound_labels = match.groups()
    require((int(n), h, b, tuple(bound_labels)) == binding(pr) and definition == source,
            'latest validation used a different head, base, workflow or label set')
    require(run.get('id') == listed['id'] and run.get('run_number') == listed['run_number'] and
            run.get('workflow_id') == workflow and run.get('path') == CONFIG['workflow'] and
            run.get('event') == 'pull_request' and run.get('head_sha') == head and
            run.get('repository', {}).get('full_name') == repo and
            run.get('status') == 'completed' and run.get('conclusion') == 'success',
            'latest real validation has not succeeded')
    attempt = run['run_attempt']
    require(type(attempt) is int and attempt > 0, 'invalid validation attempt')
    jobs = api.pages(route + f"actions/runs/{run['id']}/attempts/{attempt}/jobs", 'jobs')
    require(jobs and all(j.get('status') == 'completed' and j.get('conclusion') in {'success', 'skipped'}
                        for j in jobs), 'validation contains failed or unfinished jobs')
    for name in {'CI Required', check_name}:
        selected = [j for j in jobs if j.get('name') == name]
        require(len(selected) == 1, 'missing or duplicate required validation job')
        job = selected[0]
        require(job.get('run_id') == run['id'] and job.get('run_attempt') == attempt and
                job.get('head_sha') == head and job.get('conclusion') == 'success', 'required job did not succeed')
        steps = job.get('steps', [])
        require(any(s.get('name') == VERIFY_STEP and s.get('conclusion') == 'skipped' for s in steps),
                'metadata verification cannot replace real validation')
        require(any(s.get('name', '').startswith('Require ') and s.get('conclusion') == 'success' for s in steps),
                'real required validation was skipped')
        prefix = 'https://api.github.com/' + route + 'check-runs/'
        url = job.get('check_run_url', '')
        require(url.startswith(prefix) and url[len(prefix):].isdigit(), 'foreign job/check association')
        check = api.get(route + 'check-runs/' + url[len(prefix):])
        require(check.get('name') == name and check.get('app', {}).get('id') == 15368 and
                check.get('check_suite', {}).get('id') == run['check_suite_id'] and
                check.get('head_sha') in {head, source} and check.get('status') == 'completed' and
                check.get('conclusion') == 'success' and check.get('details_url') ==
                f"https://github.com/{repo}/actions/runs/{run['id']}/job/{job['id']}", 'unverified native check')
    final = api.get(route + f"actions/runs/{run['id']}")
    require(all(final.get(k) == run.get(k) for k in ('id', 'run_number', 'run_attempt', 'head_sha', 'workflow_id',
                'path', 'event', 'display_title', 'status', 'conclusion', 'check_suite_id')), 'validation changed during proof')
    latest = api.pages(route + f'actions/workflows/{workflow}/runs?head_sha={head}', 'workflow_runs')
    require(not any(r.get('run_number', 0) > run['run_number'] and r.get('id') != own_id and
                    not str(r.get('display_title', '')).startswith(METADATA_PREFIX) for r in latest),
            'newer real validation appeared')
    final_pr = api.get(route + f'pulls/{number}')
    require(final_pr.get('state') == 'open' and binding(final_pr) == binding(pr), 'PR changed during proof')
    return dict(run=run['id'], attempt=attempt, head=head, base=base, source=source, check=check_name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', default='CI Required')
    args = parser.parse_args()
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        proof = prove(API(CONFIG['repository'], os.environ['GH_TOKEN']), event, os.environ, args.check)
        message = 'Revalidated exact PR validation: ' + json.dumps(proof, sort_keys=True)
        print(message)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
                stream.write(message + '\n')
        return 0
    except Exception as error:
        print('CI metadata gate rejected: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
