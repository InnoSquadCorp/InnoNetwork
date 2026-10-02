"""Exact-tree reuse admission, provenance and fallback contracts; no network/builds."""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "Scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


p = load("main-ci-reuse-policy")
ci = load("ci-policy")
BASE, HEAD, MERGE, MAIN, TREE = (letter * 40 for letter in "abcde")
NUMBER, RUN, SUITE = 49, 900, 400
CONTEXT = {"main": MAIN, "tree": TREE}
ENV = {"GITHUB_REPOSITORY": p.REPOSITORY, "GITHUB_REF": "refs/heads/main",
       "GITHUB_WORKFLOW_REF": p.REPOSITORY + "/" + p.CI_PATH + "@refs/heads/main",
       "GITHUB_WORKFLOW_SHA": MAIN, "GITHUB_SHA": MAIN, "GITHUB_EVENT_NAME": "push"}
INVENTORY = json.loads((Path(__file__).parent / "fixtures/dependabot-full-ci.json").read_text())["jobs"]


class Transcript:
    """Positive fixture uses the repository's full, explicit job/step inventory."""
    def __init__(self):
        self.now = datetime.now(timezone.utc)
        completed = (self.now - timedelta(minutes=40)).isoformat()
        self.repo = {"id": 100, "full_name": p.REPOSITORY}
        self.event = {"ref": "refs/heads/main", "before": BASE, "after": MAIN,
                      "forced": False, "deleted": False, "commits": [{"id": MAIN}], "repository": self.repo}
        self.target = {"sha": MAIN, "tree": {"sha": TREE}, "parents": [{"sha": BASE}]}
        self.candidate = {"sha": MERGE, "tree": {"sha": TREE}, "parents": [{"sha": BASE}, {"sha": HEAD}]}
        self.current = MAIN
        self.connections = [{"number": NUMBER}]
        self.pr = {"number": NUMBER, "state": "closed", "merged": True, "merge_commit_sha": MAIN,
                   "merged_at": (self.now - timedelta(minutes=20)).isoformat(),
                   "base": {"ref": "main", "sha": BASE, "repo": self.repo},
                   "head": {"sha": HEAD, "ref": "topic", "repo": self.repo}}
        self.workflow = {"id": 10, "path": p.CI_PATH, "state": "active"}
        self.run = {"id": RUN, "run_number": 30, "run_attempt": 1, "workflow_id": 10,
                    "path": p.CI_PATH, "event": "pull_request", "status": "completed", "conclusion": "success",
                    "head_sha": HEAD, "head_branch": "topic", "repository": self.repo,
                    "head_repository": self.repo, "pull_requests": [], "check_suite_id": SUITE,
                    "referenced_workflows": [
                        {"path": f"{p.REPOSITORY}/.github/workflows/{name}@{MERGE}",
                         "sha": MERGE, "ref": f"refs/pull/{NUMBER}/merge"} for name in sorted(p.REFERENCED)]}
        self.runs = [self.run]
        self.jobs, self.checks, self.previous = [], [], []
        for index, (name, steps) in enumerate(INVENTORY.items()):
            check_id, job_id = 1000 + index, 2000 + index
            result = "skipped" if name in p.SKIPPED else "success"
            self.jobs.append({"id": job_id, "run_id": RUN, "run_attempt": 1, "head_sha": HEAD,
                              "name": name, "status": "completed", "conclusion": result, "completed_at": completed,
                              "check_run_url": f"https://api.github.com/{p.route('check-runs/')}{check_id}",
                              "steps": [dict(step, status="completed") for step in steps]})
            self.checks.append({"id": check_id, "name": name, "status": "completed", "conclusion": result,
                                "app": {"id": p.APP}, "head_sha": HEAD, "check_suite": {"id": SUITE},
                                "details_url": f"https://github.com/{p.REPOSITORY}/actions/runs/{RUN}/job/{job_id}"})
        self.reads = []

    def get(self, route):
        self.reads.append(route)
        suffix = route.removeprefix(p.route(""))
        if suffix == f"git/commits/{MAIN}":
            value = self.target
        elif suffix == f"git/commits/{MERGE}":
            value = self.candidate
        elif suffix == "git/ref/heads/main":
            value = {"object": {"sha": self.current}}
        elif suffix == f"pulls/{NUMBER}":
            value = self.pr
        elif suffix == "actions/workflows/ci.yml":
            value = self.workflow
        elif suffix.startswith("actions/runs/") and suffix.count("/") == 2:
            value = next(run for run in self.runs if run["id"] == int(suffix.rsplit("/", 1)[1]))
        else:
            raise AssertionError("unexpected metadata route: " + route)
        return copy.deepcopy(value)

    def pages(self, route, key=None):
        self.reads.append(route)
        suffix = route.removeprefix(p.route(""))
        if suffix == f"commits/{MAIN}/pulls":
            value = self.connections
        elif suffix.startswith("actions/workflows/ci.yml/runs?"):
            value = self.runs
        elif suffix == f"actions/runs/{RUN}/attempts/{self.run['run_attempt']}/jobs":
            value = self.jobs
        elif suffix.startswith(f"actions/runs/{RUN}/attempts/"):
            value = self.previous
        elif suffix == f"check-suites/{SUITE}/check-runs?filter=all":
            value = self.checks
        else:
            raise AssertionError("unexpected metadata pages: " + route)
        return copy.deepcopy(value)


