"""Recognize native metadata rechecks; never substitute them for real CI proof.

A title is a candidate, not evidence. Bind the immutable workflow definition,
merge parents and every attempt's complete job/check inventory before excluding
one from latest-validation selection. A gate that exits without proof (pending
or failed validation, obsolete head) is excluded only after a newer native
CI Required supersedes it. Unknown evidence blocks the caller.
"""
from datetime import datetime
import itertools
import re

PREFIX = 'CI metadata-only v1 '
TITLE = re.compile(PREFIX + r'pr:([1-9][0-9]*) head:([0-9a-f]{40}) base:([0-9a-f]{40}) action:(labeled|unlabeled|edited) source:([0-9a-f]{40})')
PATH = '.github/workflows/ci.yml'
DIRECT = {'Upload Macro Coverage', 'Lint (swift-format)', 'Consumer Macros', 'Consumer Examples', 'Apple Platform Build Smoke', 'CI and public operations policy', 'Benchmark Smoke', 'Run Benchmarks', 'Build DocC Site', 'CI Plan', 'Test (Bounded Target Shards) — Xcode 26.0.1', 'Upload Core Coverage', 'Dependency Review', 'Build and Test (SwiftPM) — Xcode ${{ matrix.xcode.label }}', 'Tests under ThreadSanitizer', 'Lint (Periphery)', 'Docs / Contract Sync', 'CodeQL / Swift', 'CodeQL / ${{ matrix.language }}', 'Consumer OpenAPI'}
CALLS = (({'Release Candidate'}, {'Release Candidate / Validate ${{ matrix.runtime }} Build', 'Release Candidate / Validate Release'}),)
# GitHub records skipped dynamic job names as expression source without ${{ }}.
# Match only these exact reviewed expressions, still bound to the workflow blob;
# a string mentioning a metadata label or a required context is not sufficient.
METADATA_CONDITION = "(github.event_name == 'pull_request' && (((github.event.action == 'labeled' || github.event.action == 'unlabeled') && github.event.label.name && github.event.label.name != 'release-validation' && github.event.label.name != 'concurrency-review') || (github.event.action == 'edited' && !github.event.changes.base)))"
GATES = {'CI Required': 'Require every planned CI result'}
AGGREGATES = (({'Consumer Metadata Only'}, {METADATA_CONDITION + " && 'Consumer Metadata Only' || 'Consumer Smoke'"}),)
INVENTORIES = [DIRECT.union(GATES, *children) for children in itertools.product(*CALLS, *AGGREGATES)]
VERIFY_STEP = 'Verify prior validation for metadata'
# The gate runs its verifier once and exits. A non-success never becomes a pass;
# it only stops counting when a newer same-name native check replaces it.
DEFERRED = {'failure', 'cancelled'}
APP = 15368


def completed_at(check, require):
    value = check.get('completed_at')
    try:
        moment = datetime.fromisoformat(value.replace('Z', '+00:00')) if isinstance(value, str) else None
    except ValueError:
        moment = None
    require(moment is not None and moment.tzinfo is not None, 'missing or invalid native check completion time')
    return moment


def supersedes(newer, older, require):
    """GitHub evaluates the newest same-name check; demand both ID and completion order."""
    return (newer is not None and type(newer.get('id')) is int and newer['id'] > older['id'] and
            newer.get('name') == older.get('name') and
            newer.get('head_sha') == older.get('head_sha') and newer.get('status') == 'completed' and
            completed_at(newer, require) > completed_at(older, require))


