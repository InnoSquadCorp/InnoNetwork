#!/usr/bin/env python3
"""Read-only admission of exact-tree PR verification for five main CI jobs.

No artifact, cache, PR code, status mutation, or workflow dispatch is consumed.
Missing/ambiguous admission evidence selects ordinary full CI. Once jobs have
been skipped, the aggregate must revalidate the identical proof or fail closed.
"""
import argparse
import importlib.util
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

REPOSITORY = "InnoSquadCorp/InnoNetwork"
CI_PATH = ".github/workflows/ci.yml"
APP = 15368  # GitHub Actions; names alone are not check provenance.
SHA = re.compile(r"[0-9a-f]{40}")
# These groups are tree-dependent verification only. Keep coverage/artifact
# producers, consumers, benchmarks, CodeQL, release and main policy fresh.
REUSED_JOBS = ("lint", "dead-code", "parallel-tests", "apple-platform-build-smoke", "thread-sanitizer")
REFERENCED = {"release-validation.yml"}
CORE = {'CI Plan': ['Verify actual post-merge main origin',
             'Admit equivalent-tree PR verification for main',
             'Plan exact changed paths',
             'Preserve change selection evidence'],
 'CI and public operations policy': ['Checkout',
                                     'Verify CI selection and public '
                                     'operations'],
 'Dependency Review': ['Checkout trusted dependency verifier',
                       'Verify immutable dependency transition',
                       'Wait for complete dependency snapshots',
                       'Review dependency changes'],
 'Lint (swift-format)': ['Checkout',
                         'Select Xcode',
                         'Show swift-format version',
                         'Run swift-format lint'],
 'Lint (Periphery)': ['Checkout',
                      'Select Xcode',
                      'Cache SwiftPM artifacts',
                      'Install Periphery 3.8.0',
                      'Resolve dependencies',
                      'Run Periphery scan',
                      'Report cache observations'],
 'Build and Test (SwiftPM) — Xcode 26.0.1': ['Checkout',
                                             'Select Xcode',
                                             'Cache SwiftPM artifacts',
                                             'Show Xcode and Swift versions',
                                             'Check Swift tools compatibility',
                                             'Resolve dependencies',
                                             'Verify resolved dependency lock',
                                             'Verify resolved dependency '
                                             'snapshot',
                                             'Build (Swift 6 language mode)',
                                             'Test (with code coverage)',
                                             'Generate runtime coverage report',
                                             'Upload coverage artifact',
                                             'Enforce @unchecked Sendable '
                                             'policy',
                                             'Enforce SharedCoders '
                                             'immutability',
                                             'Enforce no force unwrap in '
                                             'production sources',
                                             'Enforce no print() in production '
                                             'sources',
                                             'Report cache observations'],
 'Build and Test (SwiftPM) — Xcode 27.0': ['Checkout',
                                           'Select Xcode',
                                           'Cache SwiftPM artifacts',
                                           'Show Xcode and Swift versions',
                                           'Check Swift tools compatibility',
                                           'Resolve dependencies',
                                           'Verify resolved dependency lock',
                                           'Verify resolved dependency '
                                           'snapshot',
                                           'Build (Swift 6 language mode)',
                                           'Test (with code coverage)',
                                           'Generate runtime coverage report',
                                           'Upload coverage artifact',
                                           'Enforce @unchecked Sendable policy',
                                           'Enforce SharedCoders immutability',
                                           'Enforce no force unwrap in '
                                           'production sources',
                                           'Enforce no print() in production '
                                           'sources',
                                           'Report cache observations'],
 'Upload Core Coverage': ['Checkout',
                          'Download canonical coverage artifact',
                          'Install Codecov CLI v11.3.1',
                          'Report artifact-only Codecov fallback',
                          'Upload coverage to Codecov'],
 'Test (Bounded Target Shards) — Xcode 26.0.1': ['Checkout',
                                                 'Select Xcode',
                                                 'Cache SwiftPM artifacts',
                                                 'Show Xcode and Swift '
                                                 'versions',
                                                 'Resolve dependencies',
                                                 'Run bounded target-sharded '
                                                 'tests',
                                                 'Report cache observations'],
 'Docs / Contract Sync': ['Checkout',
                          'Select Xcode',
                          'Cache SwiftPM artifacts',
                          'Show Xcode and Swift versions',
                          'Resolve dependencies',
                          'Test docs-contract assertion helpers',
                          'Verify docs and stability contract',
                          'Verify guarded benchmark contract',
                          'Verify repeated macro build baselines',
                          'Verify public API tier fixtures',
                          'Verify dependency snapshot conversion',
                          'Verify local release preflight contract',
                          'Verify release workflow contract',
                          'Verify DocC archive contract',
                          'Verify stable examples contract',
                          'Verify example deployment floors',
                          'Verify migration guide code blocks compile',
                          'Verify CHANGELOG Unreleased section',
                          'Verify provisionally stable enum case ledger',
                          'Build documentation smoke target',
                          'Run documentation smoke target',
                          'Verify resumable upload recovery across process '
                          'exit',
                          'Report cache observations'],
 'Apple Platform Build Smoke (platform=macOS, macOS, macosx, xcodebuild)': ['Checkout',
                                                                            'Select '
                                                                            'Xcode',
                                                                            'Cache '
                                                                            'SwiftPM '
                                                                            'artifacts',
                                                                            'Show '
                                                                            'Xcode '
                                                                            'and '
                                                                            'Swift '
                                                                            'versions',
                                                                            'Resolve '
                                                                            'dependencies',
                                                                            'Build '
                                                                            'package '
                                                                            'for '
                                                                            'macOS',
                                                                            'Report '
                                                                            'cache '
                                                                            'observations'],
 'Apple Platform Build Smoke (generic/platform=iOS Simulator, iOS, iphonesimulator, xcodebuild)': ['Checkout',
                                                                                                   'Select '
                                                                                                   'Xcode',
                                                                                                   'Cache '
                                                                                                   'SwiftPM '
                                                                                                   'artifacts',
                                                                                                   'Show '
                                                                                                   'Xcode '
                                                                                                   'and '
                                                                                                   'Swift '
                                                                                                   'versions',
                                                                                                   'Resolve '
                                                                                                   'dependencies',
                                                                                                   'Build '
                                                                                                   'package '
                                                                                                   'for '
                                                                                                   'iOS',
                                                                                                   'Report '
                                                                                                   'cache '
                                                                                                   'observations'],
 'Apple Platform Build Smoke (arm64-apple-tvos16.0, tvOS, appletvos, swiftpm-cross)': ['Checkout',
                                                                                       'Select '
                                                                                       'Xcode',
                                                                                       'Cache '
                                                                                       'SwiftPM '
                                                                                       'artifacts',
                                                                                       'Show '
                                                                                       'Xcode '
                                                                                       'and '
                                                                                       'Swift '
                                                                                       'versions',
                                                                                       'Resolve '
                                                                                       'dependencies',
                                                                                       'Build '
                                                                                       'package '
                                                                                       'for '
                                                                                       'tvOS',
                                                                                       'Report '
                                                                                       'cache '
                                                                                       'observations'],
 'Apple Platform Build Smoke (arm64_32-apple-watchos9.0, watchOS, watchos, swiftpm-cross)': ['Checkout',
                                                                                             'Select '
                                                                                             'Xcode',
                                                                                             'Cache '
                                                                                             'SwiftPM '
                                                                                             'artifacts',
                                                                                             'Show '
                                                                                             'Xcode '
                                                                                             'and '
                                                                                             'Swift '
                                                                                             'versions',
                                                                                             'Resolve '
                                                                                             'dependencies',
                                                                                             'Build '
                                                                                             'package '
                                                                                             'for '
                                                                                             'watchOS',
                                                                                             'Report '
                                                                                             'cache '
                                                                                             'observations'],
 'Apple Platform Build Smoke (arm64-apple-xros1.0, visionOS, xros, swiftpm-cross)': ['Checkout',
                                                                                     'Select '
                                                                                     'Xcode',
                                                                                     'Cache '
                                                                                     'SwiftPM '
                                                                                     'artifacts',
                                                                                     'Show '
                                                                                     'Xcode '
                                                                                     'and '
                                                                                     'Swift '
                                                                                     'versions',
                                                                                     'Resolve '
                                                                                     'dependencies',
                                                                                     'Build '
                                                                                     'package '
                                                                                     'for '
                                                                                     'visionOS',
                                                                                     'Report '
                                                                                     'cache '
                                                                                     'observations'],
 'Consumer Smoke': ['Checkout', 'Require all consumer lanes to succeed'],
 'Consumer Examples': ['Checkout',
                       'Select Xcode',
                       'Show Xcode and Swift versions',
                       'Restore isolated consumer build caches',
                       'Verify macro trait manifest and default graph',
                       'Build root core without default traits',
                       'Build all independent consumer examples',
                       'Run macro adopter smoke',
                       'Run OpenAPI adopter smoke',
                       'Report cache observations'],
 'Consumer Macros': ['Checkout',
                     'Select Xcode',
                     'Restore isolated consumer build caches',
                     'Test macros from source (with code coverage)',
                     'Verify macro compile-failure diagnostics',
                     'Generate macro coverage report',
                     'Upload macro coverage artifact',
                     'Report cache observations'],
 'Consumer OpenAPI': ['Checkout',
                      'Select Xcode',
                      'Restore isolated consumer build caches',
                      'Build openapi-to-innonetwork CLI',
                      'Test openapi-to-innonetwork CLI',
                      'Typecheck generated OpenAPI output',
                      'Report cache observations'],
 'Upload Macro Coverage': ['Checkout',
                           'Download macro coverage artifact',
                           'Install Codecov CLI v11.3.1',
                           'Report artifact-only Codecov fallback',
                           'Upload macro coverage to Codecov'],
 'Benchmark Smoke': ['Checkout',
                     'Select Xcode',
                     'Cache SwiftPM artifacts',
                     'Show Xcode and Swift versions',
                     'Resolve dependencies',
                     'Run benchmark smoke',
                     'Upload benchmark smoke artifact',
                     'Report cache observations'],
 'CodeQL / Swift (swift)': ['Checkout',
                            'Select Xcode',
                            'Initialize CodeQL',
                            'Build',
                            'Perform CodeQL Analysis'],
 'Tests under ThreadSanitizer': ['Checkout',
                                 'Select Xcode',
                                 'Cache SwiftPM artifacts',
                                 'Show Xcode and Swift versions',
                                 'Resolve dependencies',
                                 'Run tests under ThreadSanitizer',
                                 'Report cache observations'],
 'Run Benchmarks': ['Checkout',
                    'Select Xcode',
                    'Cache SwiftPM artifacts',
                    'Show Xcode and Swift versions',
                    'Test benchmark report tooling',
                    'Verify guarded benchmark contract',
                    'Compare same-runner benchmark medians',
                    'Upload benchmark artifact',
                    'Report cache observations'],
 'Build DocC Site': ['Checkout',
                     'Select Xcode',
                     'Cache SwiftPM artifacts',
                     'Show Xcode and Swift versions',
                     'Verify DocC archive contract fixtures',
                     'Build DocC archives',
                     'Verify public DocC archives',
                     'Transform DocC archives for static hosting',
                     'Validate DocC site files',
                     'Upload Documentation Artifact',
                     'Report cache observations'],
 'Release Candidate / Validate Release': ['Checkout',
                                          'Test release artifact scripts',
                                          'Validate immutable CI candidate',
                                          'Select Xcode',
                                          'Cache SwiftPM artifacts',
                                          'Show Xcode and Swift versions',
                                          'Resolve dependencies',
                                          'Verify resolved dependency lock',
                                          'Verify macro trait manifest and '
                                          'default graph',
                                          'Build root core without default '
                                          'traits',
                                          'Verify docs and stability contract',
                                          'Verify guarded benchmark contract',
                                          'Verify repeated macro build '
                                          'baselines',
                                          'Verify stable examples contract',
                                          'Verify example deployment floors',
                                          'Verify migration guide code blocks '
                                          'compile',
                                          'Verify CHANGELOG Unreleased section',
                                          'Verify provisionally stable enum '
                                          'case ledger',
                                          'Verify macro compile-failure '
                                          'diagnostics',
                                          'Enforce @unchecked Sendable policy',
                                          'Enforce SharedCoders immutability',
                                          'Enforce no force unwrap in '
                                          'production sources',
                                          'Enforce no print() in production '
                                          'sources',
                                          'Build and run documentation smoke '
                                          'target',
                                          'Build all independent consumer '
                                          'examples',
                                          'Verify resumable upload recovery '
                                          'across process exit',
                                          'Run macro adopter smoke',
                                          'Run OpenAPI adopter smoke',
                                          'Build openapi-to-innonetwork CLI',
                                          'Test openapi-to-innonetwork CLI',
                                          'Typecheck generated OpenAPI output',
                                          'Run quick benchmarks',
                                          'Retain raw benchmark diagnostics',
                                          'Run serial tests with coverage',
                                          'Generate runtime coverage report',
                                          'Run bounded target-sharded tests',
                                          'Run macro tests from source with '
                                          'coverage',
                                          'Generate macro coverage report',
                                          'Build DocC archives',
                                          'Verify public DocC archives',
                                          'Generate SBOMs (CycloneDX 1.5)',
                                          'Prepare release artifact manifest',
                                          'Upload release artifacts',
                                          'Report cache observations'],
 'Release Candidate / Validate macOS Build': ['Checkout',
                                              'Select Xcode',
                                              'Cache SwiftPM artifacts',
                                              'Show Xcode and Swift versions',
                                              'Resolve dependencies',
                                              'Require SDK',
                                              'Build package for macOS',
                                              'Report cache observations'],
 'Release Candidate / Validate iOS Build': ['Checkout',
                                            'Select Xcode',
                                            'Cache SwiftPM artifacts',
                                            'Show Xcode and Swift versions',
                                            'Resolve dependencies',
                                            'Require SDK',
                                            'Build package for iOS',
                                            'Report cache observations'],
 'Release Candidate / Validate tvOS Build': ['Checkout',
                                             'Select Xcode',
                                             'Cache SwiftPM artifacts',
                                             'Show Xcode and Swift versions',
                                             'Resolve dependencies',
                                             'Require SDK',
                                             'Build package for tvOS',
                                             'Report cache observations'],
 'Release Candidate / Validate watchOS Build': ['Checkout',
                                                'Select Xcode',
                                                'Cache SwiftPM artifacts',
                                                'Show Xcode and Swift versions',
                                                'Resolve dependencies',
                                                'Require SDK',
                                                'Build package for watchOS',
                                                'Report cache observations'],
 'Release Candidate / Validate visionOS Build': ['Checkout',
                                                 'Select Xcode',
                                                 'Cache SwiftPM artifacts',
                                                 'Show Xcode and Swift '
                                                 'versions',
                                                 'Resolve dependencies',
                                                 'Require SDK',
                                                 'Build package for visionOS',
                                                 'Report cache observations'],
 'CI Required': ['Checkout', 'Require every planned CI result', 'Verify prior validation for metadata']}