def proven(transcript=None):
    t = transcript or Transcript()
    return p.prove(t, t.event, CONTEXT, now=t.now)


def successful_rerun():
    t = Transcript()
    t.previous = copy.deepcopy(t.jobs)
    t.run["run_attempt"] = 2
    for job, old_check in zip(t.jobs, list(t.checks)):
        job["run_attempt"] = 2
        job["id"] += 100
        check_id = old_check["id"] + 100
        job["check_run_url"] = f"https://api.github.com/{p.route('check-runs/')}{check_id}"
        t.checks.append(dict(old_check, id=check_id,
                            details_url=f"https://github.com/{p.REPOSITORY}/actions/runs/{RUN}/job/{job['id']}"))
    return t


class AdmissionTests(unittest.TestCase):
    def test_same_tree_squash_with_empty_post_merge_run_association_is_proven(self):
        t = Transcript()
        proof = proven(t)
        self.assertEqual(proof["main"], MAIN)
        self.assertEqual(proof["merge"], MERGE)
        self.assertNotEqual(proof["main"], proof["merge"])
        self.assertEqual(proof["tree"], TREE)
        self.assertEqual(proof["reused_jobs"], list(p.REUSED_JOBS))
        self.assertFalse(any("artifact" in path or "logs" in path or "statuses" in path for path in t.reads))

    def test_matching_pr_association_is_accepted_and_conflicting_one_rejected(self):
        t = Transcript()
        t.run["pull_requests"] = [{"number": NUMBER, "head": {"sha": HEAD, "ref": "topic", "repo": t.repo},
                                   "base": {"sha": BASE, "ref": "main", "repo": t.repo}}]
        proven(t)
        t.run["pull_requests"][0]["base"]["sha"] = "f" * 40
        with self.assertRaises(p.Rejected):
            proven(t)

    def test_wrong_tree_base_head_main_or_merge_shape_rejects(self):
        mutations = [
            lambda t: t.candidate["tree"].update(sha="f" * 40),
            lambda t: t.target["tree"].update(sha="f" * 40),
            lambda t: t.candidate["parents"][0].update(sha="f" * 40),
            lambda t: t.candidate["parents"][1].update(sha="f" * 40),
            lambda t: t.target["parents"].append({"sha": HEAD}),
            lambda t: t.event.update(before="f" * 40),
            lambda t: t.event.update(after="f" * 40),
            lambda t: setattr(t, "current", "f" * 40),
            lambda t: t.pr["head"].update(sha="f" * 40),
            lambda t: t.pr.update(merge_commit_sha="f" * 40),
            lambda t: t.pr["base"].update(sha="f" * 40),
        ]
        for mutate in mutations:
            t = Transcript()
            mutate(t)
            with self.subTest(mutation=mutations.index(mutate)), self.assertRaises(p.Rejected):
                proven(t)

    def test_direct_multiple_force_deleted_or_fork_pushes_reject(self):
        mutations = [lambda t: t.connections.clear(), lambda t: t.connections.append({"number": 50}),
                     lambda t: t.event["commits"].append({"id": HEAD}), lambda t: t.event.update(forced=True),
                     lambda t: t.event.update(deleted=True), lambda t: t.event.pop("forced"),
                     lambda t: t.pr.update(merged=False), lambda t: t.pr["base"].update(ref="dev"),
                     lambda t: t.pr["head"].update(repo={"id": 999}),
                     lambda t: t.run.update(head_repository={"id": 999})]
        for index, mutate in enumerate(mutations):
            t = Transcript()
            mutate(t)
            with self.subTest(mutation=index), self.assertRaises(p.Rejected):
                proven(t)

    def test_workflow_refs_and_origin_are_immutable(self):
        mutations = [lambda t: t.run.update(workflow_id=20), lambda t: t.run.update(path=".github/workflows/fake.yml"),
                     lambda t: t.run.update(event="workflow_dispatch"), lambda t: t.run.update(head_branch="other"),
                     lambda t: t.workflow.update(state="disabled_manually"),
                     lambda t: t.run["referenced_workflows"].pop(),
                     lambda t: t.run["referenced_workflows"][0].update(sha="f" * 40),
                     lambda t: t.run["referenced_workflows"][0].update(ref="refs/heads/main"),
                     lambda t: t.run["referenced_workflows"][0].update(path="foreign/workflow@" + MERGE)]
        for index, mutate in enumerate(mutations):
            t = Transcript()
            mutate(t)
            with self.subTest(mutation=index), self.assertRaises(p.Rejected):
                proven(t)

    def test_latest_failed_pending_cancelled_or_attempt_never_uses_old_success(self):
        for status, conclusion in [("queued", None), ("in_progress", None), ("completed", "failure"),
                                   ("completed", "cancelled"), ("completed", "neutral")]:
            t = Transcript()
            t.runs.append(dict(t.run, id=RUN + 1, run_number=31, status=status, conclusion=conclusion))
            with self.subTest(status=status, conclusion=conclusion), self.assertRaises(p.Rejected):
                proven(t)
        t = Transcript()
        t.run["run_attempt"] = 2
        with self.assertRaises(p.Rejected):
            proven(t)  # Returned attempt-1 jobs are not current proof.

    def test_latest_successful_attempt_can_coexist_with_historical_checks(self):
        self.assertEqual(proven(successful_rerun())["attempt"], 2)

    def test_historical_check_urls_cannot_smuggle_unassociated_check_ids(self):
        prefix = f"https://api.github.com/{p.route('check-runs/')}"
        for url in [None, "", "https://evil.invalid/1000", "https://api.github.com/repos/foreign/repo/check-runs/1000",
                    prefix, prefix + "abc", prefix + "1000?foreign=true", prefix + "0", prefix + "１０００"]:
            t = successful_rerun()
            t.previous[0]["check_run_url"] = url
            with self.subTest(url=url), self.assertRaises(p.Rejected):
                proven(t)
        t = successful_rerun()
        t.previous[0].pop("check_run_url")
        with self.assertRaises(p.Rejected): proven(t)

    def test_native_check_provenance_cannot_be_spoofed(self):
        mutations = [lambda t: t.checks[0]["app"].update(id=1),
                     lambda t: t.checks[0]["check_suite"].update(id=1),
                     lambda t: t.checks[0].update(head_sha="f" * 40),
                     lambda t: t.checks[0].update(details_url="https://example.invalid/success"),
                     lambda t: t.checks[0].update(name="forged"),
                     lambda t: t.jobs[0].update(check_run_url="https://example.invalid/1000"),
                     lambda t: t.jobs[0].update(run_id=999),
                     lambda t: t.jobs[0].update(head_sha=MAIN),
                     lambda t: t.checks.append(dict(t.checks[0], id=99999)),
                     lambda t: t.checks.append(t.checks[0])]
        for index, mutate in enumerate(mutations):
            t = Transcript()
            mutate(t)
            with self.subTest(mutation=index), self.assertRaises(p.Rejected):
                proven(t)

    def test_complete_inventory_and_successful_steps_are_required(self):
        for kind in ("missing", "duplicate", "extra", "skipped", "failure", "cancelled", "step-missing", "step-skip", "step-duplicate"):
            t = Transcript()
            job = next(job for job in t.jobs if job["name"] == "Tests under ThreadSanitizer")
            if kind == "missing": t.jobs.remove(job)
            elif kind == "duplicate": t.jobs.append(copy.deepcopy(job))
            elif kind == "extra": t.jobs.append(dict(job, name="unexpected"))
            elif kind.startswith("step-"):
                step = next(step for step in job["steps"] if step["name"] == "Run tests under ThreadSanitizer")
                if kind == "step-missing": job["steps"].remove(step)
                elif kind == "step-skip": step["conclusion"] = "skipped"
                else: job["steps"].append(copy.deepcopy(step))
            else: job["conclusion"] = kind
            with self.subTest(kind=kind), self.assertRaises(p.Rejected):
                proven(t)

    def test_only_explicit_informational_step_skips_are_allowed(self):
        t = Transcript()
        proven(t)  # Fixture contains Pages/origin/Swift 6.2 canary skips.
        job = next(job for job in t.jobs if job["name"] == "Consumer Macros")
        next(step for step in job["steps"] if step["name"] == "Verify macro compile-failure diagnostics")["conclusion"] = "skipped"
        with self.assertRaises(p.Rejected): proven(t)

    def test_old_or_post_merge_verification_is_not_reused(self):
        t = Transcript()
        t.pr["merged_at"] = (t.now - timedelta(hours=2)).isoformat()
        with self.assertRaises(p.Rejected): proven(t)
        t = Transcript()
        with self.assertRaises(p.Rejected):
            p.prove(t, t.event, CONTEXT, now=t.now + timedelta(days=2))

    def test_non_push_events_make_no_metadata_calls(self):
        for event in ("pull_request", "merge_group", "workflow_dispatch", "pull_request_target"):
            with mock.patch.object(p, "GitHub") as api:
                proof, _ = p.admit({}, dict(ENV, GITHUB_EVENT_NAME=event))
                self.assertEqual(proof, {})
                api.assert_not_called()

    def test_unknown_evidence_falls_back_before_skipping(self):
        for error in (OSError("API unavailable"), KeyError("missing"), ValueError("bad JSON")):
            with mock.patch.object(p, "checkout_context", return_value=CONTEXT):
                api = mock.Mock()
                api.get.side_effect = error
                proof, reason = p.admit(Transcript().event, ENV, api=api)
                self.assertEqual(proof, {})
                self.assertIn("full validation", reason)

    def test_final_aggregate_rejects_raced_evidence(self):
        t = Transcript()
        proof = proven(t)
        with mock.patch.object(p, "checkout_context", return_value=CONTEXT):
            p.revalidate(proof, t.event, ENV, api=t)
            t.run["run_attempt"] = 2
            with self.assertRaises(p.Rejected): p.revalidate(proof, t.event, ENV, api=t)

    def test_mutation_after_suite_snapshot_is_detected_before_proof_returns(self):
        mutations = [lambda t: t.run.update(run_attempt=2, status="in_progress", conclusion=None),
                     lambda t: t.run.update(status="completed", conclusion="failure"),
                     lambda t: t.runs.append(dict(t.run, id=RUN + 1, run_number=31, status="queued", conclusion=None)),
                     lambda t: setattr(t, "current", "f" * 40)]
        for index, mutate in enumerate(mutations):
            t = Transcript()
            admitted = proven(t)
            original_pages = t.pages
            def racing_pages(route, key=None):
                snapshot = original_pages(route, key)
                if route == p.route(f"check-suites/{SUITE}/check-runs?filter=all"):
                    mutate(t)
                return snapshot
            with self.subTest(mutation=index), mock.patch.object(t, "pages", side_effect=racing_pages), \
                    mock.patch.object(p, "checkout_context", return_value=CONTEXT):
                with self.assertRaises(p.Rejected):
                    p.revalidate(admitted, t.event, ENV, api=t)

    def test_mid_admission_race_selects_full_validation(self):
        t = Transcript()
        original_pages = t.pages
        def racing_pages(route, key=None):
            snapshot = original_pages(route, key)
            if route == p.route(f"check-suites/{SUITE}/check-runs?filter=all"):
                t.run.update(run_attempt=2, status="in_progress", conclusion=None)
            return snapshot
        with mock.patch.object(t, "pages", side_effect=racing_pages), \
                mock.patch.object(p, "checkout_context", return_value=CONTEXT):
            proof, reason = p.admit(t.event, ENV, api=t)
        self.assertEqual(proof, {})
        self.assertIn("full validation", reason)

    def test_checkout_requires_exact_trusted_main_workflow_and_clean_tree(self):
        with mock.patch.object(p.subprocess, "check_output", side_effect=[MAIN + "\n", "", TREE + "\n"]):
            self.assertEqual(p.checkout_context(ROOT, ENV), CONTEXT)
        for key, value in [("GITHUB_EVENT_NAME", "pull_request"), ("GITHUB_WORKFLOW_SHA", HEAD),
                           ("GITHUB_WORKFLOW_REF", "foreign/workflow"), ("GITHUB_REPOSITORY", "fork/repo")]:
            with self.subTest(key=key), self.assertRaises(p.Rejected):
                p.checkout_context(ROOT, dict(ENV, **{key: value}))
        with mock.patch.object(p.subprocess, "check_output", side_effect=[MAIN, "Scripts/ci-policy.py\n"]):
            with self.assertRaises(p.Rejected): p.checkout_context(ROOT, ENV)


