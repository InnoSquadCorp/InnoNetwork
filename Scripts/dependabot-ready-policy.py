#!/usr/bin/env python3
"""Read-only native Ready verdicts and narrowly bounded reporter refreshes."""
import argparse
from datetime import datetime, timezone, timedelta
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse

REPORTER_PATH = ".github/workflows/dependabot-ready.yml"
SOURCE_STEP = "Evaluate Ready snapshot from "
ENFORCE_STEP = "Enforce Ready snapshot"
REQUEST_STEP = "Request verified native Ready refresh"
BINDING = re.compile(r"Ready v1 pr:([1-9][0-9]*) head:([a-f0-9]{40}) head-repo:([1-9][0-9]*) base-repo:([1-9][0-9]*) base:main source:([a-f0-9]{40})")


def policy_module():
    spec = importlib.util.spec_from_file_location("merge_policy", Path(__file__).with_name("dependabot-merge-policy.py"))
    policy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(policy)
    return policy


def event_binding(api, p, run, pr, number, head):
    # The fixed trusted workflow formats these GitHub event fields, never the
    # PR title/body. A matching branch/SHA alone cannot establish PR identity.
    match = BINDING.fullmatch(run.get("display_title", ""))
    p.require(match is not None, "native reporter lacks trusted event binding")
    identity = (int(match[1]), match[2], int(match[3]), int(match[4]))
    p.require(identity == (number, head, pr["head"]["repo"]["id"], pr["base"]["repo"]["id"]),
              "native reporter event binding disagrees with current PR")
    # Historical checks need their original trusted identity, not current policy
    # equality. Latest verdicts/writers separately require source_compatible.
    source_ancestor(api, p, match[5])
    return match[5]


def validate_run(api, p, run, workflow, repo, pr, number, head):
    links = run.get("pull_requests", [])
    p.require(isinstance(links, list), "malformed native reporter PR associations")
    p.require(run.get("workflow_id") == workflow["id"] and run.get("path", "").split("@")[0] == REPORTER_PATH and
              run.get("event") == "pull_request_target" and run.get("head_sha") == head and
              run.get("head_branch") == pr["head"]["ref"] and
              run.get("repository", {}).get("id") == repo["id"] and
              run.get("head_repository", {}).get("id") == pr["head"]["repo"]["id"] and
              pr["base"]["repo"]["id"] == repo["id"] and pr["base"]["ref"] == "main" and
              type(run.get("run_attempt")) is int and run["run_attempt"] > 0 and type(run.get("check_suite_id")) is int,
              "invalid native reporter PR/head/workflow provenance")
    if links:
        p.require([x.get("number") for x in links] == [number] and links[0].get("head", {}).get("sha") == head and
                  links[0].get("base", {}).get("ref") == "main" and
                  links[0].get("base", {}).get("repo", {}).get("id") == repo["id"],
                  "invalid native reporter PR association")
    if not links or run.get("display_title", "").startswith("Ready v1 "):
        event_binding(api, p, run, pr, number, head)


def runs(api, p, number, head):
    repo = api.get(p.route(""))
    pr = current_pr(api, p, number, head)
    workflow = api.get(p.route("actions/workflows/dependabot-ready.yml"))
    p.require(workflow.get("path") == REPORTER_PATH and workflow.get("state") == "active", "native reporter missing/inactive")
    candidates = api.pages(p.route(f"actions/workflows/dependabot-ready.yml/runs?event=pull_request_target&head_sha={head}"), "workflow_runs")
    result = []
    for item in candidates:
        numbers = [x.get("number") for x in item.get("pull_requests", [])]
        if number not in numbers:
            match = BINDING.fullmatch(item.get("display_title", ""))
            relevant = not numbers and ((match and int(match[1]) == number) or
                (item.get("head_branch") == pr["head"].get("ref") and
                 item.get("head_repository", {}).get("id") == pr["head"].get("repo", {}).get("id")))
            if not relevant:
                continue
        run = api.get(p.route(f"actions/runs/{item['id']}"))
        p.require(run.get("id") == item["id"], "native reporter detail changed identity")
        validate_run(api, p, run, workflow, repo, pr, number, head)
        result.append(run)
    return result


