#!/usr/bin/env python3
"""Trusted metadata-only Dependabot coordinator. Never downloads PR code/artifacts."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = "InnoSquadCorp/InnoNetwork"
CI_PATH = ".github/workflows/ci.yml"
NOTICE_PATH = ".github/workflows/dependabot-review-notice.yml"
COORDINATOR_PATH = ".github/workflows/dependabot-auto-merge.yml"
READY = "Dependabot Merge Ready"
APP = 15368
BOT = {"login": "dependabot[bot]", "id": 49699333, "type": "Bot"}
SHA = re.compile(r"[0-9a-f]{40}")
PREFIX = "CI / Dependabot merge #"
COORDINATOR_SOURCE_STEP = "Resolve authoritative API targets from "
SKIPPED_REFRESH_NAME = ("matrix.target.pr && format('Ready refresh PR{0} run{1} attempt{2}', "
                        "matrix.target.pr, matrix.target.run, matrix.target.attempt) || 'ready-refresh'")
# All bot updates, including major/toolchain updates, need the full contract.
# The native required ready check is separate from these inputs (no cycle).
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
FULL_SKIPPED = set()
ALLOWED_STEP_SKIP = {('CI Plan', 'Verify actual post-merge main origin'),
 ('Upload Core Coverage', 'Report artifact-only Codecov fallback'),
 ('Upload Macro Coverage', 'Report artifact-only Codecov fallback')}
ALLOWED_STEP_SKIP.update({('CI Required', 'Verify prior validation for metadata')})


class Rejected(ValueError):
    pass


class NeedsFreshReporter(Rejected):
    """Verified absence/obsolescence; never a successful Ready verdict."""
    def __init__(self, reason, message):
        super().__init__(message)
        self.reason = reason


class Superseded(Rejected):
    pass


def require(condition, reason):
    if not condition:
        raise Rejected(reason)


class GitHub:
    def __init__(self, token=None):
        self.token = token or os.environ.get("GH_TOKEN")
        require(bool(self.token), "missing job token")

    def request(self, method, path, payload=None):
        require(path == "graphql" or path == f"repos/{REPOSITORY}" or path.startswith(f"repos/{REPOSITORY}/"), "foreign API target")
        request = urllib.request.Request("https://api.github.com/" + path,
            data=None if payload is None else json.dumps(payload).encode(), method=method,
            headers={"Authorization": "Bearer " + self.token,
                     "Accept": "application/vnd.github+json", "Content-Type": "application/json",
                     "X-GitHub-Api-Version": "2022-11-28"})
        # No mutation retries: an unknown outcome must be read back first.
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return (json.loads(raw) if raw else None), response.headers

    def get(self, path):
        return self.request("GET", path)[0]

    def mutate(self, method, path, payload):
        return self.request(method, path, payload)[0]

    def pages(self, path, key=None):
        result = []
        page = 1
        while True:
            separator = "&" if "?" in path else "?"
            data, headers = self.request("GET", f"{path}{separator}per_page=100&page={page}")
            values = data if key is None else data.get(key)
            require(isinstance(values, list), "malformed paginated API result")
            result.extend(values)
            if 'rel="next"' not in headers.get("Link", ""):
                if key and "total_count" in data:
                    require(len(result) == data["total_count"], "truncated API pages")
                return result
            page += 1
            require(page <= 100, "excessive API pagination")

    def graphql(self, query, variables):
        response = self.mutate("POST", "graphql", {"query": query, "variables": variables})
        require(isinstance(response, dict) and not response.get("errors") and isinstance(response.get("data"), dict),
                "GraphQL returned errors or missing data")
        return response["data"]


def validation_runs(api, runs, workflow_id, repository_id, number, head, source):
    spec = importlib.util.spec_from_file_location("ci_metadata_policy", Path(__file__).with_name("ci-metadata-policy.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.partition(api, runs, repository=REPOSITORY, repository_id=repository_id,
                            workflow_id=workflow_id, number=number, head=head, source=source, require=require)


def route(suffix):
    return f"repos/{REPOSITORY}" + ("/" + suffix if suffix else "")


def trusted_context(environment):
    require(environment.get("GITHUB_REPOSITORY") == REPOSITORY and
            environment.get("GITHUB_REF") == "refs/heads/main" and
            environment.get("GITHUB_WORKFLOW_REF") == REPOSITORY + "/.github/workflows/dependabot-auto-merge.yml@refs/heads/main",
            "mutation requires trusted default-main workflow/ref")


def bot(pr):
    return all(pr.get("user", {}).get(k) == v for k, v in BOT.items())


def basic(pr, repo, require_open=True):
    require(pr.get("base", {}).get("ref") == "main", "wrong base branch")
    require(pr.get("base", {}).get("repo", {}).get("full_name") == REPOSITORY, "wrong target repository")
    require(pr.get("head", {}).get("repo", {}).get("id") == repo["id"] and
            pr["head"]["repo"].get("full_name") == REPOSITORY, "fork or missing head repository")
    require(bool(SHA.fullmatch(pr.get("head", {}).get("sha", ""))), "invalid head SHA")
    require(bot(pr), "PR author is not verified Dependabot")
    if require_open:
        require(pr.get("state") == "open" and pr.get("merged") is False, "PR not open")
        require(pr.get("draft") is False, "draft PR")
        require(pr.get("mergeable") is True, "conflict or unknown mergeability")


def native_rules(api, repo):
    require(repo.get("allow_auto_merge") is True and repo.get("allow_squash_merge") is True,
            "native auto-merge/squash feature disabled")
    rules = api.pages(route("rules/branches/main"))
    status = [r for r in rules if r.get("type") == "required_status_checks"]
    review = [r for r in rules if r.get("type") == "pull_request"]
    require(bool(status), "native required checks absent")
    require(bool(review), "native pull-request rule absent")
    require(any(r.get("parameters", {}).get("required_review_thread_resolution") is True for r in review), "native review-thread resolution missing")
    contexts = set()
    rulesets = {}

    def verify_source(rule):
        require(rule.get("ruleset_source_type") == "Repository" and rule.get("ruleset_source") == REPOSITORY,
                "unverified inherited protection")
        identifier = rule.get("ruleset_id")
        require(type(identifier) is int and identifier > 0, "missing protection ruleset identity")
        if identifier not in rulesets:
            rulesets[identifier] = api.get(route(f"rulesets/{identifier}"))
        ruleset = rulesets[identifier]
        require(ruleset.get("enforcement") == "active", "inactive protection")
        # This signal describes THIS coordinator token, not an owner/admin's
        # connector read. Redacted bypass_actors is not an empty list. Without
        # a verified runtime never-bypass signal remain in standby; never ask
        # for an Administration credential to manufacture that assurance.
        require(ruleset.get("current_user_can_bypass") == "never",
                "standby: coordinator no-bypass capability missing or unsafe")
        if "bypass_actors" in ruleset:
            require(not any(a.get("actor_type") == "Integration" and a.get("actor_id") == APP
                            for a in ruleset["bypass_actors"]), "GitHub Actions has protection bypass")

    for rule in status:
        verify_source(rule)
        parameters = rule.get("parameters", {})
        require(parameters.get("strict_required_status_checks_policy") is True, "loose native CI policy")
        for check in parameters.get("required_status_checks", []):
            require(check.get("integration_id") == APP, "required check has wrong app or any source")
            contexts.add(check.get("context"))
    for rule in review:
        verify_source(rule)
        count = rule.get("parameters", {}).get("required_approving_review_count")
        require(type(count) is int and count >= 0, "unverified native approval-count policy")
        # Zero remains allowed: this checks the native PR/thread barrier,
        # not a new human-approval count or a repository setting mutation.
    require({"CI Required", READY} <= contexts, "native CI/ready requirement missing")


def reviews(api, number):
    latest = {}
    for review in sorted(api.pages(route(f"pulls/{number}/reviews")), key=lambda r: r["id"]):
        state = review.get("state")
        require(state in {"APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", "PENDING"}, "unknown review state")
        if state != "COMMENTED":
            latest[review["user"]["id"]] = state
    require(not any(s in {"CHANGES_REQUESTED", "PENDING"} for s in latest.values()), "review blocks auto-merge")
    cursor = None
    while True:
        data = api.graphql('''query($number:Int!,$cursor:String) {
          repository(owner:"InnoSquadCorp",name:"InnoNetwork") { pullRequest(number:$number) {
            id headRefOid reviewDecision reviewThreads(first:100,after:$cursor) {
              nodes { isResolved } pageInfo { hasNextPage endCursor }
            }
          } }
        }''', {"number": number, "cursor": cursor})["repository"]["pullRequest"]
        require(data is not None and data.get("reviewDecision") not in {"CHANGES_REQUESTED", "REVIEW_REQUIRED"}, "native review decision blocks")
        threads = data["reviewThreads"]
        require(all(t.get("isResolved") is True for t in threads["nodes"]), "unresolved review thread")
        if not threads["pageInfo"]["hasNextPage"]:
            return data
        next_cursor = threads["pageInfo"]["endCursor"]
        require(isinstance(next_cursor, str) and next_cursor and next_cursor != cursor, "invalid review pagination")
        cursor = next_cursor


def proof(api, number, notification=None):
    repo = api.get(route(""))
    require(repo.get("full_name") == REPOSITORY and repo.get("default_branch") == "main", "wrong repository/default branch")
    pr = api.get(route(f"pulls/{number}"))
    if pr.get("mergeable") is None:  # One bounded read retry; never retry writes.
        pr = api.get(route(f"pulls/{number}"))
    basic(pr, repo)
    native_rules(api, repo)
    main = api.get(route("git/ref/heads/main"))["object"]["sha"]
    require(pr["base"]["sha"] == main, "base is no longer main")
    head = pr["head"]["sha"]
    merge_sha = pr.get("merge_commit_sha")
    require(bool(SHA.fullmatch(merge_sha or "")), "missing test-merge SHA")
    parents = api.get(route(f"git/commits/{merge_sha}"))["parents"]
    require([p["sha"] for p in parents] == [main, head], "test-merge parents do not match base/head")
    graph = reviews(api, number)
    require(graph["headRefOid"] == head, "head raced during reviews")
    require(not pr.get("requested_reviewers") and not pr.get("requested_teams"), "review request pending")
    workflow = api.get(route("actions/workflows/ci.yml"))
    require(workflow.get("path") == CI_PATH and workflow.get("state") == "active", "wrong/inactive CI workflow")
    runs = api.pages(route(f"actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}"), "workflow_runs")
    runs, metadata_check_ids, _ = validation_runs(api, runs, workflow["id"], repo["id"], number, head, merge_sha)
    require(bool(runs), "missing exact-head CI")
    run = max(runs, key=lambda r: (r["run_number"], r["id"]))
    run = api.get(route(f"actions/runs/{run['id']}"))
    require(run.get("workflow_id") == workflow["id"] and run.get("path", "").split("@")[0] == CI_PATH,
            "wrong source workflow identity")
    require(run.get("event") == "pull_request" and run.get("head_sha") == head and
            run.get("repository", {}).get("id") == repo["id"] and run.get("head_repository", {}).get("id") == repo["id"],
            "wrong CI origin/head")
    require([p.get("number") for p in run.get("pull_requests", [])] == [number], "missing/ambiguous current PR connection")
    connection = run["pull_requests"][0]
    require(connection.get("head", {}).get("sha") == head and connection.get("base", {}).get("sha") == main,
            "CI connection tested an obsolete head/base")
    if notification:
        require(notification.get("id") == run["id"] and notification.get("run_attempt") == run["run_attempt"],
                "obsolete run/attempt notification")
    require(run.get("status") == "completed" and run.get("conclusion") == "success", "latest CI incomplete or failed")
    jobs = api.pages(route(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs"), "jobs")
    require(len(jobs) == len(CORE) + len(FULL_SKIPPED) and {j.get("name") for j in jobs} == set(CORE) | FULL_SKIPPED,
            "missing, duplicate or unexpected full CI job")
    checks = []
    for sha in dict.fromkeys((head, merge_sha)):
        checks.extend(api.pages(route(f"commits/{sha}/check-runs?filter=all"), "check_runs"))
        statuses = api.pages(route(f"commits/{sha}/statuses"))
        contexts = {}
        for status in statuses:
            contexts.setdefault(status["context"], status)
        require(all(s.get("state") == "success" for s in contexts.values()), "pending/failed commit status")
    by_id = {c["id"]: c for c in checks}
    require(len(by_id) == len(checks), "duplicate check IDs across attribution")
    job_ids = set()
    for job in jobs:
        name = job["name"]
        expected = "skipped" if name in FULL_SKIPPED else "success"
        require(job.get("status") == "completed" and job.get("conclusion") == expected, "job failed/cancelled/missing/unexpected skip: " + name)
        check_url = job.get("check_run_url", "")
        require(check_url.startswith(f"https://api.github.com/repos/{REPOSITORY}/check-runs/"), "missing job/check association")
        check_id = int(check_url.rsplit("/", 1)[1])
        job_ids.add(check_id)
        check = by_id.get(check_id, {})
        require(check.get("name") == name and check.get("app", {}).get("id") == APP and
                check.get("check_suite", {}).get("id") == run["check_suite_id"] and check.get("head_sha") in {head, merge_sha} and
                check.get("details_url") == f"https://github.com/{REPOSITORY}/actions/runs/{run['id']}/job/{job['id']}" and
                check.get("status") == "completed" and check.get("conclusion") == expected,
                "wrong app/suite/job/head proof: " + name)
        if name in FULL_SKIPPED:
            require(not job.get("steps"), "skipped job contains executable steps: " + name)
        if name in CORE:
            steps = job.get("steps", [])
            require(set(CORE[name]) <= {s.get("name") for s in steps}, "missing validation step: " + name)
            require(all(s.get("status") == "completed" and (s.get("conclusion") == "success" or
                        (s.get("conclusion") == "skipped" and (name, s.get("name")) in ALLOWED_STEP_SKIP)) for s in steps),
                    "failed/pending/skipped validation step: " + name)
    # Ready itself is not an input. Earlier successful attempts are evidence
    # only; every other current-head check must have a successful latest value.
    extra = {}
    historical_ids = set()
    for attempt in range(1, run["run_attempt"]):
        previous = api.pages(route(f"actions/runs/{run['id']}/attempts/{attempt}/jobs"), "jobs")
        historical_ids.update(int(j["check_run_url"].rsplit("/", 1)[1]) for j in previous)
    old_suites = {r.get("check_suite_id") for r in runs if r["run_number"] < run["run_number"] and
                  r.get("event") == "pull_request" and r.get("head_sha") == head and
                  r.get("workflow_id") == workflow["id"] and r.get("head_repository", {}).get("id") == repo["id"] and
                  [p.get("number") for p in r.get("pull_requests", [])] == [number] and r.get("status") == "completed"}
    transport_ids = coordinator_check_ids(api, number, head, checks) | metadata_check_ids
    for check in sorted(checks, key=lambda c: c["id"], reverse=True):
        if check.get("name") == READY:
            require(check["id"] in transport_ids, "unassociated/legacy Ready check; fresh native reporter head required")
            continue
        if check["id"] in job_ids or check["id"] in historical_ids or check["id"] in transport_ids:
            continue
        if check.get("check_suite", {}).get("id") in old_suites and check.get("app", {}).get("id") == APP:
            continue
        if check.get("check_suite", {}).get("id") == run["check_suite_id"]:
            raise Rejected("duplicate/unassociated current CI result")
        extra.setdefault((check.get("head_sha"), check.get("name"), check.get("app", {}).get("id")), check)
    require(all(c.get("status") == "completed" and c.get("conclusion") == "success" for c in extra.values()),
            "additional check pending/failed/skipped")
    return {"pr": pr, "node": graph["id"], "head": head, "base": main, "merge": merge_sha,
            "run": run["id"], "attempt": run["run_attempt"]}


def same(left, right):
    require(all(left[k] == right[k] for k in ("head", "base", "merge", "run", "attempt", "node")), "head/base/CI attempt raced")


def coordinator_runs(api, number, head):
    """Read eligible PR-bound provenance; notifications are never check sources."""
    repo = api.get(route(""))
    require(repo.get("full_name") == REPOSITORY and repo.get("default_branch") == "main",
            "wrong Ready repository/default branch")
    workflow = api.get(route("actions/workflows/dependabot-auto-merge.yml"))
    require(workflow.get("path") == COORDINATOR_PATH and workflow.get("state") == "active",
            "wrong/inactive Ready workflow")
    pr = api.get(route(f"pulls/{number}"))
    candidates = api.pages(route(f"actions/workflows/dependabot-auto-merge.yml/runs?event=pull_request_target&head_sha={head}"), "workflow_runs")
    runs = []
    for candidate in candidates:
        numbers = [p.get("number") for p in candidate.get("pull_requests", [])]
        if number not in numbers:
            # An unassociated newer run on this PR branch cannot be silently
            # ignored in favour of older success (notably on fork events).
            require(numbers or candidate.get("head_branch") != pr["head"].get("ref") or
                    candidate.get("head_repository", {}).get("id") != pr["head"].get("repo", {}).get("id"),
                    "Ready run lacks PR association; explicit PR-bound issuance required")
            continue
        run = api.get(route(f"actions/runs/{candidate['id']}"))
        connections = run.get("pull_requests", [])
        require(run.get("workflow_id") == workflow["id"] and run.get("path", "").split("@")[0] == COORDINATOR_PATH and
                run.get("event") == "pull_request_target" and run.get("head_sha") == head and
                run.get("repository", {}).get("id") == repo["id"] and
                run.get("head_repository", {}).get("id") == pr["head"].get("repo", {}).get("id") and
                [p.get("number") for p in connections] == [number] and
                connections[0].get("head", {}).get("sha") == head and
                connections[0].get("base", {}).get("ref") == "main" and
                connections[0].get("base", {}).get("repo", {}).get("id") == repo["id"] and
                type(run.get("run_attempt")) is int and run["run_attempt"] > 0 and
                type(run.get("check_suite_id")) is int,
                "invalid PR-bound Ready workflow provenance")
        runs.append(run)
    require(bool(runs), "no PR-bound Ready run; trigger or rerun pull_request_target")
    return runs


def ready_policy():
    spec = importlib.util.spec_from_file_location("native_ready_policy", Path(__file__).with_name("dependabot-ready-policy.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def this_policy():
    # importlib-loaded test modules need not be registered in sys.modules.
    class Policy:
        pass
    policy = Policy()
    policy.__dict__.update(globals())
    return policy


def coordinator_check_ids(api, number, head, checks):
    """Exclude only proven coordinator transport, never CI or arbitrary names."""
    by_id = {c["id"]: c for c in checks}
    ids = set()
    names = {"inspect", f"bot-ready ({number})", "ready-plan", "post-merge-plan", "post-merge"}
    runs = coordinator_runs(api, number, head)
    for run in runs:
        for attempt in range(1, run["run_attempt"] + 1):
            jobs = api.pages(route(f"actions/runs/{run['id']}/attempts/{attempt}/jobs"), "jobs")
            for job in jobs:
                bare_skip = job.get("name") == "bot-ready" and job.get("status") == "completed" and job.get("conclusion") == "skipped"
                refresh_skip = job.get("name") in {"ready-refresh", SKIPPED_REFRESH_NAME}
                require(job.get("name") in names or bare_skip or refresh_skip, "unexpected coordinator transport job")
                check_id = coordinator_job_check(job, run, attempt, head, by_id)
                if refresh_skip:
                    check = by_id[check_id]
                    require(job.get("status") == check.get("status") == "completed" and
                            job.get("conclusion") == check.get("conclusion") == "skipped" and job.get("steps") == [],
                            "PR-target refresh transport must be a terminal empty skip")
                    # GitHub can expose the unevaluated name for a matrix that
                    # never expands. Bind this exact exception to the trusted
                    # workflow source reported by the real inspect job.
                    inspectors = [item for item in jobs if item.get("name") == "inspect"]
                    require(len(inspectors) == 1, "missing/ambiguous coordinator source job")
                    inspector = inspectors[0]
                    source_check = by_id[coordinator_job_check(inspector, run, attempt, head, by_id)]
                    require(inspector.get("status") == source_check.get("status") == "completed" and
                            inspector.get("conclusion") == source_check.get("conclusion") == "success",
                            "coordinator source job did not succeed")
                    source_steps = [step for step in (inspector.get("steps") or [])
                                    if str(step.get("name", "")).startswith(COORDINATOR_SOURCE_STEP)]
                    require(len(source_steps) == 1 and source_steps[0].get("status") == "completed" and
                            source_steps[0].get("conclusion") == "success", "coordinator source step missing/unsuccessful")
                    source = source_steps[0]["name"][len(COORDINATOR_SOURCE_STEP):]
                    require(bool(SHA.fullmatch(source)), "invalid coordinator source SHA")
                    ready_policy().source_ancestor(api, this_policy(), source)
                ids.add(check_id)
    ids.update(ready_policy().verified_check_ids(api, this_policy(), number, head))
    return ids

def coordinator_job_check(job, run, attempt, head, checks):
    require(job.get("run_id") == run["id"] and job.get("run_attempt") == attempt and
            job.get("head_sha") == head and type(job.get("id")) is int and job["id"] > 0,
            "wrong coordinator job/run/attempt/head")
    url = job.get("check_run_url", "")
    prefix = f"https://api.github.com/repos/{REPOSITORY}/check-runs/"
    require(isinstance(url, str) and url.startswith(prefix) and re.fullmatch(r"[1-9][0-9]*", url[len(prefix):]),
            "missing coordinator job/check association")
    check_id = int(url[len(prefix):])
    check = checks.get(check_id, {})
    require(check.get("name") == job["name"] and check.get("app", {}).get("id") == APP and
            check.get("head_sha") == head and check.get("check_suite", {}).get("id") == run["check_suite_id"] and
            check.get("details_url") == f"https://github.com/{REPOSITORY}/actions/runs/{run['id']}/job/{job['id']}",
            "unverified coordinator transport check")
    return check_id


def coordinate(api, number, enabled=False, notification=None):
    trusted_context(os.environ)
    pr = api.get(route(f"pulls/{number}"))
    require(pr.get("base", {}).get("repo", {}).get("full_name") == REPOSITORY, "foreign target")
    if pr.get("state") != "open":
        return "closed: reconcile post-merge separately"
    head = pr.get("head", {}).get("sha", "")
    require(bool(SHA.fullmatch(head)), "invalid gate head")
    if pr["base"].get("ref") != "main":
        cancel_auto_merge(api, pr)
        return "wrong base: auto-merge ineligible"
    if not bot(pr):
        return "manual PR; native read-only reporter owns Ready, auto-merge not requested"
    # Notifications are only wake-ups. Obsolete run events do not overwrite a
    # newer decision; current pending/failure events invalidate readiness.
    try:
        if notification:
            current = api.get(route(f"actions/runs/{notification['id']}"))
            if current.get("run_attempt") != notification.get("run_attempt") or current.get("head_sha") != head:
                return "obsolete notification; no mutation"
            runs = api.pages(route(f"actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}"), "workflow_runs")
            workflow = api.get(route("actions/workflows/ci.yml"))
            runs, _, metadata_runs = validation_runs(api, runs, workflow["id"], pr["base"]["repo"]["id"],
                                                     number, head, pr["merge_commit_sha"])
            if (notification["id"], notification["run_attempt"]) in metadata_runs:
                # A verified no-op can finish after real CI was blocked on it.
                # Reconcile current facts without binding proof to the no-op:
                # only the latest actual full CI and native Ready can arm.
                notification = None
            elif not runs or max(runs, key=lambda r: (r["run_number"], r["id"]))["id"] != notification["id"]:
                return "obsolete notification; no mutation"
        require(enabled is True, "standby: new auto-merge approvals disabled")
        first = proof(api, number, notification)
        require(first["head"] == head, "head changed before native enable")
        readiness = ready_policy()
        binding = readiness.require_success(api, this_policy(), number, head)
        second = proof(api, number, notification)
        same(first, second)
        require(readiness.require_success(api, this_policy(), number, head) == binding, "native Ready changed before arming")
        # Native Ready is already green. All authoritative proof reads must
        # precede enable: GitHub can merge as soon as that request is accepted.
        third = proof(api, number, notification)
        same(second, third)
        require(readiness.require_success(api, this_policy(), number, head) == binding, "native Ready changed at final arming guard")
        if not third["pr"].get("auto_merge"):
            query = '''mutation($id:ID!,$head:GitObjectID!) {
              enablePullRequestAutoMerge(input:{pullRequestId:$id,expectedHeadOid:$head,mergeMethod:SQUASH}) {
                pullRequest { id headRefOid autoMergeRequest { enabledAt } }
              }
            }'''
            try:
                api.graphql(query, {"id": third["node"], "head": head})
            except Exception:
                # Unknown mutation outcome: read once, never blind retry/fallback.
                observed = api.get(route(f"pulls/{number}"))
                require(observed.get("head", {}).get("sha") == head and observed.get("auto_merge") is not None,
                        "native enable outcome not confirmed")
        return "native auto-merge armed; server owns actual merge"
    except Exception as error:
        reason = "blocked: " + str(error)
        try:
            cancel_auto_merge(api, api.get(route(f"pulls/{number}")))
        except Exception as cancel_error:
            raise Rejected(reason + "; cancellation unconfirmed: " + str(cancel_error)) from cancel_error
        return reason


def cancel_auto_merge(api, pr):
    # Protective cancellation is limited to verified bot PRs in this repository.
    # A failure never falls back to a direct merge or blind mutation retry.
    if bot(pr) and pr.get("auto_merge") and pr.get("state") == "open":
        require(pr.get("base", {}).get("repo", {}).get("full_name") == REPOSITORY, "foreign cancellation")
        try:
            api.graphql('''mutation($id:ID!) {
              disablePullRequestAutoMerge(input:{pullRequestId:$id}) { pullRequest { id } }
            }''', {"id": pr["node_id"]})
        except Exception:
            observed = api.get(route(f"pulls/{pr['number']}"))
            require(not observed.get("auto_merge") or observed.get("state") == "closed", "native cancellation not confirmed")


def verify_post_merge(api, number, expected_sha):
    require(bool(SHA.fullmatch(expected_sha or "")), "invalid expected main SHA")
    repo = api.get(route(""))
    pr = api.get(route(f"pulls/{number}"))
    basic(pr, repo, require_open=False)
    require(pr.get("state") == "closed" and pr.get("merged") is True and
            pr.get("merge_commit_sha") == expected_sha, "not the actual merged Dependabot PR")
    require(api.get(route("git/ref/heads/main"))["object"]["sha"] == expected_sha, "stale main publication origin")
    return pr


def post_merge_candidate(api):
    """Read-only eligibility; API errors and ambiguous identities are errors."""
    main = api.get(route("git/ref/heads/main"))["object"]["sha"]
    require(bool(SHA.fullmatch(main or "")), "invalid current main SHA")
    prs = api.pages(route(f"commits/{main}/pulls"))
    merged = []
    for pr in prs:
        require("merged_at" in pr and "merge_commit_sha" in pr and pr.get("state") in {"open", "closed"} and
                type(pr.get("number")) is int and pr["number"] > 0, "missing post-merge PR metadata")
        user = pr.get("user", {})
        require(isinstance(user, dict) and all(k in user for k in BOT), "missing post-merge author metadata")
        if not pr.get("merged_at") or pr.get("merge_commit_sha") != main:
            continue
        if bot(pr):
            merged.append(pr)
        elif user.get("login") == BOT["login"] or user.get("id") == BOT["id"]:
            raise Rejected("ambiguous post-merge bot identity")
    require(len(merged) <= 1, "ambiguous Dependabot merge at current main")
    if not merged:
        return None, "no Dependabot merge at current main"
    number = merged[0]["number"]
    verify_post_merge(api, number, main)
    runs = api.pages(route(f"actions/workflows/ci.yml/runs?branch=main&head_sha={main}"), "workflow_runs")
    for run in runs:
        if run.get("head_sha") == main and (run.get("event") == "push" or
                (run.get("event") == "workflow_dispatch" and run.get("display_title") == PREFIX + str(number))):
            return None, "main CI already exists; no duplicate or failed-run retry"
    verify_post_merge(api, number, main)
    return {"pr": number, "main": main}, "verified current-main CI recovery needed"


def post_merge_plan(api, enabled=False, wait_for_merge=False):
    if enabled is not True:
        return None, "standby: no post-merge dispatch"
    # Only a bot-coordination wake waits for native completion. Periodic/main
    # recovery reads once. This preserves the old bounded native-merge window.
    for attempt in range(7 if wait_for_merge else 1):
        candidate, reason = post_merge_candidate(api)
        if candidate is not None or reason != "no Dependabot merge at current main":
            break
        if wait_for_merge and attempt < 6:
            time.sleep(5)
    return candidate, reason


def post_merge(api, enabled=False, expected_sha=None, expected_pr=None):
    if enabled is not True:
        return "standby: no post-merge dispatch"
    candidate, reason = post_merge_candidate(api)
    if candidate is None:
        return reason
    number, main = candidate["pr"], candidate["main"]
    if expected_sha is not None or expected_pr is not None:
        require(main == expected_sha and number == expected_pr, "post-merge plan changed before dispatch")
    # Exact workflow/ref hardcoded. No arbitrary dispatch supplied by a PR.
    try:
        api.mutate("POST", route("actions/workflows/ci.yml/dispatches"),
                   {"ref": "main", "inputs": {"dependabot_merge_pr": str(number)}})
    except Exception:
        observed = api.pages(route(f"actions/workflows/ci.yml/runs?branch=main&head_sha={main}"), "workflow_runs")
        require(any(r.get("event") == "workflow_dispatch" and r.get("display_title") == PREFIX + str(number)
                    for r in observed), "dispatch outcome uncertain; no retry")
    return "verified current-main CI dispatched"


def targets(api, event_name, event):
    if event_name == "pull_request_target":
        return [event["pull_request"]["number"]], None
    if event_name == "workflow_run":
        alert = event["workflow_run"]
        live = api.get(route(f"actions/runs/{alert['id']}"))
        require(live.get("repository", {}).get("full_name") == REPOSITORY, "foreign notification")
        path = live.get("path", "").split("@")[0]
        require(path in {CI_PATH, NOTICE_PATH, ".github/workflows/dependabot-ready.yml"}, "unrecognized notification workflow")
        if path == CI_PATH and live.get("event") != "pull_request":
            return [], None
        allowed_events = {CI_PATH: {"pull_request"}, NOTICE_PATH: {"pull_request_review", "pull_request_review_comment"},
                          ".github/workflows/dependabot-ready.yml": {"pull_request_target"}}
        require(live.get("event") in allowed_events[path], "wrong notification event")
        numbers = [p["number"] for p in live.get("pull_requests", [])]
        if len(numbers) != 1:
            # Some review and fork workflow runs omit PR associations. Reconcile
            # authoritative open PRs rather than guess an association or fail
            # inspect. Each bot still needs its own exact full CI proof.
            return [p["number"] for p in api.pages(route("pulls?state=open"))
                    if p.get("base", {}).get("ref") == "main" or bot(p)], None
        return numbers, alert if path == CI_PATH else None
    require(event_name in {"schedule", "workflow_dispatch", "push"}, "unsupported coordinator event")
    return [p["number"] for p in api.pages(route("pulls?state=open"))
                    if p.get("base", {}).get("ref") == "main" or bot(p)], None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("targets", "coordinate", "post-merge-plan", "post-merge", "verify-post-merge"))
    parser.add_argument("--pr", type=int)
    parser.add_argument("--expected-sha")
    args = parser.parse_args()
    try:
        if args.command in {"coordinate", "post-merge", "verify-post-merge"}:
            require(type(args.pr) is int and args.pr > 0, "missing/invalid PR number")
        if args.command in {"coordinate", "post-merge-plan", "post-merge"}:
            trusted_context(os.environ)
        api = GitHub()
        require(os.environ.get("GITHUB_REPOSITORY", REPOSITORY) == REPOSITORY, "foreign workflow repository")
        enabled = os.environ.get("DEPENDABOT_AUTO_MERGE_ENABLED") == "true"
        if args.command == "verify-post-merge":
            verify_post_merge(api, args.pr, args.expected_sha)
            print("Verified actual Dependabot merge at exact current main.")
            return 0
        if args.command == "post-merge-plan":
            candidate, reason = post_merge_plan(api, enabled, os.environ.get("WAIT_FOR_BOT_MERGE") == "true")
            if "GITHUB_OUTPUT" in os.environ:
                with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                    output.write("needed=" + str(candidate is not None).lower() + "\n")
                    if candidate is not None:
                        output.write("pr=" + str(candidate["pr"]) + "\n")
                        output.write("main_sha=" + candidate["main"] + "\n")
            print(reason)
            return 0
        if args.command == "post-merge":
            require(bool(SHA.fullmatch(args.expected_sha or "")), "missing/invalid planned main SHA")
            print(post_merge(api, enabled, args.expected_sha, args.pr))
            return 0
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        numbers, notification = targets(api, os.environ["GITHUB_EVENT_NAME"], event)
        if args.command == "targets":
            require(all(type(n) is int and n > 0 for n in numbers), "invalid PR number")
            if "GITHUB_OUTPUT" in os.environ:
                with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                    bots, manual, reporter_prs = [], [], []
                    for number in sorted(set(numbers)):
                        pr = api.get(route(f"pulls/{number}"))
                        (bots if bot(pr) else manual).append(number)
                        # Retargeted bots still need protective cancellation,
                        # but only open main PRs have a native Ready surface.
                        if pr.get("state") == "open" and pr.get("base", {}).get("ref") == "main":
                            reporter_prs.append(number)
                    output.write("prs=" + json.dumps(reporter_prs) + "\n")
                    output.write("bot_prs=" + json.dumps(bots) + "\n")
                    output.write("manual_prs=" + json.dumps(manual) + "\n")
            print("Current metadata targets:", sorted(set(numbers)))
        else:
            require(args.pr in numbers, "PR does not match notification")
            print(coordinate(api, args.pr, enabled, notification))
    except (Rejected, KeyError, TypeError, OSError, urllib.error.URLError) as error:
        print("Dependabot policy rejected: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