class IntegrationTests(unittest.TestCase):
    def test_planner_cli_separates_logical_contract_from_physical_outputs(self):
        t = Transcript()
        with tempfile.TemporaryDirectory(prefix="innonetwork-reuse-plan-") as directory:
            root = Path(directory)
            event, plan_path, outputs = root / "event.json", root / "plan.json", root / "outputs"
            event.write_text(json.dumps(t.event))
            for proof in ({}, proven(t)):
                outputs.write_text("")
                result = subprocess.run([
                    "python3", "-B", str(ROOT / "Scripts/ci-policy.py"), "plan",
                    "--event", str(event), "--output", str(plan_path)],
                    env={"PATH": os.environ["PATH"], "GITHUB_EVENT_NAME": "push",
                         "GITHUB_OUTPUT": str(outputs), "CI_REUSE": json.dumps(proof)},
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                logical = json.loads(plan_path.read_text())
                physical = dict(line.split("=", 1) for line in outputs.read_text().splitlines())
                for job in ci.JOBS:
                    self.assertEqual(logical["jobs"][job], job != "dependency-review")
                    expected = job != "dependency-review" and (not proof or job not in p.REUSED_JOBS)
                    self.assertEqual(physical[job], str(expected).lower())

    def test_aggregate_cli_requeries_admitted_source_and_fails_late_revocation(self):
        t = Transcript()
        proof = proven(t)
        plan = ci.make_plan("push", t.event, [])
        needs = {"ci-plan": {"result": "success"}, **{
            job: {"result": "success" if selected and job not in p.REUSED_JOBS else "skipped"}
            for job, selected in plan["jobs"].items()}}
        with tempfile.TemporaryDirectory(prefix="innonetwork-reuse-evaluate-") as directory:
            event = Path(directory) / "event.json"
            event.write_text(json.dumps(t.event))
            environment = dict(ENV, GITHUB_EVENT_PATH=str(event), CI_REUSE=json.dumps(proof),
                               CI_PLAN=json.dumps(plan), CI_NEEDS=json.dumps(needs))
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch.object(ci.sys, "argv", ["ci-policy.py", "evaluate"]), \
                    mock.patch.object(ci, "reuse_policy", return_value=p), \
                    mock.patch.object(p, "checkout_context", return_value=CONTEXT), \
                    mock.patch.object(p, "GitHub", return_value=t), \
                    mock.patch.object(ci.sys, "stdout", io.StringIO()), \
                    mock.patch.object(ci.sys, "stderr", io.StringIO()):
                self.assertEqual(ci.main(), 0)
                self.assertIn(p.route(f"actions/runs/{RUN}"), t.reads)
                t.run["conclusion"] = "failure"
                self.assertEqual(ci.main(), 1)

    def test_full_logical_requirements_remain_and_only_five_physical_jobs_skip(self):
        plan = ci.make_plan("push", {"ref": "refs/heads/main"}, [])
        proof = proven()
        needs = {"ci-plan": {"result": "success"}, **{
            job: {"result": "success" if selected and job not in p.REUSED_JOBS else "skipped"}
            for job, selected in plan["jobs"].items()}}
        self.assertEqual(set(job for job, selected in plan["jobs"].items() if selected), set(ci.JOBS) - {"dependency-review"})
        ci.evaluate(plan, needs, proof)
        with self.assertRaises(ValueError): ci.evaluate(plan, needs)
        for job in ("policy", "build-and-test", "documentation", "consumer-macros", "consumer-smoke", "benchmark-smoke", "benchmarks", "release-candidate"):
            bad = copy.deepcopy(needs)
            bad[job]["result"] = "skipped"
            with self.subTest(job=job), self.assertRaises(ValueError): ci.evaluate(plan, bad, proof)
        bad = copy.deepcopy(needs)
        bad["thread-sanitizer"]["result"] = "failure"
        with self.assertRaises(ValueError): ci.evaluate(plan, bad, proof)

    def test_proof_schema_and_allowlist_cannot_expand(self):
        for mutation in (lambda proof: proof["reused_jobs"].append("build-and-test"),
                         lambda proof: proof.update(schema=2), lambda proof: proof.update(schema=True),
                         lambda proof: proof.update(run="900"), lambda proof: proof.update(extra=True),
                         lambda proof: proof.update(main="main")):
            proof = proven()
            mutation(proof)
            with self.assertRaises(p.Rejected): p.validate_proof(proof)
        plan = ci.make_plan("pull_request", {"action": "opened", "pull_request": {"labels": [], "user": {"login": "human"}}}, ["Package.swift"])
        with self.assertRaises(ValueError): ci.reused_jobs(plan, proven())

    def test_cli_evaluator_does_not_accept_unverified_json_proof(self):
        plan = ci.make_plan("push", {"ref": "refs/heads/main"}, [])
        result = subprocess.run(["python3", "-B", str(ROOT / "Scripts/ci-policy.py"), "evaluate"],
            env={"PATH": os.environ["PATH"], "CI_PLAN": json.dumps(plan), "CI_NEEDS": "{}", "CI_REUSE": json.dumps(proven())},
            capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_reuse_inventory_preserves_every_network_bot_contract(self):
        from test_dependabot_merge_policy import p as bot_policy, workflow_inventory
        self.assertEqual(p.CORE, bot_policy.CORE)
        self.assertEqual(p.STEP_SKIPS, bot_policy.ALLOWED_STEP_SKIP)
        self.assertEqual(set(p.CORE), set(workflow_inventory()))
        self.assertFalse(p.SKIPPED)
        for name in ("Build and Test (SwiftPM) — Xcode 26.0.1", "Build and Test (SwiftPM) — Xcode 27.0", "Tests under ThreadSanitizer", "Dependency Review"):
            self.assertIn(name, p.CORE)
        self.assertEqual(len([name for name in p.CORE if name.startswith("Apple Platform Build Smoke")]), 5)

    def test_workflow_keeps_main_outputs_and_permissions_scoped(self):
        source = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("reuse: ${{ steps.reuse.outputs.proof }}", source)
        self.assertIn('Scripts/main-ci-reuse-policy.py --event "$GITHUB_EVENT_PATH"', source)
        self.assertIn("CI_REUSE: ${{ needs.ci-plan.outputs.reuse }}", source)
        for job in p.REUSED_JOBS:
            self.assertIn("if: needs.ci-plan.outputs." + job + " == 'true'", source)
        for job in ("build-and-test", "upload-core-coverage", "consumer-macros", "consumer-openapi", "consumer-examples", "benchmark-smoke", "benchmarks", "documentation", "release-candidate"):
            self.assertIn("if: fromJSON(needs.ci-plan.outputs.plan).jobs." + job, source)
        for path in ("release.yml", "release-validation.yml"):
            self.assertNotIn("main-ci-reuse", (ROOT / ".github/workflows" / path).read_text())
        docs = (ROOT / ".github/workflows/docs-publish.yml").read_text()
        self.assertIn("github.event.workflow_run.event == 'push'", docs)
        self.assertIn("Scripts/publish-docs.py", docs)


class TransportTests(unittest.TestCase):
    def test_transport_is_get_only_scoped_and_rejects_redirects(self):
        api = p.GitHub("fixture-token")
        response = mock.MagicMock()
        response.__enter__.return_value = io.StringIO('{"ok":true}')
        response.__enter__.return_value.headers = {}
        with mock.patch.object(api.opener, "open", return_value=response) as opener:
            self.assertEqual(api.get(p.route("pulls/49")), {"ok": True})
            request = opener.call_args.args[0]
            self.assertEqual(request.get_method(), "GET")
            self.assertIsNone(request.data)
        with self.assertRaises(p.Rejected): api.get("repos/foreign/repo/pulls/49")
        with self.assertRaises(p.Rejected): p.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.invalid")
        self.assertFalse(hasattr(api, "mutate"))

    def test_all_pages_and_total_count_are_checked(self):
        api = p.GitHub("fixture-token")
        with mock.patch.object(api, "request", side_effect=[
                ({"jobs": [1], "total_count": 2}, {"Link": '<ignored>; rel="next"'}),
                ({"jobs": [2], "total_count": 2}, {})]):
            self.assertEqual(api.pages(p.route("actions/runs/900/jobs"), "jobs"), [1, 2])
        with mock.patch.object(api, "request", return_value=({"jobs": [1], "total_count": 2}, {})):
            with self.assertRaises(p.Rejected): api.pages(p.route("actions/runs/900/jobs"), "jobs")


if __name__ == "__main__":
    unittest.main()
