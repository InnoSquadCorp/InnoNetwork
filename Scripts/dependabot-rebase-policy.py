#!/usr/bin/env python3
"""Ask Dependabot to rebase one behind PR at a time onto current main (stdlib only).

The coordinator proves only a PR whose base is current main, so after any main
push every other Dependabot PR is blocked until it is rebased. Rebasing all of
them at once lets one merge and wastes full CI on the rest, so one PR is moved
at a time: wait while one is rebasing, validating or merging, then ask for the
oldest behind PR. Dependabot refuses commands from GITHUB_TOKEN and GitHub Apps,
so the command is posted with a push-capable user token, which is otherwise used
only to look up its owner. Planning reads use the read-only job token.
"""
import argparse
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request

WORKFLOW_REF = "InnoSquadCorp/InnoNetwork/.github/workflows/dependabot-rebase.yml@refs/heads/main"
COMMAND = "@dependabot rebase"
COMMANDS = ("@dependabot rebase", "@dependabot recreate")
# Dependabot honours commands only from users with push access, and anyone can
# comment on a public repository. Only a current write role holds the queue;
# association labels such as MEMBER do not imply it. Maintain maps to write.
PUSH = {"admin", "write"}
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


def moved_at(api, ref, sha):
    """When ref actually moved to sha, or None. A commit date can predate its push."""
    activities = api.get(p.route("activity?ref=" + urllib.parse.quote(ref, safe="/") + "&per_page=100"))
    p.require(isinstance(activities, list), "malformed repository activity")
    return next((when(a["timestamp"]) for a in activities if a.get("after") == sha), None)


def can_push(api, login, cache):
    if not login:
        return False
    if login not in cache:
        try:
            role = api.get(p.route("collaborators/" + urllib.parse.quote(login, safe="") + "/permission"))
            cache[login] = role.get("permission") in PUSH
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            error.close()
            cache[login] = False
    return cache[login]


def rebase_request(api, number, since, writers):
    """Return (time, refused) of the latest push-capable command since main moved."""
    asked, refused = None, False
    for comment in api.pages(p.route(f"issues/{number}/comments")):
        created = when(comment["created_at"])
        body = (comment.get("body") or "").strip()
        if created < since:
            continue
        if body.startswith(COMMANDS) and can_push(api, comment.get("user", {}).get("login", ""), writers):
            asked, refused = created, False
        elif asked is not None and p.bot(comment) and REFUSAL in body:
            refused = True
    return asked, refused


def validation_state(api, number, head, base, head_ref, now):
    """Describe why a current-base PR still holds the queue, or None."""
    prefix = f"CI validation v2 pr:{number} head:{head} base:{base} "
    runs = [r for r in api.pages(p.route(f"actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}"),
                                 "workflow_runs")
            if r.get("display_title", "").startswith(prefix)]
    if not runs:
        # An unknown or old push must not hold the queue.
        pushed = moved_at(api, "refs/heads/" + head_ref, head)
        return "waiting for CI to start" if pushed is not None and now - pushed < START_GRACE else None
    latest = max(runs, key=lambda r: r["run_number"])
    if latest.get("status") != "completed":
        return "CI running"
    if latest.get("conclusion") == "success" and now - when(latest["updated_at"]) < MERGE_GRACE:
        return "waiting for auto-merge"
    return None


def plan(api, now):
    """Return (PR number or None, main SHA, reason)."""
    main_sha = api.get(p.route("commits/main"))["sha"]
    p.require(bool(p.SHA.fullmatch(main_sha)), "invalid main SHA")
    # Commands and refusals before main moved here belong to an older main.
    since = moved_at(api, "refs/heads/main", main_sha)
    p.require(since is not None, "no main move record for " + main_sha)
    waiting, candidates, writers = [], [], {}
    for pr in sorted(api.pages(p.route("pulls?state=open&base=main")), key=lambda x: x["number"]):
        head_repo = pr.get("head", {}).get("repo") or {}
        if not p.bot(pr) or pr.get("draft") is not False or head_repo.get("full_name") != p.REPOSITORY:
            continue
        number, head, base = pr["number"], pr["head"]["sha"], pr["base"]["sha"]
        if base == main_sha:
            state = validation_state(api, number, head, base, pr["head"]["ref"], now)
            if state:
                waiting.append(f"#{number} {state}")
            continue
        asked, refused = rebase_request(api, number, since, writers)
        if refused:
            print(f"::warning::Dependabot refused the rebase command on #{number}; skipping it for this main")
        elif asked is None:
            candidates.append(number)
        elif now - asked < REQUEST_TTL:
            waiting.append(f"#{number} rebase requested")
    if waiting:
        return None, main_sha, "waiting: " + ", ".join(waiting)
    if not candidates:
        return None, main_sha, "no behind Dependabot PR needs a rebase"
    return candidates[0], main_sha, f"#{candidates[0]} is the oldest behind Dependabot PR"


def token_login(token):
    # The shared helper only reaches repository routes; the owner lookup is fixed.
    request = urllib.request.Request("https://api.github.com/user", headers={
        "Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(request, timeout=30) as response:
        login = json.loads(response.read()).get("login")
    p.require(isinstance(login, str) and bool(login), "command token has no user login")
    return login


def run(api, command_api, command_login, enabled, now):
    """command_login is called only when a command would be posted."""
    if not enabled:
        return "standby: DEPENDABOT_AUTO_MERGE_ENABLED is not true"
    number, main_sha, reason = plan(api, now)
    if number is None:
        return reason
    if command_api is None:
        return reason + "; DEPENDABOT_COMMAND_TOKEN is not configured, no rebase requested"
    # A refused command would not count as a request, so every wake would post
    # it again. Check the owner's write role before the first comment.
    login = command_login()
    if not can_push(api, login, {}):
        print(f"::warning::DEPENDABOT_COMMAND_TOKEN belongs to {login}, who lacks write access")
        return reason + "; the command token owner lacks write access, no rebase requested"
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
        print(run(api, command_api, lambda: token_login(token),
                  os.environ.get("DEPENDABOT_AUTO_MERGE_ENABLED") == "true", now))
    except (p.Rejected, KeyError, TypeError, ValueError, OSError, urllib.error.URLError) as error:
        print("Dependabot rebase rejected: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
