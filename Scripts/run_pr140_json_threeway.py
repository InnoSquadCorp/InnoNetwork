#!/usr/bin/env python3
"""One preregistered JSON attribution experiment; never replaces required CI."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

import benchmark_protocol as protocol
from compare_benchmark_runs import load_report, result_map
from guarded_benchmarks import load_guarded_benchmarks

REVISIONS = {
    "A": "b358692e1e583b5cef1c97bb65208729b313f574",
    "B": "e74f322dc46b660e02c22fb601d8e5e79b0c02a8",
    "C": "955841b398b96b1bf012c9c06c815e10d345109d",
}
ARCHIVE_REF = "refs/heads/benchmark-baselines/json-6.0"
KINDS = ("AA", "AB", "BB", "BC", "CC", "AC")
BUDGET_SECONDS = 2400
SAMPLE_SECONDS = 60
THRESHOLD = 20
METHODOLOGY = (
    "run_same_runner_benchmarks.sh", "benchmark_protocol.py", "compare_benchmark_runs.py",
    "run_with_guarded_benchmarks.py", "guarded_benchmarks.py",
)
ORIGINAL_FAILURE = "https://github.com/InnoSquadCorp/InnoNetwork/actions/runs/36992525790/job/110791851913"


def schedule():
    # Each kind occurs early/middle/late exactly once. Within each comparison,
    # execute base/head, head/base, base/head; three pairs cannot balance fully.
    observations = []
    for round_index in range(3):
        offset = 2 * round_index
        for kind in KINDS[offset:] + KINDS[:offset]:
            sides = ("head", "base") if round_index == 1 else ("base", "head")
            for side in sides:
                observations.append({"kind": kind, "pair": round_index + 1,
                                     "side": side, "revision_label": kind[side == "head"]})
    return observations


def control_failures(report):
    failures = []
    for row in report["baseline"]["deltas"]:
        if (abs(row["deltaPercent"]) > THRESHOLD
                or row["baselineRelativeSpreadPercent"] > THRESHOLD
                or row["currentRelativeSpreadPercent"] > THRESHOLD):
            failures.append(row)
    return failures


def remaining_budget(started, limit, now=None):
    seconds = min(limit, BUDGET_SECONDS - ((time.monotonic() if now is None else now) - started) - 10)
    if seconds <= 0:
        raise TimeoutError("whole-experiment deadline reached")
    return seconds


def validate_json_report(report, guards):
    _, rows = result_map(report, "JSON diagnostic sample")
    protocol.require({"/".join(key) for key in rows} == set(guards)
                     and all(row["iterations"] == 20_000 for row in rows.values()),
                     "JSON workload/iteration contract changed")


def collect_samples(manifests, output, parent, guards, state, destination, remaining):
    for observation in schedule():
        kind, side, pair = observation["kind"], observation["side"], observation["pair"]
        pair_dir = output / kind
        sample_path = pair_dir / f"{side}-{pair}.json"
        code = protocol.sample(manifests[kind], side, sample_path, parent / "missing-baseline.json",
            pair_dir / "protocol" / f"{side}-{pair}-process.json", timeout_seconds=remaining(SAMPLE_SECONDS))
        protocol.require(code == 0, f"sample failed with {code}; collection stops without retry")
        validate_json_report(load_report(sample_path), guards)
        state["samples"].append(observation)
        protocol.write_json(destination, state)


def compare_samples(candidate, output, remaining):
    os.environ["INNO_BENCHMARK_SCOPE"] = "json"
    outcomes, unstable = {}, {}
    for kind in KINDS:
        pair_dir = output / kind
        invocation = uuid.uuid4().hex
        argv = [sys.executable, str(candidate / "Scripts/run_with_guarded_benchmarks.py"), "--",
                sys.executable, str(candidate / "Scripts/compare_benchmark_runs.py")]
        for side in ("base", "head"):
            for pair in range(1, 4):
                argv += ["--" + side, str(pair_dir / f"{side}-{pair}.json")]
        argv += ["--output", str(pair_dir / "results.json"), "--receipt", str(pair_dir / "protocol/comparison.json"),
                 "--invocation-id", invocation, "--source-head", REVISIONS[kind[1]], "--max-regression-percent", "20"]
        code = protocol.execute(argv, pair_dir / "protocol/comparison-process.json", cwd=candidate,
                                timeout_seconds=remaining(60))
        protocol.verify_comparison(pair_dir, invocation, REVISIONS[kind[1]], code)
        report = load_report(pair_dir / "results.json")
        outcomes[kind] = {"guard_exit": code, "guard_failures": report["baseline"]["guardFailures"]}
        if kind[0] == kind[1]:
            unstable[kind] = control_failures(report)
    unstable = {kind: rows for kind, rows in unstable.items() if rows}
    return outcomes, unstable


def main():
    repo = Path(__file__).resolve().parents[1]
    output = repo / ".build/pr140-json-attribution/threeway"
    output.mkdir(parents=True, exist_ok=False)  # no old evidence can be recycled
    started = time.monotonic()
    state = {"schema": 1, "status": "incomplete", "revisions": REVISIONS,
             "schedule": schedule(), "planned_process_count": 36, "samples": [],
             "total_budget_seconds": BUDGET_SECONDS, "sample_limit_seconds": SAMPLE_SECONDS,
             "guard_threshold_percent": THRESHOLD, "original_failure": ORIGINAL_FAILURE,
             "controls": "unstable if any JSON row has abs(paired median)>20 or either side spread>20",
             "limitations": ["Report only; does not replace canonical gate or erase original failure",
                             "No detected control violation is not proof of environmental stability or causality",
                             "Three pairs cannot fully balance direction; JSON-only predecessor workload",
                             "No retry, selected sample, baseline reset, override or trend write"]}
    destination = output / "experiment.json"
    protocol.write_json(destination, state)
    worktrees = []
    parent = None

    def remaining(limit):
        return remaining_budget(started, limit)

    def command(*args):
        return subprocess.check_output(args, text=True, timeout=remaining(60)).strip()

    def expired(signum, frame):
        raise TimeoutError("whole-experiment deadline reached")

    old_handler = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, BUDGET_SECONDS)
    try:
        orchestration = command("git", "-C", str(repo), "rev-parse", "HEAD")
        protocol.require(not os.environ.get("GITHUB_SHA") or orchestration == os.environ["GITHUB_SHA"],
                         "orchestration commit differs from dispatched SHA")
        protocol.require(not os.environ.get("INNO_BENCHMARK_REGRESSION_REASON"), "overrides are forbidden")
        state["orchestration_commit"] = orchestration
        state["orchestration_sha256"] = protocol.sha256(__file__)
        state["environment"] = protocol.host_identity()
        protocol.require(state["environment"]["swift"].splitlines()[0] ==
                         "Apple Swift version 6.2 (swiftlang-6.2.0.19.9 clang-1700.3.19.1)",
                         "requires the original Apple Swift 6.2 compiler build")
        protocol.require(state["environment"]["architecture"] == "arm64"
                         and state["environment"]["sdk_build"] == "25A352",
                         "requires the original architecture and SDK build")
        protocol.require(state["environment"]["xcode"] == "Xcode 26.0.1\nBuild version 17A400",
                         "requires the original Xcode build")
        published = command("git", "-C", str(repo), "ls-remote", "--exit-code", "origin", ARCHIVE_REF)
        protocol.require(published == REVISIONS["A"] + "\t" + ARCHIVE_REF, "archive ref moved")
        command("git", "-C", str(repo), "fetch", "--no-tags", "origin", ARCHIVE_REF)
        protocol.require(command("git", "-C", str(repo), "rev-parse", "FETCH_HEAD") == REVISIONS["A"],
                         "archive fetch moved")
        for revision in REVISIONS.values():
            protocol.require(command("git", "-C", str(repo), "rev-parse", revision + "^{commit}") == revision,
                             "source commit differs")
        command("git", "-C", str(repo), "merge-base", "--is-ancestor", REVISIONS["B"], REVISIONS["C"])
        for path in ("Sources", "Benchmarks") + tuple("Scripts/" + name for name in METHODOLOGY):
            b = command("git", "-C", str(repo), "rev-parse", REVISIONS["B"] + ":" + path)
            c = command("git", "-C", str(repo), "rev-parse", REVISIONS["C"] + ":" + path)
            protocol.require(b == c, "main/candidate measured code or methodology differs")
        for name in METHODOLOGY:
            original = subprocess.check_output(["git", "-C", str(repo), "show", REVISIONS["C"] + ":Scripts/" + name],
                                               timeout=remaining(60))
            protocol.require(original == (repo / "Scripts" / name).read_bytes(), "canonical methodology changed")
        protocol.write_json(destination, state)  # complete fixed plan before builds or samples
        parent = Path(tempfile.mkdtemp(prefix="pr140-json-threeway-", dir=os.environ.get("RUNNER_TEMP")))
        roots, binaries, builds, locks = {}, {}, {}, {}
        for label, revision in REVISIONS.items():
            roots[label] = parent / label
            command("git", "-C", str(repo), "worktree", "add", "--detach", str(roots[label]), revision)
            worktrees.append(roots[label])
        candidate = roots["C"]
        guards = load_guarded_benchmarks(candidate, "json")
        protocol.require(len(guards) == 5, "requires all five JSON guards")
        for label, root in roots.items():
            if label != "C":
                shutil.copyfile(candidate / "Benchmarks/InnoNetworkBenchmarks/main.swift",
                                root / "Benchmarks/InnoNetworkBenchmarks/main.swift")
            locks[label] = protocol.sha256(root / "Package.resolved")
            scratch = parent / (label + "-build")
            argv = ["xcrun", "swift", "build", "-c", "release", "--disable-default-traits",
                    "--product", "InnoNetworkBenchmarks", "--scratch-path", str(scratch),
                    "--cache-path", str(parent / "cache"), "-Xswiftc", "-DINNO_BENCHMARK_PRESERVED_JSON"]
            builds[label] = output / "builds" / (label + ".json")
            code = protocol.execute(argv, builds[label], cwd=root,
                                    stdout_path=output / "builds" / (label + ".log"),
                                    timeout_seconds=remaining(protocol.BUILD_TIMEOUT_SECONDS))
            protocol.require(code == 0, f"{label} build failed with {code}; no samples launched")
            protocol.require(locks[label] == protocol.sha256(root / "Package.resolved"), "build changed exact lock")
            command("git", "-C", str(root), "diff", "--exit-code", "--", "Sources", "Package.swift", "Package.resolved")
            bin_path = command("xcrun", "swift", "build", "--package-path", str(root), "-c", "release",
                               "--disable-default-traits", "--scratch-path", str(scratch),
                               "--cache-path", str(parent / "cache"), "--show-bin-path")
            binaries[label] = Path(bin_path) / "InnoNetworkBenchmarks"
        manifests = {}
        for kind in KINDS:
            remaining(1)
            pair_dir = output / kind
            pair_protocol = pair_dir / "protocol"
            pair_protocol.mkdir(parents=True)
            participants = dict(zip(("base", "head"), kind))
            for side, label in participants.items():
                shutil.copyfile(builds[label], pair_protocol / (side + "-build.json"))
            value = protocol.manifest(pair_protocol,
                {side: roots[label] for side, label in participants.items()},
                {side: REVISIONS[label] for side, label in participants.items()},
                {side: binaries[label] for side, label in participants.items()}, "json")
            protocol.require(value["environment"] == state["environment"], "environment identity changed")
            for side, label in participants.items():
                protocol.require(value["sources"][side]["lock_sha256"] == locks[label], "manifest lock changed")
            value["diagnostic_global_schedule"] = schedule()
            value["original_build_receipts"] = {side: {"label": label, "sha256": protocol.sha256(builds[label])}
                                                for side, label in participants.items()}
            protocol.write_json(pair_protocol / "manifest.json", value)
            if kind[0] == kind[1]:
                protocol.require(value["binaries"]["base"] == value["binaries"]["head"], "control binary differs")
            manifests[kind] = value
        # Preserve executables too; prior reports kept only hashes. These copies
        # are evidence, never alternate measured/rebuilt binaries.
        (output / "binaries").mkdir()
        state["retained_binaries"] = {}
        for label, binary in binaries.items():
            copy = output / "binaries" / label
            shutil.copyfile(binary, copy)
            protocol.require(protocol.sha256(copy) == protocol.sha256(binary), "retained binary differs")
            state["retained_binaries"][label] = {"file": "binaries/" + label, "sha256": protocol.sha256(copy)}
        protocol.write_json(destination, state)
        collect_samples(manifests, output, parent, guards, state, destination, remaining)
        outcomes, unstable = compare_samples(candidate, output, remaining)
        state.update(status="complete", comparisons=outcomes, control_violations=unstable,
                     attribution="inconclusive-control-variation" if unstable else "no-large-control-variation-observed",
                     elapsed_seconds=time.monotonic() - started)
        protocol.write_json(destination, state)
        # This is a separate diagnostic outcome, never a new required-check verdict.
        return 2 if unstable else (1 if any(item["guard_exit"] for item in outcomes.values()) else 0)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        state.update(status="incomplete", attribution="inconclusive", error=str(error),
                     elapsed_seconds=time.monotonic() - started)
        protocol.write_json(destination, state)
        print("PR140 three-way diagnostic incomplete: " + str(error), file=sys.stderr)
        return 2
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, old_handler)
        for root in reversed(worktrees):
            try:
                subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", str(root)],
                               check=True, timeout=20)
            except (OSError, subprocess.SubprocessError) as error:
                print("temporary worktree cleanup failed: " + str(error), file=sys.stderr)
        # Build products/cache remain in this disposable runner directory; do not
        # traverse/delete unrelated workspaces or signal unowned processes.


if __name__ == "__main__":
    raise SystemExit(main())
