#!/usr/bin/env python3
"""Rerun PR CI that failed for no reason of its own (stdlib only).

GitHub-hosted macOS capacity sometimes never assigns a runner. The job is then
cancelled with "not acquired by Runner", the aggregate gates fail, and the PR
stays red although none of its code ran. Nothing else retries such a run: the
Dependabot rebase queue skips a current-base PR whose CI failed, and a human PR
waits for someone to notice. This reruns the failed jobs only when every failure
is a lost runner or a gate that merely aggregates other jobs, so a real failure
is never retried, and stops after a few attempts so an outage is left to a human.

A metadata-only gate judges its validation once and exits. One that started
before that validation succeeded, for example because it was admitted the moment
a lost-runner attempt ended, keeps blocking the PR after the retry succeeds. So
when a validation succeeds, the newest metadata gate that failed before that
success is rerun, once per success. The gate still decides; this only asks again.
"""
import argparse
from datetime import datetime
import importlib.util
import os
from pathlib import Path
import sys
import urllib.error

WORKFLOW_REF = "InnoSquadCorp/InnoNetwork/.github/workflows/ci-runner-retry.yml@refs/heads/main"
CI_PATH = ".github/workflows/ci.yml"
RUNNER_LOST = "was not acquired by Runner"
# Jobs that only judge other jobs' results; they fail whenever a lane is lost.
AGGREGATES = {"CI Required", "Consumer Smoke"}
PASSED = {"success", "skipped", "neutral"}
# The third attempt is the last. A validation that still finds no runner then is
# an outage, not a blip, and a gate that still fails then needs a human.
MAX_ATTEMPT = 3