SKIPPED = set()
STEP_SKIPS = {('CI Plan', 'Verify actual post-merge main origin'),
 ('Upload Core Coverage', 'Report artifact-only Codecov fallback'),
 ('Upload Macro Coverage', 'Report artifact-only Codecov fallback')}
PROOF_FIELDS = {"schema", "repository_id", "main", "base", "head", "merge", "tree",
                "pr", "run", "attempt", "workflow", "suite", "reused_jobs"}

STEP_SKIPS.update({('CI Required', 'Verify prior validation for metadata')})


class Rejected(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise Rejected(reason)


def validation_runs(api, runs, workflow_id, repository_id, number, head, source):
    spec = importlib.util.spec_from_file_location("ci_metadata_policy", Path(__file__).with_name("ci-metadata-policy.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.partition(api, runs, repository=REPOSITORY, repository_id=repository_id,
                            workflow_id=workflow_id, number=number, head=head, source=source, require=require)


def route(suffix):
    return f"repos/{REPOSITORY}/" + suffix


def job_check_id(job):
    url = job.get("check_run_url")
    prefix = "https://api.github.com/" + route("check-runs/")
    require(isinstance(url, str) and url.startswith(prefix) and
            re.fullmatch(r"[0-9]+", url[len(prefix):]) is not None,
            "missing or foreign job/check binding")
    check_id = int(url[len(prefix):])
    require(check_id > 0, "invalid job/check identity")
    return check_id


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Rejected("GitHub metadata redirect is not reusable evidence")


class GitHub:
    """GET-only, repository-bounded metadata transport with complete pagination."""
    def __init__(self, token=None):
        self.token = token or os.environ.get("GH_TOKEN")
        require(bool(self.token), "missing read-only job token")
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, path):
        require(path.startswith(route("")) and "\n" not in path, "foreign metadata target")
        request = urllib.request.Request("https://api.github.com/" + path, method="GET", headers={
            "Authorization": "Bearer " + self.token,
            "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
        with self.opener.open(request, timeout=15) as response:
            return json.load(response), response.headers

    def get(self, path):
        return self.request(path)[0]

    def pages(self, path, key=None):
        result = []
        for page in range(1, 101):
            separator = "&" if "?" in path else "?"
            data, headers = self.request(f"{path}{separator}per_page=100&page={page}")
            values = data if key is None else data.get(key)
            require(isinstance(values, list), "malformed metadata page")
            result.extend(values)
            if 'rel="next"' not in headers.get("Link", ""):
                if key and "total_count" in data:
                    require(len(result) == data["total_count"], "incomplete metadata pages")
                return result
        raise Rejected("excessive metadata pagination")


def validate_proof(proof):
    require(isinstance(proof, dict), "reuse proof must be an object")
    if not proof:
        return
    require(set(proof) == PROOF_FIELDS and type(proof["schema"]) is int and proof["schema"] == 1,
            "unsupported reuse proof schema")
    for field in ("main", "base", "head", "merge", "tree"):
        require(isinstance(proof[field], str) and SHA.fullmatch(proof[field]), "invalid proof commit/tree")
    for field in ("repository_id", "pr", "run", "attempt", "workflow", "suite"):
        require(type(proof[field]) is int and proof[field] > 0, "invalid proof identity")
    require(proof["reused_jobs"] == list(REUSED_JOBS), "reuse cannot change the five-job allowlist")


def checkout_context(root, environment):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()
    require(environment.get("GITHUB_EVENT_NAME") == "push" and
            environment.get("GITHUB_REPOSITORY") == REPOSITORY and
            environment.get("GITHUB_REF") == "refs/heads/main" and
            environment.get("GITHUB_WORKFLOW_REF") == REPOSITORY + "/" + CI_PATH + "@refs/heads/main",
            "reuse is only for trusted main push CI")
    main = environment.get("GITHUB_SHA", "")
    require(bool(SHA.fullmatch(main)) and environment.get("GITHUB_WORKFLOW_SHA") == main,
            "workflow must execute the exact main commit")
    require(git("rev-parse", "HEAD") == main, "checkout is not the workflow main SHA")
    require(not git("diff", "--name-only", "HEAD", "--"), "tracked checkout changed before proof")
    return {"main": main, "tree": git("rev-parse", "HEAD^{tree}")}


def timestamp(value):
    require(isinstance(value, str), "missing source completion time")
    value = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(value.tzinfo is not None, "source time must include timezone")
    return value


def prove(api, event, context, now=None):
    """Return deterministic evidence; caller supplies verified main checkout context."""
    main, tree = context["main"], context["tree"]
    require(event.get("ref") == "refs/heads/main" and event.get("after") == main and
            event.get("forced") is False and event.get("deleted") is False,
            "not a normal main push")
    commits = event.get("commits")
    require(isinstance(commits, list) and len(commits) == 1 and commits[0].get("id") == main,
            "reuse requires a single-commit push")
    repository_id = event.get("repository", {}).get("id")
    require(type(repository_id) is int and repository_id > 0 and
            event["repository"].get("full_name") == REPOSITORY, "wrong push repository")
    target = api.get(route(f"git/commits/{main}"))
    require(target.get("sha") == main and target.get("tree", {}).get("sha") == tree and
            len(target.get("parents", [])) == 1, "main commit/tree/parents differ")
    base = target["parents"][0]["sha"]
    require(bool(SHA.fullmatch(base)) and event.get("before") == base, "push includes additional base changes")
    require(api.get(route("git/ref/heads/main")).get("object", {}).get("sha") == main,
            "main was superseded")
    connections = api.pages(route(f"commits/{main}/pulls"))
    require(len(connections) == 1 and type(connections[0].get("number")) is int,
            "missing or ambiguous merged PR")
    number = connections[0]["number"]
    pr = api.get(route(f"pulls/{number}"))
    require(pr.get("number") == number and pr.get("merged") is True and pr.get("state") == "closed" and
            pr.get("merge_commit_sha") == main and pr.get("base", {}).get("ref") == "main" and
            pr["base"].get("sha") == base and pr["base"].get("repo", {}).get("id") == repository_id and
            pr.get("head", {}).get("repo", {}).get("id") == repository_id,
            "PR is not the exact same-repository squash merge")
    head = pr["head"].get("sha", "")
    require(bool(SHA.fullmatch(head)) and head not in (main, base) and
            isinstance(pr["head"].get("ref"), str) and bool(pr["head"]["ref"]), "invalid source head")
    workflow = api.get(route("actions/workflows/ci.yml"))
    require(workflow.get("path") == CI_PATH and workflow.get("state") == "active" and
            type(workflow.get("id")) is int and workflow["id"] > 0, "wrong/inactive source workflow")
    runs = api.pages(route(f"actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}"), "workflow_runs")
    runs, _, _ = validation_runs(api, runs, workflow["id"], repository_id, number, head, main)
    require(bool(runs), "missing exact-head CI")
    require(all(type(run.get("id")) is int and run["id"] > 0 and
                type(run.get("run_number")) is int and run["run_number"] > 0 for run in runs),
            "invalid source run identity")
    latest = max(runs, key=lambda run: (run["run_number"], run["id"]))
    run = api.get(route(f"actions/runs/{latest['id']}"))
    require(run.get("id") == latest["id"] and run.get("workflow_id") == workflow["id"] and
            run.get("path") == CI_PATH and run.get("event") == "pull_request" and run.get("head_sha") == head and
            run.get("head_branch") == pr["head"].get("ref") and
            run.get("repository", {}).get("id") == repository_id and
            run.get("head_repository", {}).get("id") == repository_id and
            run.get("status") == "completed" and run.get("conclusion") == "success" and
            type(run.get("run_attempt")) is int and 0 < run["run_attempt"] <= 100 and
            type(run.get("check_suite_id")) is int and run["check_suite_id"] > 0,
            "latest source run/attempt is not successful trusted PR CI")
    # After merge GitHub can return [] here. PR->main, immutable merge parents,
    # repository IDs and referenced workflow refs independently bind the run.
    links = run.get("pull_requests")
    require(isinstance(links, list), "missing run association field")
    if links:
        require(len(links) == 1 and links[0].get("number") == number and
                links[0].get("head", {}).get("sha") == head and
                links[0]["head"].get("ref") == pr["head"]["ref"] and
                links[0]["head"].get("repo", {}).get("id") == repository_id and
                links[0].get("base", {}).get("sha") == base and
                links[0]["base"].get("ref") == "main" and
                links[0]["base"].get("repo", {}).get("id") == repository_id,
                "conflicting source PR association")
    references = run.get("referenced_workflows", [])
    require(len(references) == len(REFERENCED), "missing/extra reusable workflow identity")
    merge_shas = {reference.get("sha") for reference in references}
    require(len(merge_shas) == 1, "reusable workflows tested different commits")
    merge = next(iter(merge_shas))
    require(isinstance(merge, str) and SHA.fullmatch(merge), "missing immutable tested merge SHA")
    expected_paths = {f"{REPOSITORY}/.github/workflows/{name}@{merge}" for name in REFERENCED}
    require({reference.get("path") for reference in references} == expected_paths and
            all(reference.get("ref") == f"refs/pull/{number}/merge" for reference in references),
            "wrong reusable workflow path/ref")
    candidate = api.get(route(f"git/commits/{merge}"))
    require(candidate.get("sha") == merge and candidate.get("tree", {}).get("sha") == tree and
            [parent.get("sha") for parent in candidate.get("parents", [])] == [base, head],
            "tested merge tree/base/head differ from squash main")
    # Equal complete Git trees also prove every workflow/action/script blob is
    # identical, rather than merely trusting a branch name or PR artifact.
    jobs = api.pages(route(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs"), "jobs")
    names = [job.get("name") for job in jobs]
    require(len(names) == len(CORE) + len(SKIPPED) and set(names) == set(CORE) | SKIPPED,
            "missing, duplicate or unexpected full CI job")
    checks = api.pages(route(f"check-suites/{run['check_suite_id']}/check-runs?filter=all"), "check_runs")
    require(all(type(check.get("id")) is int and check["id"] > 0 for check in checks), "invalid native check identity")
    by_id = {check["id"]: check for check in checks}
    require(len(by_id) == len(checks), "duplicate native checks")
    job_check_ids = set()
    completion = []
    for job in jobs:
        name = job["name"]
        expected = "skipped" if name in SKIPPED else "success"
        require(type(job.get("id")) is int and job["id"] > 0 and
                job.get("status") == "completed" and job.get("conclusion") == expected and
                job.get("run_id") == run["id"] and job.get("run_attempt") == run["run_attempt"] and
                job.get("head_sha") == head, "wrong source job outcome/attempt/head: " + name)
        check_id = job_check_id(job)
        require(check_id not in job_check_ids, "duplicate source job check")
        job_check_ids.add(check_id)
        check = by_id.get(check_id, {})
        require(check.get("name") == name and check.get("app", {}).get("id") == APP and
                check.get("check_suite", {}).get("id") == run["check_suite_id"] and
                check.get("head_sha") in (head, merge) and check.get("status") == "completed" and
                check.get("conclusion") == expected and check.get("details_url") ==
                f"https://github.com/{REPOSITORY}/actions/runs/{run['id']}/job/{job['id']}",
                "wrong native check provenance: " + name)
        steps = job.get("steps")
        require(isinstance(steps, list), "missing source steps")
        if name in SKIPPED:
            require(not steps, "skipped job contains steps")
            continue
        completion.append(timestamp(job.get("completed_at")))
        step_names = [step.get("name") for step in steps]
        require(len(step_names) == len(set(step_names)) and set(CORE[name]) <= set(step_names),
                "missing/duplicate validation steps: " + name)
        require(all(step.get("status") == "completed" and
                    (step.get("conclusion") == "success" or
                     (step.get("conclusion") == "skipped" and (name, step.get("name")) in STEP_SKIPS))
                    for step in steps), "failed or unexpected skipped validation step: " + name)
    # Checks from earlier attempts may coexist. Nothing unassociated in this
    # source suite can masquerade as another successful latest-attempt job.
    previous_ids = set()
    for attempt in range(1, run["run_attempt"]):
        previous = api.pages(route(f"actions/runs/{run['id']}/attempts/{attempt}/jobs"), "jobs")
        previous_ids.update(job_check_id(job) for job in previous)
    require(set(by_id) == job_check_ids | previous_ids, "unassociated checks in source CI suite")
    merged_at = timestamp(pr.get("merged_at"))
    require(all(timedelta(0) <= merged_at - ended <= timedelta(hours=24) for ended in completion),
            "source verification did not finish within 24 hours before merge")
    now = now or datetime.now(timezone.utc)
    require(merged_at <= now and all(timedelta(0) <= now - ended <= timedelta(hours=24) for ended in completion),
            "source verification is stale or from the future")
    # A rerun can start while jobs/checks are being read. An initial successful
    # run snapshot is not a final verdict: bracket those reads with the latest
    # list/detail and main identity before admitting or revalidating any skip.
    final_runs = api.pages(route(f"actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}"), "workflow_runs")
    final_runs, _, _ = validation_runs(api, final_runs, workflow["id"], repository_id, number, head, main)
    require(bool(final_runs) and all(type(item.get("id")) is int and item["id"] > 0 and
            type(item.get("run_number")) is int and item["run_number"] > 0 for item in final_runs),
            "latest source run disappeared or became ambiguous")
    final_latest = max(final_runs, key=lambda item: (item["run_number"], item["id"]))
    require(final_latest["id"] == run["id"] and final_latest["run_number"] == run["run_number"],
            "a newer source run appeared during proof")
    final_run = api.get(route(f"actions/runs/{run['id']}"))
    stable = ("id", "run_number", "run_attempt", "workflow_id", "path", "event", "head_sha",
              "head_branch", "check_suite_id", "status", "conclusion", "referenced_workflows")
    require(all(final_run.get(field) == run.get(field) for field in stable) and
            final_run.get("repository", {}).get("id") == repository_id and
            final_run.get("head_repository", {}).get("id") == repository_id,
            "source run/attempt changed while reading proof")
    require(api.get(route("git/ref/heads/main")).get("object", {}).get("sha") == main,
            "main changed while reading proof")
    # No Ready or review conclusion is manufactured here. A merged PR is the
    # authorization boundary; native CI evidence is a separate bounded input.
    proof = {"schema": 1, "repository_id": repository_id, "main": main, "base": base,
             "head": head, "merge": merge, "tree": tree, "pr": number, "run": run["id"],
             "attempt": run["run_attempt"], "workflow": workflow["id"], "suite": run["check_suite_id"],
             "reused_jobs": list(REUSED_JOBS)}
    validate_proof(proof)
    return proof


def revalidate(proof, event, environment, root=Path("."), api=None):
    validate_proof(proof)
    if proof:
        current = prove(api or GitHub(), event, checkout_context(root, environment))
        require(current == proof, "PR evidence changed after admission; full validation is required")


def admit(event, environment, root=Path("."), api=None):
    if environment.get("GITHUB_EVENT_NAME") != "push":
        return {}, "ordinary PR, queue and manual validation remain unchanged"
    try:
        proof = prove(api or GitHub(), event, checkout_context(root, environment))
        return proof, f"five jobs reuse PR #{proof['pr']} run {proof['run']} attempt {proof['attempt']}"
    except Exception as error:
        # This is an optimization only. Failed reads, malformed metadata and
        # unsupported shapes must never suppress a normal validation job.
        return {}, "full validation: " + str(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", required=True, type=Path)
    args = parser.parse_args()
    proof, reason = admit(json.loads(args.event.read_text()), os.environ)
    payload = json.dumps(proof, separators=(",", ":"))
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("proof=" + payload + "\n")
    print(reason)
    if "GITHUB_STEP_SUMMARY" in os.environ:
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write("## Main verification reuse\n\n" + reason + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
