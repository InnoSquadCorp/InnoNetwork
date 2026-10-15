#!/usr/bin/env python3
"""Read-only native arming receipts; only the coordinator may emit a receipt."""
from datetime import datetime
import hashlib
import json
import os
import re
import urllib.parse

PREFIX = "Native arm v1 "
PATTERN = re.compile(r"Native arm v1 pr:([1-9][0-9]*) proof:([0-9a-f]{64}) ready:([1-9][0-9]*):([1-9][0-9]*):([1-9][0-9]*):([1-9][0-9]*) source:([0-9a-f]{40}) arming:([0-9a-f]{64})")
GATE_STEP = "Gate native auto-merge on exact current CI proof"
# GraphQL Bot.login omits the REST-only [bot] suffix.
ACTOR = {"login": "github-actions", "databaseId": 41898282, "__typename": "Bot"}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def proof_digest(number, proof):
    return digest(dict(pr=number, **{key: proof[key] for key in ("head", "base", "merge", "run", "attempt", "node")}))


def timestamp(p, value):
    p.require(isinstance(value, str) and value.endswith("Z"), "native arm timestamp missing or malformed")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise p.Rejected("native arm timestamp malformed") from error
    p.require(parsed.tzinfo is not None, "native arm timestamp is not timezone-aware")
    return parsed


def state(api, p, number, proof):
    owner, name = p.REPOSITORY.split("/")
    data = api.graphql('''query($owner:String!,$name:String!,$number:Int!) {
      repository(owner:$owner,name:$name) { nameWithOwner pullRequest(number:$number) {
        id headRefOid autoMergeRequest { enabledAt mergeMethod enabledBy {
          login __typename ... on Bot { databaseId }
        } }
        timelineItems(last:1,itemTypes:[AUTO_MERGE_ENABLED_EVENT,AUTO_MERGE_DISABLED_EVENT,AUTO_REBASE_ENABLED_EVENT,AUTO_SQUASH_ENABLED_EVENT]) {
          nodes {
            __typename
            ... on AutoMergeEnabledEvent { id createdAt actor { login __typename ... on Bot { databaseId } } }
            ... on AutoSquashEnabledEvent { id createdAt actor { login __typename ... on Bot { databaseId } } }
            ... on AutoMergeDisabledEvent { id createdAt }
            ... on AutoRebaseEnabledEvent { id createdAt }
          }
        }
      } }
    }''', {"owner": owner, "name": name, "number": number})
    repo = data.get("repository") if isinstance(data, dict) else None
    pr = repo.get("pullRequest") if isinstance(repo, dict) else None
    p.require(isinstance(repo, dict) and repo.get("nameWithOwner") == p.REPOSITORY and
              isinstance(pr, dict) and pr.get("id") == proof["node"] and pr.get("headRefOid") == proof["head"],
              "native arm repository/PR/head identity changed")
    arm = pr.get("autoMergeRequest")
    p.require(isinstance(arm, dict) and arm.get("mergeMethod") == "SQUASH" and arm.get("enabledBy") == ACTOR,
              "native arm is absent or not the expected Actions squash request")
    timestamp(p, arm.get("enabledAt"))
    events = pr.get("timelineItems", {}).get("nodes")
    p.require(isinstance(events, list) and len(events) == 1, "native arm event missing or ambiguous")
    event = events[0]
    p.require(event.get("__typename") in {"AutoMergeEnabledEvent", "AutoSquashEnabledEvent"} and
              isinstance(event.get("id"), str) and bool(event["id"]) and event.get("actor") == ACTOR,
              "native arm latest enable event identity changed")
    timestamp(p, event.get("createdAt"))
    return dict(arm, event=event)


def trusted_origin(p, run, workflow, repo, number, head):
    if not (run.get("workflow_id") == workflow["id"] and
            run.get("path", "").split("@")[0] == p.COORDINATOR_PATH and
            run.get("repository", {}).get("id") == repo["id"] and
            run.get("head_repository", {}).get("id") == repo["id"] and
            run.get("event") in {"pull_request_target", "workflow_run", "schedule", "push", "workflow_dispatch"}):
        return False
    if run["event"] == "pull_request_target":
        links = run.get("pull_requests", [])
        return (isinstance(links, list) and run.get("head_sha") == head and
                [link.get("number") for link in links] == [number] and
                links[0].get("head", {}).get("sha") == head and links[0].get("base", {}).get("ref") == "main" and
                links[0].get("base", {}).get("repo", {}).get("id") == repo["id"])
    return run.get("head_branch") == "main" and bool(p.SHA.fullmatch(run.get("head_sha", "")))