def latest(api, p, number, head):
    candidates = runs(api, p, number, head)
    if not candidates:
        raise p.NeedsFreshReporter("missing_native_reporter",
                                   "no native reporter: fresh PR lifecycle event required after trusted-main deployment")
    return max(candidates, key=lambda r: (r["run_number"], r["id"]))


def job_record(api, p, run, attempt=None, require_steps=True):
    attempt = run["run_attempt"] if attempt is None else attempt
    jobs = api.pages(p.route(f"actions/runs/{run['id']}/attempts/{attempt}/jobs"), "jobs")
    p.require(len(jobs) == 1 and jobs[0].get("name") == p.READY, "native reporter must have exactly one fixed-name job")
    job = jobs[0]
    p.require(type(job.get("id")) is int and job["id"] > 0, "invalid native job ID")
    url = job.get("check_run_url", "")
    prefix = f"https://api.github.com/repos/{p.REPOSITORY}/check-runs/"
    p.require(url.startswith(prefix) and url[len(prefix):].isdigit(), "native job lacks check association")
    check = api.get(p.route("check-runs/" + url[len(prefix):]))
    p.require(check.get("id") == int(url[len(prefix):]) and check.get("name") == p.READY and
              check.get("app", {}).get("id") == p.APP and check.get("head_sha") == run["head_sha"] and
              check.get("check_suite", {}).get("id") == run["check_suite_id"] and
              check.get("details_url") == f"https://github.com/{p.REPOSITORY}/actions/runs/{run['id']}/job/{job['id']}",
              "native reporter check has wrong job/app/head/suite provenance")
    steps = job.get("steps") or []
    source_steps = [s for s in steps if str(s.get("name", "")).startswith(SOURCE_STEP)]
    binding = BINDING.fullmatch(run.get("display_title", ""))
    if binding:
        expected = SOURCE_STEP + binding[5] + " for " + run["display_title"].rsplit(" source:", 1)[0]
        p.require(len(source_steps) == 1 and source_steps[0]["name"] == expected,
                  "native event/job source binding mismatch")
    if not require_steps:
        return job, check, None
    p.require(len(source_steps) == 1 and p.SHA.fullmatch(source_steps[0]["name"][len(SOURCE_STEP):].split(" ", 1)[0]) and
              (binding is not None or p.SHA.fullmatch(source_steps[0]["name"][len(SOURCE_STEP):])) and
              sum(s.get("name") == ENFORCE_STEP for s in steps) == 1, "native reporter evaluation/enforce steps missing")
    source = source_steps[0]["name"][len(SOURCE_STEP):].split(" ", 1)[0]
    p.require(binding is None or binding[5] == source, "native event/job source mismatch")
    return job, check, source


def source_ancestor(api, p, source):
    main = api.get(p.route("git/ref/heads/main"))["object"]["sha"]
    p.require(bool(p.SHA.fullmatch(main or "")), "invalid trusted main SHA")
    comparison = api.get(p.route(f"compare/{source}...{main}"))
    p.require(comparison.get("status") in {"identical", "ahead"} and
              comparison.get("merge_base_commit", {}).get("sha") == source, "reporter source is not trusted main ancestry")
    return main


def verified_absence(api, p, source, path):
    """A contents 404 is lifecycle skew only if the immutable tree proves it."""
    commit = api.get(p.route(f"git/commits/{source}"))
    tree_sha = commit.get("tree", {}).get("sha")
    p.require(commit.get("sha") == source and isinstance(tree_sha, str) and p.SHA.fullmatch(tree_sha),
              "missing/malformed historical commit tree identity")
    tree = api.get(p.route(f"git/trees/{tree_sha}?recursive=1"))
    entries = tree.get("tree")
    p.require(tree.get("sha") == tree_sha and tree.get("truncated") is False and isinstance(entries, list) and
              all(isinstance(item, dict) and isinstance(item.get("path"), str) for item in entries),
              "incomplete historical tree cannot prove file absence")
    p.require(not any(item["path"] == path for item in entries),
              "contents lookup failed for an existing historical policy file")


