#!/usr/bin/env python3
"""Rerun a failed PR CI run whose only real failures never got a runner (stdlib only).

GitHub-hosted macOS capacity sometimes never assigns a runner. The job is then
cancelled with "not acquired by Runner", the aggregate gates fail, and the PR
stays red although none of its code ran. Nothing else retries such a run: the
Dependabot rebase queue skips a current-base PR whose CI failed, and a human PR
waits for someone to notice. This reruns the failed jobs only when every failure
is a lost runner or a gate that merely aggregates other jobs, so a real failure
is never retried, and stops after a few attempts so an outage is left to a human.
"""
import argparse
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
# A third attempt that still finds no runner is an outage, not a blip.
MAX_ATTEMPT = 3


def policy_module():
    spec = importlib.util.spec_from_file_location("merge_policy", Path(__file__).with_name("dependabot-merge-policy.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


p = policy_module()


def lost(api, job):
    """A job cancelled before any runner took it, as GitHub annotates it."""
    if job.get("conclusion") != "cancelled" or job.get("steps") or job.get("runner_name"):
        return False
    notes = api.get(p.route(f"check-runs/{job['id']}/annotations"))
    p.require(isinstance(notes, list), "malformed check run annotations")
    return any(RUNNER_LOST in (note.get("message") or "") for note in notes)


def plan(api, run_id):
    """Return (run or None, reason)."""
    run = api.get(p.route(f"actions/runs/{run_id}"))
    p.require(run.get("id") == run_id and run.get("path", "").split("@")[0] == CI_PATH and
              run.get("repository", {}).get("full_name") == p.REPOSITORY,
              "not a CI run of this repository")
    if run.get("event") != "pull_request" or run.get("status") != "completed" or run.get("conclusion") != "failure":
        return None, "only a failed pull_request CI run can be retried"
    attempt = run.get("run_attempt")
    p.require(type(attempt) is int and attempt > 0, "invalid run attempt")
    if attempt >= MAX_ATTEMPT:
        return None, f"attempt {attempt} still failed; leaving the runner outage to a human"
    jobs = api.pages(p.route(f"actions/runs/{run_id}/attempts/{attempt}/jobs"), "jobs")
    failed = [job for job in jobs if job.get("conclusion") not in PASSED]
    runnerless = [job for job in failed if lost(api, job)]
    real = [job["name"] for job in failed if job not in runnerless and job.get("name") not in AGGREGATES]
    if real:
        return None, "real failures, not retried: " + ", ".join(sorted(real))
    if not runnerless:
        return None, "no job lost its runner"
    return run, "rerun after lost runners: " + ", ".join(sorted(job["name"] for job in runnerless))


def run(api, run_id):
    target, reason = plan(api, run_id)
    if target is None:
        return reason
    # No retry: an unknown outcome shows up as a new attempt or not at all.
    api.mutate("POST", p.route(f"actions/runs/{run_id}/rerun-failed-jobs"), {})
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