def issuer_context(api, p, ready, number, head):
    source = os.environ.get("GITHUB_WORKFLOW_SHA", "")
    p.require(bool(p.SHA.fullmatch(source)) and os.environ.get("GITHUB_JOB") == "bot-ready" and
              "GITHUB_OUTPUT" in os.environ, "native arming requires immutable scoped coordinator output")
    ready.source_compatible(api, p, source)
    run_id, attempt = int(os.environ["GITHUB_RUN_ID"]), int(os.environ["GITHUB_RUN_ATTEMPT"])
    run = api.get(p.route(f"actions/runs/{run_id}"))
    workflow = api.get(p.route("actions/workflows/dependabot-auto-merge.yml"))
    reporter = ready.latest(api, p, number, head)
    p.require(workflow.get("path") == p.COORDINATOR_PATH and workflow.get("state") == "active" and
              run.get("id") == run_id and run.get("run_attempt") == attempt and
              run.get("event") == os.environ.get("GITHUB_EVENT_NAME") and
              run.get("status") == "in_progress" and run.get("conclusion") is None and
              trusted_origin(p, run, workflow, api.get(p.route("")), number, head) and
              (run["event"] == "pull_request_target" or run.get("head_sha") == source),
              "native receipt issuer has stale or untrusted execution identity")
    # Receipt discovery and the rerun writer both start at the reporter's
    # creation time. An older queued/lifecycle coordinator must not arm an
    # undiscoverable receipt; the reporter's next workflow_run wake can retry.
    p.require(timestamp(p, run.get("created_at")) >= timestamp(p, reporter.get("created_at")),
              "coordinator predates selected reporter; wait for a fresh reporter wake")


def failed_reporter(api, p, ready, number, head):
    ready.current_pr(api, p, number, head)
    run = ready.latest(api, p, number, head)
    job, check, source = ready.job_record(api, p, run)
    ready.source_compatible(api, p, source)
    p.require(not ready.controlled_verdict(p, run, job, check),
              "native Ready must be controlled failure before arming; refresh unarmed success first")
    return dict(run=run["id"], attempt=run["run_attempt"], job=job["id"], check=check["id"])


def receipt(number, proof, reporter, source, arm):
    return (f"{PREFIX}pr:{number} proof:{proof_digest(number, proof)} "
            f"ready:{reporter['run']}:{reporter['attempt']}:{reporter['job']}:{reporter['check']} "
            f"source:{source} arming:{digest(arm)}")


def emit(api, p, ready, number, proof, reporter, arm):
    source = os.environ.get("GITHUB_WORKFLOW_SHA", "")
    p.require(bool(p.SHA.fullmatch(source)), "native receipt requires immutable coordinator source")
    ready.source_compatible(api, p, source)
    p.require(os.environ.get("GITHUB_JOB") == "bot-ready" and "GITHUB_OUTPUT" in os.environ,
              "native receipt requires the scoped coordinator output")
    value = receipt(number, proof, reporter, source, arm)
    p.require(PATTERN.fullmatch(value) is not None, "invalid native receipt output")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write("arm_receipt=" + value + "\n")


def original_failure(api, p, ready, number, reporter, parts, snapshot):
    run_id, attempt, job_id, check_id = map(int, parts.group(3, 4, 5, 6))
    p.require(reporter["id"] == run_id and
              reporter["run_attempt"] in ({attempt + 1} if snapshot else {attempt, attempt + 1}),
              "native receipt is not for this reporter attempt")
    if reporter["run_attempt"] == attempt + 1:
        if reporter.get("status") == "completed":
            live_job, live_check, live_source = ready.job_record(api, p, reporter)
            ready.source_compatible(api, p, live_source)
            p.require(ready.controlled_verdict(p, reporter, live_job, live_check),
                      "receipt reporter rerun did not succeed")
        else:
            p.require(reporter.get("status") in {"queued", "pending", "waiting", "requested", "in_progress"} and
                      reporter.get("conclusion") is None, "receipt reporter rerun has unknown state")
    old = reporter
    if reporter["run_attempt"] != attempt:
        old = api.get(p.route(f"actions/runs/{run_id}/attempts/{attempt}"))
        p.require(old.get("run_attempt") == attempt and all(old.get(k) == reporter.get(k) for k in
                  ("id", "run_number", "check_suite_id", "display_title")), "native receipt historical attempt identity changed")
        ready.validate_run(api, p, old, {"id": reporter["workflow_id"]}, api.get(p.route("")),
                           ready.current_pr(api, p, number, reporter["head_sha"]), number, reporter["head_sha"])
    job, check, source = ready.job_record(api, p, old, attempt)
    ready.source_compatible(api, p, source)
    p.require(job["id"] == job_id and check["id"] == check_id and not ready.controlled_verdict(p, old, job, check),
              "native receipt lacks the original controlled failure barrier")