def source_compatible(api, p, source):
    main = source_ancestor(api, p, source)
    # Re-running preserves the old workflow definition and privileges. Do not
    # rerun an obsolete definition while checking out newer policy code.
    obsolete = False
    for path in (REPORTER_PATH, p.COORDINATOR_PATH, "Scripts/dependabot-ready-policy.py", "Scripts/dependabot-merge-policy.py", "Scripts/ci-metadata-policy.py"):
        current = api.get(p.route(f"contents/{path}?ref={main}"))
        p.require(isinstance(current.get("sha"), str) and p.SHA.fullmatch(current["sha"]),
                  "missing/malformed reporter definition/policy blob identity")
        try:
            old = api.get(p.route(f"contents/{path}?ref={source}"))
        except urllib.error.HTTPError as error:
            if error.code != 404 or source == main:
                raise
            verified_absence(api, p, source, path)
            obsolete = True
            continue
        p.require(isinstance(old.get("sha"), str) and p.SHA.fullmatch(old["sha"]),
                  "missing/malformed reporter definition/policy blob identity")
        obsolete = obsolete or old["sha"] != current["sha"]
    # Validate every identity before classifying normal policy deployment skew.
    if obsolete:
        raise p.NeedsFreshReporter("obsolete_reporter_policy",
                                   "obsolete reporter definition/policy: fresh PR lifecycle event required")


def controlled_verdict(p, run, job, check):
    p.require(run.get("status") == "completed" and run.get("conclusion") in {"success", "failure"} and
              job.get("status") == "completed" and job.get("conclusion") in {"success", "failure"} and
              check.get("status") == "completed" and check.get("conclusion") == job["conclusion"],
              "reporter must be terminal success/failure; cancelled/unknown requires operator recovery")
    for step in job["steps"]:
        allowed = {"success", "failure"} if step["name"] == ENFORCE_STEP else {"success"}
        p.require(step.get("status") == "completed" and step.get("conclusion") in allowed,
                  "reporter infrastructure/API/evaluation failure requires operator recovery")
    enforced = next(s["conclusion"] for s in job["steps"] if s["name"] == ENFORCE_STEP)
    p.require(run["conclusion"] == job["conclusion"] == enforced, "native reporter verdict disagrees with job/run")
    return enforced == "success"


def current_pr(api, p, number, head=None):
    pr = api.get(p.route(f"pulls/{number}"))
    p.require(pr.get("number") == number and pr.get("state") == "open" and pr.get("base", {}).get("ref") == "main" and
              pr.get("base", {}).get("repo", {}).get("full_name") == p.REPOSITORY and
              bool(p.SHA.fullmatch(pr.get("head", {}).get("sha", ""))) and
              (head is None or pr["head"]["sha"] == head), "PR/head/base changed")
    return pr


def desired(api, p, number, enabled):
    pr = current_pr(api, p, number)
    if not p.bot(pr):
        return True, "Manual PR: normal CI/review requirements remain; no auto-merge approval."
    if not enabled:
        return False, "Standby: new bot auto-merge approvals disabled."
    try:
        first, second = p.proof(api, number), p.proof(api, number)
        p.same(first, second)
        return True, "Full exact-head/base/CI proof currently eligible."
    except p.Rejected as error:
        return False, "Blocked: " + str(error)