def validation_gate(api, route, runs, *, repository, repository_id, workflow_id, head, require):
    """Return the latest real validation's native CI Required check once GitHub created it."""
    ordinary = [r for r in runs if not str(r.get('display_title', '')).startswith(PREFIX)]
    if not ordinary:
        return None
    listed = max(ordinary, key=lambda r: (r['run_number'], r['id']))
    run = api.get(route + f"actions/runs/{listed['id']}")
    require(run.get('id') == listed['id'] and run.get('workflow_id') == workflow_id and run.get('path') == PATH and
            run.get('event') == 'pull_request' and run.get('head_sha') == head and
            run.get('repository', {}).get('id') == repository_id and
            run.get('head_repository', {}).get('id') == repository_id and
            type(run.get('run_attempt')) is int and 0 < run['run_attempt'] <= 100 and
            type(run.get('check_suite_id')) is int and run['check_suite_id'] > 0,
            'superseding validation is foreign or unbound')
    jobs = [j for j in api.pages(route + f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", 'jobs')
            if j.get('name') == 'CI Required']
    require(len(jobs) <= 1, 'duplicate validation CI Required job')
    if not jobs:
        return None
    job, prefix = jobs[0], 'https://api.github.com/' + route + 'check-runs/'
    url = job.get('check_run_url', '')
    require(type(job.get('id')) is int and job.get('run_id') == run['id'] and job.get('run_attempt') == run['run_attempt'] and
            job.get('head_sha') == head and url.startswith(prefix) and
            re.fullmatch(r'[1-9][0-9]*', url[len(prefix):]) is not None, 'unbound validation CI Required job')
    check = api.get(route + 'check-runs/' + url[len(prefix):])
    require(check.get('id') == int(url[len(prefix):]) and check.get('name') == 'CI Required' and
            check.get('app', {}).get('id') == APP and check.get('head_sha') == head and
            check.get('check_suite', {}).get('id') == run['check_suite_id'] and check.get('details_url') ==
            f"https://github.com/{repository}/actions/runs/{run['id']}/job/{job['id']}",
            'unverified validation CI Required check')
    return check


def partition(api, runs, *, repository, repository_id, workflow_id, number, head, source, require):
    """Return validation runs, exempt check IDs and verified (run, attempt) pairs."""
    route = 'repos/' + repository + '/'
    validations, ignored, metadata_runs = [], set(), set()
    proven, deferred = [], []
    expected_blob = None
    require(all(type(r.get('id')) is int and r['id'] > 0 and
                type(r.get('run_number')) is int and r['run_number'] > 0 for r in runs),
            'invalid CI run ordering')
    ordinary = [r for r in runs if not str(r.get('display_title', '')).startswith(PREFIX)]
    latest_validation = max((r.get('run_number', 0) for r in ordinary), default=0)
    for listed in runs:
        # Older terminal runs already use the caller's ordinary historical
        # handling. Do not let a metadata run from an obsolete base/workflow
        # block a later real validation, or reread its entire job inventory.
        if (not str(listed.get('display_title', '')).startswith(PREFIX) or
                listed.get('run_number', 0) < latest_validation):
            validations.append(listed)
            continue
        run = api.get(route + f"actions/runs/{listed['id']}")
        binding = TITLE.fullmatch(run.get('display_title', ''))
        require(binding is not None, 'invalid metadata-only event binding')
        pr, bound_head, base, action, definition = binding.groups()
        require(int(pr) == number and bound_head == head and
                run.get('id') == listed['id'] and run.get('run_number') == listed.get('run_number') and
                run.get('workflow_id') == workflow_id and run.get('path') == PATH and
                run.get('event') == 'pull_request' and run.get('head_sha') == head and
                run.get('repository', {}).get('id') == repository_id and
                run.get('head_repository', {}).get('id') == repository_id and
                run.get('status') == 'completed' and run.get('conclusion') in {'success', 'skipped'} | DEFERRED and
                type(run.get('run_attempt')) is int and 0 < run['run_attempt'] <= 100 and
                type(run.get('check_suite_id')) is int and run['check_suite_id'] > 0,
                'metadata run is pending, foreign or unbound')
        commit = api.get(route + 'git/commits/' + definition)
        require(commit.get('sha') == definition and
                [p.get('sha') for p in commit.get('parents', [])] == [base, head],
                'metadata workflow is not its event merge commit')
        if expected_blob is None:
            expected_blob = api.get(route + 'contents/' + PATH + '?ref=' + source).get('sha', '')
            require(re.fullmatch(r'[0-9a-f]{40}', expected_blob) is not None,
                    'missing current workflow identity')
        blob = api.get(route + 'contents/' + PATH + '?ref=' + definition).get('sha')
        require(blob == expected_blob, 'metadata workflow differs from current validation definition')
        checks = api.pages(route + f"check-suites/{run['check_suite_id']}/check-runs?filter=all", 'check_runs')
        by_id = {c.get('id'): c for c in checks}
        require(len(by_id) == len(checks), 'duplicate metadata checks')
        observed, gates = set(), {}
        # Every attempt must prove it skipped all validation work. Only the
        # latest attempt's gate can be the run's native verdict; a rerun's newer
        # gate supersedes an earlier timed-out or cancelled one.
        for attempt in range(1, run['run_attempt'] + 1):
            latest = attempt == run['run_attempt']
            jobs = api.pages(route + f"actions/runs/{run['id']}/attempts/{attempt}/jobs", 'jobs')
            names = [j.get('name') for j in jobs]
            require(len(names) == len(set(names)) and set(names) in INVENTORIES,
                    'missing, extra or validation-named metadata job')
            for job in jobs:
                url = job.get('check_run_url', '')
                prefix = 'https://api.github.com/' + route + 'check-runs/'
                require(url.startswith(prefix) and re.fullmatch(r'[1-9][0-9]*', url[len(prefix):]) is not None,
                        'missing native metadata job/check association')
                check_id = int(url[len(prefix):])
                require(check_id not in observed, 'duplicate metadata job/check association')
                observed.add(check_id)
                check = by_id.get(check_id, {})
                if job['name'] in GATES:
                    steps = job.get('steps', [])
                    verify = [s for s in steps if s.get('name') == VERIFY_STEP]
                    normal = [s for s in steps if s.get('name') == GATES[job['name']]]
                    expected = job.get('conclusion')
                    if expected == 'success':
                        require(len(verify) == 1 and verify[0].get('conclusion') == 'success' and
                                len(normal) == 1 and normal[0].get('conclusion') == 'skipped' and
                                all(s.get('status') == 'completed' and s.get('conclusion') in {'success', 'skipped'}
                                    for s in steps), 'metadata gate did not verify prior validation')
                    else:
                        # An unproven gate may stop at any step, but the real
                        # aggregate step must never have run in a metadata event.
                        require(expected in DEFERRED and len(verify) <= 1 and len(normal) <= 1 and
                                all(s.get('conclusion') in {'skipped', None} for s in normal),
                                'metadata gate skipped, ran validation work or ended in an unknown state')
                    if latest:
                        require(expected == run['conclusion'] or (expected == 'success' and run['conclusion'] == 'skipped'),
                                'metadata gate disagrees with its run conclusion')
                    gates[attempt] = check
                else:
                    expected = 'skipped'
                    require(job.get('steps') == [], 'metadata run executed validation work')
                require(type(job.get('id')) is int and job['id'] > 0 and
                        job.get('run_id') == run['id'] and job.get('run_attempt') == attempt and
                        job.get('head_sha') == head and job.get('status') == 'completed' and
                        job.get('conclusion') == expected and
                        check.get('name') == job['name'] and check.get('app', {}).get('id') == APP and
                        check.get('check_suite', {}).get('id') == run['check_suite_id'] and
                        check.get('head_sha') in {head, definition} and check.get('status') == 'completed' and
                        check.get('conclusion') == expected and check.get('details_url') ==
                        f"https://github.com/{repository}/actions/runs/{run['id']}/job/{job['id']}",
                        'metadata run executed work or has unverified native checks')
        require(set(by_id) == observed, 'unassociated metadata checks')
        verdict = gates[run['run_attempt']]
        require(all(supersedes(verdict, gate, require) for attempt, gate in gates.items() if attempt < run['run_attempt']),
                'metadata rerun did not supersede its earlier attempt')
        final = api.get(route + f"actions/runs/{run['id']}")
        require(all(final.get(k) == run.get(k) for k in (
            'id', 'run_number', 'run_attempt', 'workflow_id', 'path', 'event', 'display_title',
            'head_sha', 'repository', 'head_repository', 'check_suite_id', 'status', 'conclusion')),
            'metadata run changed while reading proof')
        (deferred if verdict['conclusion'] in DEFERRED else proven).append(verdict)
        ignored.update(observed)
        metadata_runs.add((run['id'], run['run_attempt']))
    if deferred:
        # Exclude an unproven gate only when GitHub already evaluates a newer
        # CI Required instead: the latest validation's own aggregate or a
        # proven metadata gate. Callers still prove that validation separately.
        newer = proven + [validation_gate(api, route, runs, repository=repository, repository_id=repository_id,
                                          workflow_id=workflow_id, head=head, require=require)]
        require(all(any(supersedes(check, gate, require) for check in newer) for gate in deferred),
                'unproven metadata gate is still the newest CI Required; rerun it after validation succeeds')
    return validations, ignored, metadata_runs