def policy_module():
    spec = importlib.util.spec_from_file_location("merge_policy", Path(__file__).with_name("dependabot-merge-policy.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


p = policy_module()
# Run titles and the gate's job and step names have one definition each.
metadata = p.sibling("ci_metadata_policy", "ci-metadata-policy.py")
verifier = p.sibling("verify_ci_metadata", "verify-ci-metadata.py")


def when(value):
    p.require(isinstance(value, str), "missing job time")
    moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    p.require(moment.tzinfo is not None, "job time without a zone")
    return moment


def attempt_of(run):
    attempt = run.get("run_attempt")
    p.require(type(attempt) is int and attempt > 0, "invalid run attempt")
    return attempt


def lost(api, job):
    """A job cancelled before any runner took it, as GitHub annotates it."""
    if job.get("conclusion") != "cancelled" or job.get("steps") or job.get("runner_name"):
        return False
    notes = api.get(p.route(f"check-runs/{job['id']}/annotations"))
    p.require(isinstance(notes, list), "malformed check run annotations")
    return any(RUNNER_LOST in (note.get("message") or "") for note in notes)


def lost_runners(api, run):
    """A failed run is rerun only when nothing but lost runners failed it."""
    attempt = attempt_of(run)
    if attempt >= MAX_ATTEMPT:
        return None, f"attempt {attempt} still failed; leaving the runner outage to a human"
    jobs = api.pages(p.route(f"actions/runs/{run['id']}/attempts/{attempt}/jobs"), "jobs")
    failed = [job for job in jobs if job.get("conclusion") not in PASSED]
    runnerless = [job for job in failed if lost(api, job)]
    real = [job["name"] for job in failed if job not in runnerless and job.get("name") not in AGGREGATES]
    if real:
        return None, "real failures, not retried: " + ", ".join(sorted(real))
    if not runnerless:
        return None, "no job lost its runner"
    return run["id"], "rerun after lost runners: " + ", ".join(sorted(job["name"] for job in runnerless))


def gate_of(listed, number, head):
    """Whether a run's title binds a metadata gate to this PR and head."""
    bound = metadata.TITLE.fullmatch(str(listed.get("display_title", "")))
    return bound is not None and int(bound[1]) == number and bound[2] == head


def moved(run, number, head):
    """GitHub lists a run's open PR at its current head; another head there leaves this one behind."""
    return any(isinstance(pr, dict) and pr.get("number") == number and
               isinstance((pr.get("head") or {}).get("sha"), str) and pr["head"]["sha"] != head
               for pr in run.get("pull_requests") or [])


def stale_gate(api, run):
    """A successful validation reruns the newest metadata gate that judged too early."""
    # A metadata run's own title never matches, so its success ends here too.
    bound = verifier.TITLE.fullmatch(str(run.get("display_title", "")))
    if bound is None or bound[2] != run.get("head_sha") or verifier.belongs_to_other_pr(run, int(bound[1])):
        return None, "not a bound PR validation; no metadata gate depends on it"
    number, head = int(bound[1]), bound[2]
    # A gate of an older head can only fail again. A fork PR has no such listing
    # and stays eligible: the gate itself rejects a head that moved.
    if moved(run, number, head):
        return None, "the pull request moved to another head"
    runs = api.pages(p.route(f"actions/workflows/ci.yml/runs?head_sha={head}"), "workflow_runs")
    p.require(all(type(r.get("run_number")) is int and r["run_number"] > 0 for r in [run, *runs]),
              "invalid CI run ordering")
    # GitHub may judge a required name by its newest check suite, and the gate
    # reads the newest validation. An older gate, or one a newer validation
    # replaced, blocks nothing; rerunning it would only add a fresh failed check.
    newer = [r for r in runs if r["run_number"] > run["run_number"]]
    if any(not str(r.get("display_title", "")).startswith(metadata.PREFIX) and
           not verifier.belongs_to_other_pr(r, number) for r in newer):
        return None, "a newer validation of this head decides"
    gates = [r for r in newer if gate_of(r, number, head)]
    if not gates:
        return None, "no metadata gate ran after this validation"
    listed = max(gates, key=lambda r: r["run_number"])
    if listed.get("status") != "completed":
        return None, "the newest metadata gate has not finished; it judges this validation itself"
    if listed.get("conclusion") != "failure":
        return None, "the newest metadata gate did not fail"
    gate = api.get(p.route(f"actions/runs/{listed['id']}"))
    p.require(gate.get("id") == listed["id"] and gate.get("path", "").split("@")[0] == CI_PATH and
              gate.get("repository", {}).get("full_name") == p.REPOSITORY and
              gate.get("event") == "pull_request" and gate.get("head_sha") == head and gate_of(gate, number, head),
              "metadata gate is not bound to this validation")
    if gate.get("status") != "completed" or gate.get("conclusion") != "failure":
        return None, "the newest metadata gate is no longer failed"
    attempt = attempt_of(gate)
    if attempt >= MAX_ATTEMPT:
        return None, f"metadata gate attempt {attempt} still failed; leaving it to a human"
    # Rerun nothing but the gate job: every validation job of a metadata run is
    # skipped, and its real aggregate step never runs.
    jobs = api.pages(p.route(f"actions/runs/{gate['id']}/attempts/{attempt}/jobs"), "jobs")
    judged = [job for job in jobs if job.get("name") in metadata.GATES]
    if (len(judged) != 1 or judged[0].get("conclusion") != "failure" or
            any(job.get("conclusion") != "skipped" or job.get("steps")
                for job in jobs if job.get("name") not in metadata.GATES) or
            any(step.get("name") == metadata.GATES[judged[0]["name"]] and step.get("conclusion") not in ("skipped", None)
                for step in judged[0].get("steps") or [])):
        return None, "the newest metadata run is not a failed gate alone"
    finished = [when(job["completed_at"])
                for job in api.pages(p.route(f"actions/runs/{run['id']}/attempts/{attempt_of(run)}/jobs"), "jobs")
                if job.get("completed_at")]
    p.require(bool(finished), "successful validation has no finished job")
    # A gate that started after the validation succeeded has judged that success.
    # Its failure has another cause, so each success asks a gate at most once.
    if when(judged[0].get("started_at")) >= max(finished):
        return None, "the newest metadata gate already judged this successful validation"
    return gate["id"], f"rerun metadata gate {gate['id']}: it failed before validation {run['id']} succeeded"


def plan(api, run_id):
    """Return (ID of the run to rerun or None, reason)."""
    run = api.get(p.route(f"actions/runs/{run_id}"))
    p.require(run.get("id") == run_id and run.get("path", "").split("@")[0] == CI_PATH and
              run.get("repository", {}).get("full_name") == p.REPOSITORY,
              "not a CI run of this repository")
    if run.get("event") != "pull_request" or run.get("status") != "completed":
        return None, "only a completed pull_request CI run is handled"
    if run.get("conclusion") == "failure":
        return lost_runners(api, run)
    if run.get("conclusion") == "success":
        return stale_gate(api, run)
    return None, "only a failed or successful pull_request CI run is handled"


def run(api, run_id):
    target, reason = plan(api, run_id)
    if target is None:
        return reason
    # No retry: an unknown outcome shows up as a new attempt or not at all.
    api.mutate("POST", p.route(f"actions/runs/{target}/rerun-failed-jobs"), {})
    return reason


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "run"))
    args = parser.parse_args()
    try:
        p.require(os.environ.get("GITHUB_REPOSITORY") == p.REPOSITORY and
                  os.environ.get("GITHUB_WORKFLOW_REF") == WORKFLOW_REF,
                  "runner retries require the trusted default-main workflow")
        run_id = int(os.environ["RUN_ID"])
        api = p.GitHub()
        if args.command == "plan":
            print(plan(api, run_id)[1])
        else:
            print(run(api, run_id))
    except (p.Rejected, KeyError, TypeError, ValueError, OSError, urllib.error.URLError) as error:
        print("CI runner retry rejected: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