def snapshot(api, p, number, enabled):
    env = os.environ
    p.require(env.get("GITHUB_REPOSITORY") == p.REPOSITORY and env.get("GITHUB_REF") == "refs/heads/main" and
              env.get("GITHUB_WORKFLOW_REF") == p.REPOSITORY + "/" + REPORTER_PATH + "@refs/heads/main" and
              env.get("GITHUB_EVENT_NAME") == "pull_request_target" and env.get("GITHUB_JOB") == "ready",
              "native snapshot requires trusted PR-target reporter context")
    event = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_text())
    p.require(event.get("pull_request", {}).get("number") == number, "native snapshot event/PR mismatch")
    pr = current_pr(api, p, number)
    head = pr["head"]["sha"]
    event_pr = event["pull_request"]
    p.require(event_pr.get("head", {}).get("sha") == head and
              event_pr.get("head", {}).get("ref") == pr["head"]["ref"] and
              event_pr.get("head", {}).get("repo", {}).get("id") == pr["head"]["repo"]["id"] and
              event_pr.get("base", {}).get("ref") == "main" and
              event_pr.get("base", {}).get("repo", {}).get("id") == pr["base"]["repo"]["id"],
              "native snapshot event head/base/repository changed")
    run = latest(api, p, number, head)
    p.require(str(run["id"]) == env.get("GITHUB_RUN_ID") and str(run["run_attempt"]) == env.get("GITHUB_RUN_ATTEMPT"),
              "obsolete native reporter run/attempt")
    # Future timeline steps need not be exposed while this step is executing.
    # Source identity comes from immutable GitHub context, not a future step.
    job, check, _ = job_record(api, p, run, require_steps=False)
    source = env.get("GITHUB_WORKFLOW_SHA", "")
    p.require(bool(p.SHA.fullmatch(source)), "invalid immutable reporter source")
    binding = BINDING.fullmatch(run.get("display_title", ""))
    p.require(binding is None or binding[5] == source, "native event/environment source mismatch")
    p.require(run.get("status") == job.get("status") == check.get("status") == "in_progress" and
              run.get("conclusion") is None and check.get("conclusion") is None, "native reporter is no longer running")
    source_compatible(api, p, source)
    verdict, reason = desired(api, p, number, enabled)
    current_pr(api, p, number, head)
    again = latest(api, p, number, head)
    p.require((again["id"], again["run_attempt"]) == (run["id"], run["run_attempt"]) and
              again.get("status") == "in_progress" and again.get("conclusion") is None, "reporter superseded/cancelled before verdict")
    return verdict, reason


def verified_check_ids(api, p, number, head):
    ids = set()
    sources = runs(api, p, number, head)
    newest = max(((r["run_number"], r["id"]) for r in sources), default=None)
    for run in sources:
        for attempt in range(1, run["run_attempt"] + 1):
            jobs = api.pages(p.route(f"actions/runs/{run['id']}/attempts/{attempt}/jobs"), "jobs")
            if not jobs:
                older = (run["run_number"], run["id"]) != newest or attempt < run["run_attempt"]
                previous = run if attempt == run["run_attempt"] else api.get(p.route(f"actions/runs/{run['id']}/attempts/{attempt}"))
                p.require(older and previous.get("id") == run["id"] and previous.get("head_sha") == head and
                          previous.get("workflow_id") == run["workflow_id"] and previous.get("event") == "pull_request_target" and
                          previous.get("status") == "completed" and previous.get("conclusion") == "cancelled",
                          "empty native attempt is not a verified superseded cancellation")
                # No check IDs are exempted. Any actual orphan/legacy check
                # still fails the main proof as unassociated evidence.
                continue
            _, check, _ = job_record(api, p, run, attempt, require_steps=False)
            p.require(check["id"] not in ids, "duplicate native reporter check identity")
            ids.add(check["id"])
    return ids


def require_success(api, p, number, head):
    current_pr(api, p, number, head)
    run = latest(api, p, number, head)
    job, check, source = job_record(api, p, run)
    source_compatible(api, p, source)
    p.require(controlled_verdict(p, run, job, check), "latest native Ready verdict is not success")
    return run["id"], run["run_attempt"], check["id"]


def refresh_plan(api, p, number, enabled):
    pr = current_pr(api, p, number)
    run = latest(api, p, number, pr["head"]["sha"])
    if run.get("status") in {"queued", "pending", "waiting", "requested", "in_progress"}:
        return None
    job, check, source = job_record(api, p, run)
    source_compatible(api, p, source)
    actual = controlled_verdict(p, run, job, check)
    expected, _ = desired(api, p, number, enabled)
    if actual == expected:
        return None
    return dict(pr=number, head=pr["head"]["sha"], run=run["id"], attempt=run["run_attempt"], job=job["id"])


def refresh_batch(api, p, numbers, enabled):
    """Isolate verified lifecycle gaps, not API/provenance failures or verdicts."""
    targets, blocked = [], []
    for number in sorted(numbers):
        head = current_pr(api, p, number)["head"]["sha"]
        try:
            target = refresh_plan(api, p, number, enabled)
        except p.NeedsFreshReporter as error:
            p.require(error.reason in {"missing_native_reporter", "obsolete_reporter_policy"},
                      "unrecognized native reporter recovery reason")
            current_pr(api, p, number, head)
            blocked.append(dict(pr=number, head=head, reason=error.reason))
        else:
            current_pr(api, p, number, head)
            if target is not None:
                p.require(target["head"] == head, "refresh head changed during batch planning")
                targets.append(target)
    return targets, blocked


