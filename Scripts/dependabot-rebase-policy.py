#!/usr/bin/env python3
"""Ask Dependabot to rebase one behind PR at a time onto current main (stdlib only).

The coordinator proves only a PR whose base is current main, so after any main
push every other Dependabot PR is blocked until it is rebased. Rebasing all of
them at once lets one merge and wastes full CI on the rest, so one PR is moved
at a time: wait while one is rebasing, validating or merging, then ask for the
oldest behind PR. Dependabot refuses commands from GITHUB_TOKEN and GitHub Apps,
so the command alone is posted with a push-capable user token. Planning reads
use the read-only job token.
"""
import argparse
from datetime import datetime, timedelta, timezone
import importlib.util
import os
from pathlib import Path
import sys
import urllib.error

WORKFLOW_REF = "InnoSquadCorp/InnoNetwork/.github/workflows/dependabot-rebase.yml@refs/heads/main"
COMMAND = "@dependabot rebase"
COMMANDS = ("@dependabot rebase", "@dependabot recreate")
# Dependabot honours commands only from users with push access. Anyone can
# comment on a public repository, so other authors never hold the queue.
TRUSTED = {"OWNER", "MEMBER", "COLLABORATOR"}
REFUSAL = "only users with push access"
# Dependabot answers within minutes; silence means the command was ignored.
REQUEST_TTL = timedelta(hours=1)
# A rebased head gets its CI run within minutes.
START_GRACE = timedelta(minutes=30)
# Native auto-merge follows a green validation within minutes.
MERGE_GRACE = timedelta(hours=1)


def policy_module():
    spec = importlib.util.spec_from_file_location("merge_policy", Path(__file__).with_name("dependabot-merge-policy.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


p = policy_module()


def when(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def rebase_request(api, number, since):
    """Return (time, refused) of the latest trusted command since main moved."""
    asked, refused = None, False
    for comment in api.pages(p.route(f"issues/{number}/comments")):
        created = when(comment["created_at"])
        body = (comment.get("body") or "").strip()
        if created < since:
            continue
        if comment.get("author_association") in TRUSTED and body.startswith(COMMANDS):
            asked, refused = created, False
        elif asked is not None and p.bot(comment) and REFUSAL in body:
            refused = True
    return asked, refused


def validation_state(api, number, head, base, now):
    """Describe why a current-base PR still holds the queue, or None."""
    prefix = f"CI validation v2 pr:{number} head:{head} base:{base} "
    runs = [r for r in api.pages(p.route(f"actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}"),
                                 "workflow_runs")
            if r.get("display_title", "").startswith(prefix)]
    if not runs:
        pushed = when(api.get(p.route(f"commits/{head}"))["commit"]["committer"]["date"])
        return "waiting for CI to start" if now - pushed < START_GRACE else None
    latest = max(runs, key=lambda r: r["run_number"])
    if latest.get("status") != "completed":
        return "CI running"
    if latest.get("conclusion") == "success" and now - when(latest["updated_at"]) < MERGE_GRACE:
        return "waiting for auto-merge"
    return None


def plan(api, now):
    """Return (PR number or None, main SHA, reason)."""
    main = api.get(p.route("commits/main"))
    main_sha = main["sha"]
    p.require(bool(p.SHA.fullmatch(main_sha)), "invalid main SHA")
    since = when(main["commit"]["committer"]["date"])
    waiting, candidates = [], []
    for pr in sorted(api.pages(p.route("pulls?state=open&base=main")), key=lambda x: x["number"]):
        head_repo = pr.get("head", {}).get("repo") or {}
        if not p.bot(pr) or pr.get("draft") is not False or head_repo.get("full_name") != p.REPOSITORY:
            continue
        number, head, base = pr["number"], pr["head"]["sha"], pr["base"]["sha"]
        if base == main_sha:
            state = validation_state(api, number, head, base, now)
            if state:
                waiting.append(f"#{number} {state}")
            continue
        asked, refused = rebase_request(api, number, since)
        if refused:
            print(f"::warning::Dependabot refused the rebase command on #{number}; "
                  "DEPENDABOT_COMMAND_TOKEN needs a user with push access")
        elif asked is None:
            candidates.append(number)
        elif now - asked < REQUEST_TTL:
            waiting.append(f"#{number} rebase requested")
    if waiting:
        return None, main_sha, "waiting: " + ", ".join(waiting)
    if not candidates:
        return None, main_sha, "no behind Dependabot PR needs a rebase"
    return candidates[0], main_sha, f"#{candidates[0]} is the oldest behind Dependabot PR"


def run(api, command_api, enabled, now):
    if not enabled:
        return "standby: DEPENDABOT_AUTO_MERGE_ENABLED is not true"
    number, main_sha, reason = plan(api, now)
    if number is None:
        return reason
    if command_api is None:
        return reason + "; DEPENDABOT_COMMAND_TOKEN is not configured, no rebase requested"
    # No retry: an unknown outcome is read back by the next wake as a request.
    command_api.mutate("POST", p.route(f"issues/{number}/comments"), {"body": COMMAND})
    return f"requested Dependabot rebase of #{number} onto {main_sha}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "run"))
    args = parser.parse_args()
    try:
        p.require(os.environ.get("GITHUB_REPOSITORY") == p.REPOSITORY and
                  os.environ.get("GITHUB_REF") == "refs/heads/main" and
                  os.environ.get("GITHUB_WORKFLOW_REF") == WORKFLOW_REF,
                  "rebase requests require the trusted default-main workflow/ref")
        api = p.GitHub()
        now = datetime.now(timezone.utc)
        if args.command == "plan":
            print(plan(api, now)[2])
            return 0
        token = os.environ.get("DEPENDABOT_COMMAND_TOKEN", "")
        command_api = p.GitHub(token) if token else None
        print(run(api, command_api, os.environ.get("DEPENDABOT_AUTO_MERGE_ENABLED") == "true", now))
    except (p.Rejected, KeyError, TypeError, ValueError, OSError, urllib.error.URLError) as error:
        print("Dependabot rebase rejected: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