def verify(api, p, ready, number, proof, reporter, snapshot=False, require_proof=True):
    """Require one current-attempt, successful trusted job receipt and live arm."""
    arm = state(api, p, number, proof)
    expected_proof = proof_digest(number, proof) if require_proof else None
    expected_arm = digest(arm)
    workflow = api.get(p.route("actions/workflows/dependabot-auto-merge.yml"))
    repo = api.get(p.route(""))
    p.require(workflow.get("path") == p.COORDINATOR_PATH and workflow.get("state") == "active", "native receipt workflow inactive")
    query = urllib.parse.urlencode({"created": ">=" + reporter["created_at"]})
    runs = api.pages(p.route("actions/workflows/dependabot-auto-merge.yml/runs?" + query), "workflow_runs")
    matches = []
    for candidate in runs:
        p.require(candidate.get("path", "").split("@")[0] == p.COORDINATOR_PATH, "foreign native receipt history")
        # Reject unrelated list entries before spending detail/job reads. This
        # is only a prefilter; the authoritative detail is revalidated below.
        if not trusted_origin(p, candidate, workflow, repo, number, proof["head"]):
            continue
        run = api.get(p.route(f"actions/runs/{candidate['id']}"))
        # A different PR's untrusted pull_request workflow may reuse this path
        # and step names. Discard foreign origins before interpreting claims.
        if not trusted_origin(p, run, workflow, repo, number, proof["head"]):
            continue
        attempt = run.get("run_attempt")
        p.require(type(attempt) is int and attempt > 0, "native receipt run attempt malformed")
        jobs = api.pages(p.route(f"actions/runs/{run['id']}/attempts/{attempt}/jobs"), "jobs")
        for job in jobs:
            if job.get("name") != f"bot-ready ({number})":
                continue
            claims = [step for step in (job.get("steps") or []) if str(step.get("name", "")).startswith(PREFIX + f"pr:{number} ")]
            if not claims:
                continue
            p.require(len(claims) == 1, "ambiguous native arm receipt steps")
            step = claims[0]
            parts = PATTERN.fullmatch(step["name"])
            p.require(parts is not None, "malformed native arm receipt")
            if (require_proof and parts[2] != expected_proof) or parts[8] != expected_arm:
                continue
            source = parts[7]
            p.require(run.get("id") == candidate["id"] and run.get("workflow_id") == workflow["id"] and
                      run.get("path", "").split("@")[0] == p.COORDINATOR_PATH and
                      run.get("repository", {}).get("id") == repo["id"] and
                      run.get("head_repository", {}).get("id") == repo["id"] and
                      run.get("event") in {"pull_request_target", "workflow_run", "schedule", "push", "workflow_dispatch"},
                      "untrusted native receipt workflow origin")
            if run["event"] == "pull_request_target":
                links = run.get("pull_requests", [])
                p.require(run.get("head_sha") == proof["head"] and [link.get("number") for link in links] == [number] and
                          links[0].get("head", {}).get("sha") == proof["head"] and
                          links[0].get("base", {}).get("ref") == "main" and
                          links[0].get("base", {}).get("repo", {}).get("id") == repo["id"], "native receipt PR source mismatch")
            else:
                p.require(run.get("head_sha") == source and run.get("head_branch") == "main", "native receipt not from default main")
            ready.source_compatible(api, p, source)
            checks = {}
            for item in jobs:
                if item.get("name") in {"inspect", f"bot-ready ({number})"}:
                    url = item.get("check_run_url", "")
                    prefix = f"https://api.github.com/repos/{p.REPOSITORY}/check-runs/"
                    p.require(isinstance(url, str) and url.startswith(prefix) and url[len(prefix):].isdigit(), "native receipt job lacks check")
                    check = api.get(p.route("check-runs/" + url[len(prefix):]))
                    p.require(check.get("id") == int(url[len(prefix):]), "native receipt check ID changed")
                    checks[int(url[len(prefix):])] = check
            check_id = p.coordinator_job_check(job, run, attempt, run["head_sha"], checks)
            check = checks[check_id]
            p.require(job.get("status") == check.get("status") == "completed" and
                      job.get("conclusion") == check.get("conclusion") == "success" and
                      step.get("status") == "completed" and step.get("conclusion") == "success" and
                      all(s.get("status") == "completed" and s.get("conclusion") == "success" for s in job.get("steps", [])) and
                      sum(s.get("name") == GATE_STEP for s in job["steps"]) == 1,
                      "native arm receipt job or proof step did not succeed")
            inspectors = [j for j in jobs if j.get("name") == "inspect"]
            p.require(len(inspectors) == 1, "native receipt source inspector missing")
            inspector = inspectors[0]
            inspection = checks[p.coordinator_job_check(inspector, run, attempt, run["head_sha"], checks)]
            p.require(inspector.get("status") == inspection.get("status") == "completed" and
                      inspector.get("conclusion") == inspection.get("conclusion") == "success" and
                      sum(s.get("name") == p.COORDINATOR_SOURCE_STEP + source and s.get("status") == "completed" and
                          s.get("conclusion") == "success" for s in inspector.get("steps", [])) == 1,
                      "native receipt immutable source not verified")
            started, completed = timestamp(p, job.get("started_at")), timestamp(p, job.get("completed_at"))
            p.require(all(started <= timestamp(p, value) <= completed
                          for value in (arm["enabledAt"], arm["event"]["createdAt"])),
                      "native arm/event does not belong to the receipt job execution")
            original_failure(api, p, ready, number, reporter, parts, snapshot)
            matches.append((run["id"], attempt, job["id"], step["name"]))
    p.require(len(matches) == 1, "missing or ambiguous trusted native arm receipt")
    p.require(state(api, p, number, proof) == arm, "native arm changed during receipt verification")
    return matches[0]