def plan_summary(p, targets, blocked):
    lines = ["## Native Ready refresh plan", "",
             f"Refresh targets: {len(targets)}; lifecycle recovery required: {len(blocked)}.",
             "Planning success is not a Ready verdict or permission to merge."]
    for item in blocked:
        lines.append(f"- [PR #{item['pr']}](https://github.com/{p.REPOSITORY}/pull/{item['pr']}) "
                     f"at `{item['head']}`: `{item['reason']}`; no refresh or Ready approval emitted.")
    if blocked:
        lines.extend(["", "A maintainer must authorize a fresh supported PR lifecycle event after trusted-main deployment.",
                      "Re-running this coordinator or an obsolete reporter cannot bootstrap a native PR check.",
                      f"See the [bootstrap and recovery runbook](https://github.com/{p.REPOSITORY}/blob/main/docs/CIAutomation.md#native-ready-bootstrap-and-recovery)."])
    return "\n".join(lines) + "\n"


def claim_name(target):
    return f"Ready refresh PR{target['pr']} run{target['run']} attempt{target['attempt']}"


def reject_prior_claim(api, p, target, reporter):
    writer_id = int(os.environ["GITHUB_RUN_ID"])
    writer_attempt = int(os.environ["GITHUB_RUN_ATTEMPT"])
    writer = api.get(p.route(f"actions/runs/{writer_id}"))
    workflow = api.get(p.route("actions/workflows/dependabot-auto-merge.yml"))
    p.require(workflow.get("path") == p.COORDINATOR_PATH and workflow.get("state") == "active" and
              writer.get("workflow_id") == workflow.get("id") and writer.get("run_attempt") == writer_attempt and
              writer.get("event") == os.environ.get("GITHUB_EVENT_NAME") and
              writer.get("path", "").split("@")[0] == p.COORDINATOR_PATH and
              writer.get("repository", {}).get("full_name") == p.REPOSITORY and
              writer.get("created_at", "") >= reporter.get("created_at", "~"), "writer predates reporter or has foreign identity")
    query = urllib.parse.urlencode({"created": ">=" + reporter["created_at"]})
    writers = api.pages(p.route("actions/workflows/dependabot-auto-merge.yml/runs?" + query), "workflow_runs")
    claims = []
    for run in writers:
        p.require(run.get("path", "").split("@")[0] == p.COORDINATOR_PATH, "foreign refresh history")
        for attempt in range(1, run["run_attempt"] + 1):
            for job in api.pages(p.route(f"actions/runs/{run['id']}/attempts/{attempt}/jobs"), "jobs"):
                if job.get("name") == claim_name(target):
                    claims.append((run, attempt, job))
    own = [job for run, attempt, job in claims if run["id"] == writer_id and attempt == writer_attempt]
    p.require(len(own) == 1 and own[0].get("status") == "in_progress" and isinstance(own[0].get("started_at"), str),
              "current refresh claim missing/ambiguous/not running")
    started = datetime.fromisoformat(own[0]["started_at"].replace("Z", "+00:00"))
    p.require(started.tzinfo is not None, "current writer has no authoritative start time")
    for run, attempt, job in claims:
        if run["id"] == writer_id and attempt == writer_attempt:
            continue
        if job.get("status") == "completed" and job.get("conclusion") == "skipped":
            continue
        if job.get("status") == "queued":
            created = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
            p.require(run.get("status") in {"queued", "pending", "waiting", "in_progress", "requested"} and
                      created.tzinfo is not None and created > started,
                      "prior refresh queued/terminal history is ambiguous; no automatic retry")
            # A run created after this writer started cannot have executed
            # beforehand; per-PR concurrency prevents it executing alongside us.
            continue
        step = next((s for s in (job.get("steps") or []) if s.get("name") == REQUEST_STEP), None)
        p.require(step is not None and step.get("conclusion") == "skipped",
                  "prior refresh attempt exists/uncertain: explicitly rerun reporter for a new source attempt")


