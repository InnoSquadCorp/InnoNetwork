#!/usr/bin/env python3
"""Authenticate a token-suppressed current-main CI wake before snapshot submission."""
import importlib.util
import json
import os
from pathlib import Path
import re

spec = importlib.util.spec_from_file_location('policy', Path(__file__).with_name('dependabot-merge-policy.py'))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def verify(api, event, expected_sha):
    repository = api.get(p.route(''))
    notice = event['workflow_run']
    run = api.get(p.route(f"actions/runs/{notice['id']}"))
    for key in ['id', 'run_attempt', 'workflow_id', 'head_sha', 'event', 'path', 'head_branch', 'display_title']:
        p.require(run.get(key) == notice.get(key), 'stale recovery wake: ' + key)
    p.require(run.get('path') == p.CI_PATH and run.get('event') == 'workflow_dispatch' and
              run.get('head_branch') == 'main' and run.get('head_sha') == expected_sha and
              run.get('repository', {}).get('full_name') == p.REPOSITORY and
              run.get('repository', {}).get('id') == repository.get('id') and
              run.get('head_repository', {}).get('id') == repository.get('id') and
              run.get('head_repository', {}).get('full_name') == p.REPOSITORY,
              'untrusted recovery run')
    workflow = api.get(p.route('actions/workflows/ci.yml'))
    p.require(workflow.get('id') == run.get('workflow_id') and workflow.get('path') == p.CI_PATH and
              workflow.get('state') == 'active', 'wrong recovery workflow')
    marker = re.fullmatch(re.escape(p.PREFIX) + r'([1-9][0-9]*)', run.get('display_title', ''))
    p.require(marker is not None, 'missing recovery marker')
    p.verify_post_merge(api, int(marker.group(1)), expected_sha)


if __name__ == '__main__':
    p.require(os.environ.get('GITHUB_WORKFLOW_REF') == p.REPOSITORY + '/.github/workflows/dependency-submission.yml@refs/heads/main' and
              os.environ.get('GITHUB_REF') == 'refs/heads/main' and os.environ.get('GITHUB_REPOSITORY') == p.REPOSITORY,
              'snapshot recovery requires trusted main workflow')
    verify(p.GitHub(), json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()), os.environ['GITHUB_SHA'])
    print('Verified actual bot merge and current-main CI recovery run.')
