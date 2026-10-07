#!/usr/bin/env python3
"""Plan InnoNetwork CI from exact Git changes and reject incomplete results (stdlib only)."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

JOBS = ('policy', 'dependency-review', 'lint', 'dead-code', 'build-and-test', 'upload-core-coverage', 'parallel-tests', 'docs-contract-sync', 'apple-platform-build-smoke', 'consumer-smoke', 'consumer-examples', 'consumer-macros', 'consumer-openapi', 'upload-macro-coverage', 'benchmark-smoke', 'codeql', 'thread-sanitizer', 'benchmarks', 'documentation', 'release-candidate')
SHA = re.compile(r"[0-9a-f]{40}")
PR_ACTIONS = {"opened", "synchronize", "reopened", "edited", "labeled", "unlabeled"}
DEPENDENCIES = {
    "upload-core-coverage": {"build-and-test"},
    "upload-macro-coverage": {"consumer-macros"},
    "consumer-smoke": {"consumer-examples", "consumer-macros", "consumer-openapi"},
}
WORKFLOW_IMPACT = {
    "ci.yml": set(JOBS), "release.yml": set(JOBS), "release-validation.yml": set(JOBS),
    "codeql.yml": {"codeql"}, "tsan.yml": {"thread-sanitizer"},
    "benchmarks.yml": {"benchmarks", "benchmark-smoke"},
    "docc-pages.yml": {"documentation", "docs-contract-sync"},
    "docs-publish.yml": {"documentation", "docs-contract-sync"},
    "dependency-submission.yml": {"dependency-review", "build-and-test"},
    "pr-dependency-submission.yml": {"dependency-review", "build-and-test"},
    "scorecard.yml": set(), "nightly-live.yml": set(JOBS),
    "dependabot-auto-merge.yml": set(), "dependabot-review-notice.yml": set(),
    "dependabot-ready.yml": set(),
}


def reuse_policy():
    spec = importlib.util.spec_from_file_location("main_ci_reuse_policy", Path(__file__).with_name("main-ci-reuse-policy.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def reused_jobs(plan, proof):
    reuse = reuse_policy()
    reuse.validate_proof(proof)
    if not proof:
        return set()
    if plan["event"] != "push" or plan["lane"] != "full" or plan["jobs"] != {job: job != "dependency-review" for job in JOBS}:
        raise ValueError("reuse must preserve every full logical requirement")
    return set(reuse.REUSED_JOBS)



def prose_module():
    spec = importlib.util.spec_from_file_location("ci_prose", Path(__file__).with_name("ci_prose.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def apply_prose(plan, root, event, paths):
    if plan["lane"] != "fast" or plan.get("requested"):
        return plan
    pr = event.get("pull_request", {})
    proof = prose_module().inspect(root, pr.get("base", {}).get("sha"), pr.get("head", {}).get("sha"), paths)
    if not proof:
        if paths and all(prose_module().candidate(path) for path in paths):
            # Code fences, file modes, missing blobs, and deletions are not prose evidence.
            return make_plan("pull_request", event, paths + ["__unproven_documentation_full_fallback__"])
        return plan
    plan["prose_only"] = proof
    plan["jobs"] = {job: job == "policy" for job in JOBS}
    if "examples_full" in plan:
        plan["examples_full"] = False
    return plan


def path_impact(path):
    if not isinstance(path, str) or not path or any(ord(c) < 32 or ord(c) == 127 for c in path):
        raise ValueError("invalid changed path")
    if path.startswith("/") or any(p in ("..", ".", "") for p in path.split("/")) or "\\" in path:
        raise ValueError("changed path must be a repository-relative POSIX path")
    if prose_module().RELEASE.search(path):
        return set(JOBS), "release metadata (full fallback)"
    # Source/test/example changes preserve all former gates, even nested docs.
    if path.startswith(("Sources/", "Tests/", "Examples/", "SmokeTests/", "Benchmarks/", "Tools/openapi-to-innonetwork/")):
        return set(JOBS), "source/test/example/performance (all Network gates)"
    if path in ("Package.swift", "Package.resolved", ".swift-format", ".periphery.yml", ".periphery-baseline.json", "codecov.yml") or path.startswith((".github/actions/", "Scripts/")):
        return set(JOBS), "shared package/toolchain/verification contract"
    if path.startswith(".github/workflows/"):
        name = path.removeprefix(".github/workflows/")
        return set(WORKFLOW_IMPACT.get(name, JOBS)), "workflow:" + name
    if path.startswith("docs/") and not path.endswith((".md", ".png", ".jpg", ".svg", ".html")):
        return set(JOBS), "shared documentation/verification inventory"
    if path == ".spi.yml" or path.endswith(".md") or path.startswith("docs/site/"):
        return {"documentation", "docs-contract-sync"}, "documentation"
    if path.startswith(".github/ISSUE_TEMPLATE/") or path in (".github/dependabot.yml", ".github/release.yml", "LICENSE"):
        return set(), "public operations"
    return set(JOBS), "unknown/shared path (full fallback)"


def with_dependencies(selected):
    selected = set(selected) | {"policy"}
    while True:
        expanded = selected | set().union(*(DEPENDENCIES.get(job, set()) for job in selected))
        if expanded == selected:
            return selected
        selected = expanded


def changed_paths(root, base, head):
    if not SHA.fullmatch(base or "") or not SHA.fullmatch(head or ""):
        raise ValueError("diff anchors must be exact lowercase commit SHAs")
    raw = subprocess.check_output([
        "git", "-C", str(root), "diff", "--name-status", "-z", "--find-renames", base + "..." + head,
    ])
    if not raw:
        return []
    tokens = raw.decode("utf-8", errors="strict").split("\x00")
    if tokens.pop() != "":
        raise ValueError("truncated Git changed-file stream")
    paths = []
    index = 0
    while index < len(tokens):
        status = tokens[index]
        index += 1
        if not re.fullmatch(r"(?:[ADMT]|[RC][0-9]{1,3})", status):
            raise ValueError("unknown or unresolved Git file status")
        if status[0] in "RC" and int(status[1:]) > 100:
            raise ValueError("invalid Git similarity score")
        if status[0] in "DRCT":
            paths.append("__full_change_fallback__")
        count = 2 if status[0] in "RC" else 1
        if len(tokens) - index < count:
            raise ValueError("missing changed-file path")
        # Both sides of a rename/copy and deleted files remain relevant even
        # when the old name no longer exists in the checkout.
        for path in tokens[index:index + count]:
            path_impact(path)
            paths.append(path)
        index += count
    return paths


def make_plan(event_name, event, paths):
    if not isinstance(event, dict) or not isinstance(paths, list):
        raise ValueError("event and changed paths have invalid types")
    lane = "full"
    requested = []
    if event_name == "pull_request":
        pr = event.get("pull_request")
        if event.get("action") not in PR_ACTIONS or not isinstance(pr, dict):
            raise ValueError("unsupported PR event")
        labels = pr.get("labels")
        user = pr.get("user")
        if not isinstance(labels, list) or any(not isinstance(x, dict) or not isinstance(x.get("name"), str) for x in labels):
            raise ValueError("missing or malformed PR labels")
        if not isinstance(user, dict) or not isinstance(user.get("login"), str) or not user["login"]:
            raise ValueError("missing or malformed PR author")
        if event["action"] == "edited" and not event.get("changes", {}).get("base"):
            raise ValueError("metadata-only edit must not create a validation plan")
        names = {label["name"].lower() for label in labels}
        lane = "release-validation" if user["login"] == "dependabot[bot]" or "release-validation" in names else "fast"
        if "concurrency-review" in names:
            requested = ["thread-sanitizer"]
    elif event_name == "push":
        repository = event.get("repository", {})
        if not isinstance(repository, dict):
            raise ValueError("malformed repository metadata")
        default = repository.get("default_branch", "main")
        if not isinstance(default, str) or not default:
            raise ValueError("malformed default branch")
        if event.get("ref") not in {"refs/heads/main", "refs/heads/" + default}:
            raise ValueError("CI push must target main/default branch")
    elif event_name == "merge_group":
        if event.get("action") != "checks_requested":
            raise ValueError("unsupported merge queue event")
    elif event_name != "workflow_dispatch":
        raise ValueError("unsupported CI event")
    selected = set(requested)
    changes = []
    for path in paths:
        impact, reason = path_impact(path)
        selected.update(impact)
        changes.append({"path": path, "reason": reason})
    selected = with_dependencies(selected)
    # Empty or unavailable evidence cannot justify skipping a validation gate.
    if lane != "fast" or not paths:
        selected = set(JOBS)
    if event_name != "pull_request":
        selected.discard("dependency-review")
    return {"schema": 1, "lane": lane, "event": event_name, "requested": requested,
            "jobs": {job: job in selected for job in JOBS}, "changes": changes}


def validate_plan(plan):
    if not isinstance(plan, dict) or (set(plan) - {"prose_only"}) != {"schema", "lane", "event", "requested", "jobs", "changes"}:
        raise ValueError("missing or unknown plan fields")
    prose = plan.get("prose_only")
    if "prose_only" in plan:
        if not isinstance(plan.get("changes"), list):
            raise ValueError("invalid prose changes")
        prose_module().validate(prose, [change.get("path") for change in plan["changes"] if isinstance(change, dict)])
        if plan.get("lane") != "fast" or plan.get("requested") or plan.get("jobs") != {job: job == "policy" for job in JOBS}:
            raise ValueError("prose-only lane must require exactly static policy")
    if type(plan["schema"]) is not int or plan["schema"] != 1 or plan["lane"] not in ("fast", "full", "release-validation"):
        raise ValueError("unsupported plan schema/lane")
    if not isinstance(plan["jobs"], dict) or set(plan["jobs"]) != set(JOBS) or any(type(v) is not bool for v in plan["jobs"].values()):
        raise ValueError("plan must declare every job with a boolean")
    if plan["requested"] not in ([], ["thread-sanitizer"]):
        raise ValueError("invalid explicitly requested checks")
    if not isinstance(plan["changes"], list):
        raise ValueError("invalid change evidence")
    selected = set(plan["requested"])
    for change in plan["changes"]:
        if not isinstance(change, dict) or set(change) != {"path", "reason"}:
            raise ValueError("invalid change record")
        impact, reason = path_impact(change["path"])
        if change["reason"] != reason:
            raise ValueError("invalid changed-path requirement")
        selected.update(impact)
    expected = with_dependencies(selected)
    if plan["lane"] != "fast" or not plan["changes"]:
        expected = set(JOBS)
    if plan["event"] not in {"pull_request", "push", "merge_group", "workflow_dispatch"}:
        raise ValueError("invalid plan event")
    if plan["event"] != "pull_request":
        expected.discard("dependency-review")
    if prose:
        expected = {"policy"}
    if plan["jobs"] != {job: job in expected for job in JOBS}:
        raise ValueError("plan does not match required changed-path and dependency selection")


def evaluate(plan, needs, proof=None, root=None, event=None):
    validate_plan(plan)
    if "prose_only" in plan:
        if root is None or not isinstance(event, dict):
            raise ValueError("prose-only result requires immutable Git revalidation")
        prose_module().revalidate(root, event, plan["prose_only"], [change["path"] for change in plan["changes"]])
    reused = reused_jobs(plan, proof or {})
    if not isinstance(needs, dict) or set(needs) != set(JOBS) | {"ci-plan"}:
        raise ValueError("missing or unexpected CI result")
    for job, selected in {"ci-plan": True, **plan["jobs"]}.items():
        result = needs[job].get("result") if isinstance(needs[job], dict) else None
        expected = "success" if selected and job not in reused else "skipped"
        if result != expected:
            raise ValueError(f"{job}: expected {expected}, got {result!r}")


def load_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key: " + key)
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    plan_cmd = sub.add_parser("plan")
    plan_cmd.add_argument("--event", required=True, type=Path)
    plan_cmd.add_argument("--root", type=Path, default=Path("."))
    plan_cmd.add_argument("--output", type=Path, required=True)
    plan_cmd.add_argument("--reuse-proof-json", default=os.environ.get("CI_REUSE", "{}"))
    for name in ("evaluate",):
        evaluate_cmd = sub.add_parser(name)
        evaluate_cmd.add_argument("--plan-json", default=os.environ.get("CI_PLAN", ""))
        evaluate_cmd.add_argument("--needs-json", default=os.environ.get("CI_NEEDS", ""))
        evaluate_cmd.add_argument("--reuse-proof-json", default=os.environ.get("CI_REUSE", "{}"))
    args = parser.parse_args()
    try:
        if args.command == "plan":
            event = load_json(args.event.read_text())
            event_name = os.environ["GITHUB_EVENT_NAME"]
            paths = []
            if event_name == "pull_request":
                pr = event["pull_request"]
                try:
                    paths = changed_paths(args.root, pr["base"]["sha"], pr["head"]["sha"])
                except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
                    print(f"Changed-file evidence unavailable; selecting full validation: {error}", file=sys.stderr)
                    paths = ["__diff_unavailable_full_fallback__"]
            plan = apply_prose(make_plan(event_name, event, paths), args.root, event, paths)
            validate_plan(plan)
            proof = load_json(args.reuse_proof_json)
            reused = reused_jobs(plan, proof)
            if reused and (event_name != "push" or event.get("ref") != "refs/heads/main" or proof["main"] != event.get("after")):
                raise ValueError("reused proof is not for this main push")
            payload = json.dumps(plan, separators=(",", ":"))
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(payload + "\n")
            if "GITHUB_OUTPUT" in os.environ:
                with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
                    stream.write("plan=" + payload + "\n")
                    for job, selected in plan["jobs"].items():
                        stream.write(job + "=" + str(selected and job not in reused).lower() + "\n")
            print(json.dumps(plan, indent=2))
        else:
            proof = load_json(args.reuse_proof_json)
            reuse = reuse_policy()
            reuse.validate_proof(proof)
            if proof:
                event = load_json(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
                reuse.revalidate(proof, event, os.environ)
            plan = load_json(args.plan_json)
            event = load_json(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()) if "prose_only" in plan else None
            evaluate(plan, load_json(args.needs_json), proof, Path("."), event)
            print("CI Required: every logical contract has fresh success or revalidated exact-tree PR evidence; no unexplained skips.")
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f"CI policy rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