def refresh(api, p, target, enabled):
    p.trusted_context(os.environ)
    p.require(os.environ.get("GITHUB_JOB") == "ready-refresh" and
              os.environ.get("GITHUB_EVENT_NAME") in {"workflow_run", "schedule", "push", "workflow_dispatch"},
              "refresh writer requires its scoped background job")
    p.require(set(target) == {"pr", "head", "run", "attempt", "job"} and
              all(type(target[k]) is int and target[k] > 0 for k in ("pr", "run", "attempt", "job")) and
              isinstance(target["head"], str) and p.SHA.fullmatch(target["head"]), "invalid refresh target")
    source = os.environ.get("GITHUB_WORKFLOW_SHA", "")
    p.require(bool(p.SHA.fullmatch(source)), "invalid immutable writer source")
    source_compatible(api, p, source)
    current_pr(api, p, target["pr"], target["head"])
    observed = refresh_plan(api, p, target["pr"], enabled)
    if observed is None:
        return "No native refresh needed or reporter already running."
    p.require(observed == target, "refresh plan became obsolete")
    run = latest(api, p, target["pr"], target["head"])
    created = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
    age = datetime.now(timezone.utc) - created
    p.require(timedelta(0) <= age < timedelta(days=30) and run["run_attempt"] < 50,
              "native reporter rerun age/attempt limit reached; fresh PR lifecycle event required")
    reject_prior_claim(api, p, target, run)
    # The writer has no contents/pull-request write permission. Protective bot
    # cancellation belongs to the existing privileged coordinator before this
    # writer is admitted by workflow needs.
    p.require(not p.bot(current_pr(api, p, target["pr"], target["head"])) or
              not api.get(p.route(f"pulls/{target['pr']}" )).get("auto_merge"),
              "armed bot must be protectively cancelled before Ready refresh")
    p.require(refresh_plan(api, p, target["pr"], enabled) == target, "reporter/eligibility changed before refresh")
    try:
        api.mutate("POST", p.route(f"actions/jobs/{target['job']}/rerun"), {})
    except Exception:
        # A lost reply is not permission to POST again. Observed writer job
        # history conservatively blocks another automatic request for this tuple.
        pass
    for index in range(4):
        live = api.get(p.route(f"actions/runs/{target['run']}"))
        if live.get("run_attempt", 0) > target["attempt"]:
            p.require(live.get("id") == target["run"] and live.get("display_title") == run.get("display_title"),
                      "rerun reporter identity/binding changed")
            validate_run(api, p, live, {"id": run["workflow_id"]}, api.get(p.route("")),
                         current_pr(api, p, target["pr"], target["head"]), target["pr"], target["head"])
            return "Verified native reporter rerun requested; final readiness remains pending."
        if index < 3:
            time.sleep(2)
    raise p.Rejected("native reporter refresh outcome unconfirmed; no retry, inspect or explicitly rerun reporter")


def main():
    p = policy_module()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("snapshot", "plan", "refresh"))
    parser.add_argument("--pr", type=int)
    args = parser.parse_args()
    try:
        if args.command in {"plan", "refresh"}:
            p.trusted_context(os.environ)
        api = p.GitHub()
        enabled = os.environ.get("DEPENDABOT_AUTO_MERGE_ENABLED") == "true"
        if args.command == "snapshot":
            p.require(type(args.pr) is int and args.pr > 0, "invalid native PR number")
            verdict, reason = snapshot(api, p, args.pr, enabled)
            with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
                stream.write("ready=" + str(verdict).lower() + "\n")
            print(reason)
        elif args.command == "plan":
            p.trusted_context(os.environ)
            numbers = json.loads(os.environ["PR_NUMBERS"])
            p.require(isinstance(numbers, list) and all(type(n) is int and n > 0 for n in numbers) and len(set(numbers)) == len(numbers), "invalid refresh PR targets")
            plans, blocked = refresh_batch(api, p, numbers, enabled)
            summary = plan_summary(p, plans, blocked)
            print(summary, end="")
            if os.environ.get("GITHUB_STEP_SUMMARY"):
                with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
                    stream.write(summary)
            with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
                stream.write("targets=" + json.dumps(plans, separators=(",", ":")) + "\n")
                stream.write("blocked=" + json.dumps(blocked, separators=(",", ":")) + "\n")
        else:
            print(refresh(api, p, json.loads(os.environ["REFRESH_TARGET"]), enabled))
        return 0
    except (p.Rejected, KeyError, TypeError, ValueError, OSError) as error:
        print("Native Ready rejected: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
