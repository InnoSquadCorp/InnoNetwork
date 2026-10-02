#!/usr/bin/env python3
"""Publish inert Pages artifacts after API-only origin and current-main checks.

Executed only from the default-branch workflow revision. Never downloads source
or artifact contents, and never changes repository/Pages settings. A release tag
must still point at current main: the single site must not roll back to old docs.
"""
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.request

REPOSITORY = "InnoSquadCorp/InnoNetwork"
APP = 15368  # GitHub Actions, not an arbitrary check with the same display name.
BOT = {"login": "dependabot[bot]", "id": 49699333, "type": "Bot"}
SHA = re.compile(r"[0-9a-f]{40}")
TAG = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
RECOVERY = re.compile(r"CI / Dependabot merge #([1-9][0-9]*)")
WORKFLOWS = {"CI": ".github/workflows/ci.yml"}


class Rejected(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise Rejected(reason)


def route(suffix=""):
    return f"repos/{REPOSITORY}" + ("/" + suffix if suffix else "")


def positive(value):
    return type(value) is int and value > 0


class GitHub:
    def __init__(self):
        self.token = os.environ.get("GH_TOKEN")
        require(bool(self.token), "missing job token")

    def request(self, method, path, payload=None):
        require(path == route() or path.startswith(route() + "/"), "foreign API target")
        request = urllib.request.Request("https://api.github.com/" + path,
            data=None if payload is None else json.dumps(payload).encode(), method=method,
            headers={"Authorization": "Bearer " + self.token,
                     "Accept": "application/vnd.github+json", "Content-Type": "application/json",
                     "X-GitHub-Api-Version": "2022-11-28"})
        # No mutation retries: an uncertain create must be investigated first.
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return (json.loads(raw) if raw else None), response.headers

    def get(self, path):
        return self.request("GET", path)[0]

    def pages(self, path, key):
        result, page = [], 1
        while True:
            separator = "&" if "?" in path else "?"
            data, headers = self.request("GET", f"{path}{separator}per_page=100&page={page}")
            require(isinstance(data, dict) and isinstance(data.get(key), list), "malformed paginated API result")
            result.extend(data[key])
            # Follow pagination by page number, never an API-returned foreign URL.
            if 'rel="next"' not in headers.get("Link", ""):
                if "total_count" in data:
                    require(type(data["total_count"]) is int and len(result) == data["total_count"], "truncated API pages")
                return result
            page += 1
            require(page <= 1000, "excessive pagination")

    def mutate(self, path, payload):
        return self.request("POST", path, payload)[0]

    def id_token(self):
        url = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL", "")
        token = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")
        require(url.startswith("https://") and bool(token), "missing OIDC request context")
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(request, timeout=30) as response:
            value = json.load(response)["value"]
        require(isinstance(value, str) and value and "\n" not in value, "invalid OIDC token")
        print("::add-mask::" + value)
        return value


def environment(env):
    require(env.get("GITHUB_REPOSITORY") == REPOSITORY and env.get("GITHUB_EVENT_NAME") == "workflow_run" and
            env.get("GITHUB_REF") == "refs/heads/main" and
            env.get("GITHUB_WORKFLOW_REF") == f"{REPOSITORY}/.github/workflows/docs-publish.yml@refs/heads/main" and
            SHA.fullmatch(env.get("GITHUB_WORKFLOW_SHA", "")), "publisher is not the trusted main workflow")


def same_repo(value, repository):
    return (value or {}).get("id") == repository["id"] and (value or {}).get("full_name") == REPOSITORY


def check_job(api, run, jobs, name, required_steps, allowed_skips=()):
    matching = [job for job in jobs if job.get("name") == name]
    require(len(matching) == 1, "missing or duplicate source job: " + name)
    job = matching[0]
    require(positive(job.get("id")) and job.get("status") == "completed" and job.get("conclusion") == "success",
            "source job did not succeed: " + name)
    check_url = re.fullmatch(rf"https://api\.github\.com/repos/{re.escape(REPOSITORY)}/check-runs/([1-9][0-9]*)",
                             job.get("check_run_url", ""))
    require(check_url is not None, "invalid source job/check connection: " + name)
    check = api.get(route("check-runs/" + check_url.group(1)))
    require(check.get("id") == int(check_url.group(1)) and check.get("name") == name and
            check.get("app", {}).get("id") == APP and check.get("check_suite", {}).get("id") == run["check_suite_id"] and
            check.get("head_sha") == run["head_sha"] and check.get("status") == "completed" and
            check.get("conclusion") == "success" and
            check.get("details_url") == f"https://github.com/{REPOSITORY}/actions/runs/{run['id']}/job/{job['id']}",
            "wrong source app/suite/job/head proof: " + name)
    steps = job.get("steps", [])
    names = [step.get("name") for step in steps]
    require(len(names) == len(set(names)) and set(required_steps) <= set(names), "missing or duplicate proof step: " + name)
    for step in steps:
        require(step.get("status") == "completed" and
                (step.get("conclusion") == "success" or
                 (step.get("conclusion") == "skipped" and step.get("name") in allowed_skips)),
                "failed or unexpected skipped source step: " + name)


def verify_recovery(api, run, repository):
    marker = RECOVERY.fullmatch(run.get("display_title", ""))
    require(marker is not None, "unverified main CI dispatch marker")
    pr = api.get(route("pulls/" + marker.group(1)))
    require(pr.get("number") == int(marker.group(1)) and pr.get("state") == "closed" and pr.get("merged") is True and
            all(pr.get("user", {}).get(key) == value for key, value in BOT.items()) and
            pr.get("merge_commit_sha") == run["head_sha"] and pr.get("base", {}).get("ref") == "main" and
            same_repo(pr.get("base", {}).get("repo"), repository) and same_repo(pr.get("head", {}).get("repo"), repository),
            "dispatch is not the actual same-repository Dependabot merge")


def verify_ref(api, run):
    branch = run["head_branch"]
    if branch != "main":
        require(run["name"] == "Documentation" and TAG.fullmatch(branch), "unsupported documentation ref")
        target = api.get(route("git/ref/tags/" + branch))["object"]
        # Both lightweight and annotated release tags are supported; no tag code runs here.
        for _ in range(8):
            require(SHA.fullmatch(target.get("sha", "")), "invalid tag object")
            if target.get("type") == "commit":
                break
            require(target.get("type") == "tag", "unsupported tag object")
            target = api.get(route("git/tags/" + target["sha"]))["object"]
        require(target.get("type") == "commit" and target.get("sha") == run["head_sha"], "tag moved or did not resolve to source SHA")
    current = api.get(route("git/ref/heads/main"))["object"]
    require(current.get("type") == "commit" and current.get("sha") == run["head_sha"], "refusing stale documentation: source is not current main")


def proof(api, event):
    repository = api.get(route())
    require(repository.get("full_name") == REPOSITORY and repository.get("default_branch") == "main" and
            positive(repository.get("id")) and same_repo(event.get("repository"), repository), "wrong repository/default branch")
    notice = event.get("workflow_run", {})
    require(positive(notice.get("id")) and positive(notice.get("run_attempt")), "invalid source run/attempt")
    run = api.get(route(f"actions/runs/{notice['id']}"))
    identity = ("id", "run_attempt", "workflow_id", "path", "name", "head_sha", "head_branch", "event", "check_suite_id")
    require(all(run.get(key) == notice.get(key) for key in identity), "source notification is stale or forged")
    require(run.get("status") == "completed" and run.get("conclusion") == "success" and
            notice.get("status") == "completed" and notice.get("conclusion") == "success" and
            same_repo(run.get("repository"), repository) and same_repo(run.get("head_repository"), repository) and
            same_repo(notice.get("repository"), repository) and same_repo(notice.get("head_repository"), repository) and
            SHA.fullmatch(run.get("head_sha", "")) and positive(run.get("check_suite_id")), "unsuccessful or foreign source run")
    name = run.get("name")
    require(name in WORKFLOWS and run.get("path") == WORKFLOWS[name] and
            run.get("event") in {"push", "workflow_dispatch"}, "unsupported source workflow/event")
    workflow = api.get(route("actions/workflows/" + WORKFLOWS[name].rsplit("/", 1)[1]))
    require(workflow.get("id") == run.get("workflow_id") and workflow.get("path") == WORKFLOWS[name] and
            workflow.get("name") == name and workflow.get("state") == "active", "wrong source workflow identity")
    jobs = api.pages(route(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs"), "jobs")
    require(len({job.get("id") for job in jobs}) == len(jobs), "duplicate source jobs")
    if name == "CI":
        require(run.get("head_branch") == "main", "CI source is not main")
        plan_steps = ["Plan exact changed paths"]
        skips = ["Verify actual post-merge main origin"]
        if run["event"] == "workflow_dispatch":
            verify_recovery(api, run, repository)
            plan_steps.append("Verify actual post-merge main origin")
            skips = []
        check_job(api, run, jobs, "CI Plan", plan_steps, skips)
        check_job(api, run, jobs, "CI Required", ["Require every planned CI result"])
        docs_job = "Build DocC Site"
    else:
        require(run["event"] == "workflow_dispatch" or TAG.fullmatch(run.get("head_branch", "")),
                "standalone branch pushes must be built by CI")
        docs_job = "Build Documentation"
    check_job(api, run, jobs, docs_job, ["Checkout", "Build DocC archives", "Verify public DocC archives", "Transform DocC archives for static hosting", "Validate DocC site files", "Upload Documentation Artifact"])
    verify_ref(api, run)
    artifacts = api.pages(route(f"actions/runs/{run['id']}/artifacts"), "artifacts")
    artifact_name = f"github-pages-{run['id']}-{run['run_attempt']}-{run['head_sha']}"
    matches = [artifact for artifact in artifacts if artifact.get("name") == artifact_name]
    require(len(matches) == 1, "missing or duplicate exact-attempt Pages artifact")
    artifact = matches[0]
    origin = artifact.get("workflow_run", {})
    require(positive(artifact.get("id")) and artifact.get("expired") is False and positive(artifact.get("size_in_bytes")) and
            origin.get("id") == run["id"] and origin.get("repository_id") == repository["id"] and
            origin.get("head_repository_id") == repository["id"] and origin.get("head_branch") == run["head_branch"] and
            origin.get("head_sha") == run["head_sha"] and
            re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", "")), "unverified or incomplete Pages artifact")
    return {"run": run, "artifact": artifact}


def publish(api, event, sleep=time.sleep):
    verified = proof(api, event)
    run, artifact = verified["run"], verified["artifact"]
    page = api.get(route("pages"))
    require(page.get("build_type") == "workflow", "Pages must already use workflow publishing; no settings are changed")
    url = page.get("html_url", "")
    require(url.startswith("https://") and "\n" not in url and "\r" not in url, "invalid configured Pages URL")
    token = api.id_token()
    # Revalidate all origin/check/artifact evidence after waiting for the shared
    # Pages queue and obtaining OIDC. Never deploy a replaced attempt or moved ref.
    latest = proof(api, event)
    require(latest == verified, "source proof changed before publication")
    verify_ref(api, run)  # Final main/tag read immediately before the only create.
    deployment = api.mutate(route("pages/deployments"), {
        "artifact_id": artifact["id"], "pages_build_version": run["head_sha"],
        "oidc_token": token, "environment": "github-pages",
    })
    deployment_id = str(deployment.get("id", ""))
    require(re.fullmatch(r"[A-Za-z0-9_-]+", deployment_id), "invalid Pages deployment ID")
    deadline, errors = time.monotonic() + 600, 0
    for _ in range(120):
        if time.monotonic() >= deadline:
            break
        try:
            status = api.get(route("pages/deployments/" + deployment_id))
        except urllib.error.URLError:
            errors += 1
            if errors >= 10:
                api.mutate(route("pages/deployments/" + deployment_id + "/cancel"), {})
                raise Rejected("Pages status unavailable; cancellation requested") from None
            sleep(5)
            continue
        if status.get("status") == "succeed":
            return url
        # Known intermediate states are bounded waits, never success. The four
        # file-sync/Pages/CDN states are in GitHub's deployment-status schema;
        # deployment_queued was observed in a real deployment response.
        # Transient status failures never create a new deployment.
        state = status.get("status")
        require(not isinstance(state, str) or state not in {"deployment_failed", "deployment_content_failed", "deployment_cancelled", "deployment_lost"},
                "Pages deployment failed: " + str(state))
        if not isinstance(state, str) or state not in {
                "deployment_in_progress", "queued", "pending", "unknown_status", "not_found", "deployment_attempt_error",
                "syncing_files", "finished_file_sync", "updating_pages", "purging_cdn", "deployment_queued"}:
            # Preserve an escaped diagnostic even if the cancellation request
            # itself fails; an unknown value must not inject extra log lines.
            print("Unknown Pages status before cancellation: " + repr(state), file=sys.stderr)
            api.mutate(route("pages/deployments/" + deployment_id + "/cancel"), {})
            raise Rejected("Unknown Pages status; cancellation requested: " + repr(state))
        sleep(5)
    # Timeout does not create a second deployment. The known operation is stopped.
    api.mutate(route("pages/deployments/" + deployment_id + "/cancel"), {})
    raise Rejected("Pages deployment timed out and cancellation was requested")


def main():
    environment(os.environ)
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    url = publish(GitHub(), event)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write("page_url=" + url + "\n")
    print("Published verified current-main documentation: " + url)


if __name__ == "__main__":
    try:
        main()
    except (Rejected, KeyError, TypeError, ValueError, urllib.error.URLError) as error:
        # HTTPError string contains status, not the authenticated request headers.
        print("::error::Documentation publication rejected: " + str(error), file=sys.stderr)
        raise SystemExit(1)
