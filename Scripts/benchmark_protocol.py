#!/usr/bin/env python3
"""Bounded benchmark provenance and fixed diagnostic controls; never a performance verdict.

Collection wraps process boundaries, outside Swift's timed measurement closure.
The primary 20% guard remains owned by compare_benchmark_runs.py. Controls may
explain uncertainty but never erase, retry or replace that guard's outcome.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import resource
import re
import signal
import subprocess
import sys
import time

from compare_benchmark_runs import (build_comparison_report, comparison_receipt, finite_numbers,
                                    load_report, result_map)

SCHEMA = 1
PRIMARY_TIMEOUT_SECONDS = 300
BUILD_TIMEOUT_SECONDS = 1200
DIAGNOSTIC_BUDGET_SECONDS = 360
DIAGNOSTIC_SAMPLE_TIMEOUT_SECONDS = 45
EVENT = ("events", "task-event-fanout-single")


def require(value, message):
    if not value:
        raise ValueError(message)


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")
    temporary.replace(path)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command(*arguments):
    return subprocess.check_output(arguments, text=True, timeout=15).strip()


def host_identity():
    return {
        "swift": command("xcrun", "swift", "--version"),
        "swift_path": command("xcrun", "--find", "swift"),
        "xcode": command("xcodebuild", "-version"),
        "developer_directory": command("xcode-select", "-p"),
        "sdk_version": command("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "sdk_build": command("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        "sdk_path": command("xcrun", "--sdk", "macosx", "--show-sdk-path"),
        "os_version": command("sw_vers", "-productVersion"),
        "os_build": command("sw_vers", "-buildVersion"),
        "architecture": command("uname", "-m"),
        "logical_cpus": os.cpu_count(),
        "runner_image": os.environ.get("ImageVersion", "unavailable"),
    }


def source_identity(root, expected):
    root = str(Path(root).resolve())
    actual = command("git", "-C", root, "rev-parse", "HEAD")
    require(actual == expected, "source checkout moved")
    # The candidate harness is copied over the base harness intentionally.
    # Record both Git object identity and the actual measured harness bytes.
    files = ("Sources", "Benchmarks", "Package.swift", "Package.resolved")
    tracked = command("git", "-C", root, "ls-files", "-z", "--", *files).split("\0")
    actual_files = {name: sha256(Path(root) / name) for name in tracked if name}
    return {
        "commit": actual,
        "actual_tracked_file_sha256": actual_files,
        "git_objects": {name: command("git", "-C", root, "rev-parse", "HEAD:" + name) for name in files},
        "measured_harness_sha256": sha256(Path(root) / "Benchmarks/InnoNetworkBenchmarks/main.swift"),
        "manifest_sha256": sha256(Path(root) / "Package.swift"),
        "lock_sha256": sha256(Path(root) / "Package.resolved"),
    }


def system_snapshot():
    # These are observations, not thermal/scheduler diagnoses. No elevated
    # commands, CPU affinity, priority, power or machine settings are changed.
    return {"wall_time_ns": time.time_ns(), "monotonic_ns": time.monotonic_ns(),
            "load_average": list(os.getloadavg())}


def child_group_exists(child):
    # execute creates this session; never signal the collector's own group.
    require(child.pid != os.getpgrp(), "refusing collector process-group cleanup")
    # Darwin may report EPERM for an exited, unreaped group leader. Reap our
    # child and retry the group probe; a live/unauthorized group still fails.
    child.poll()
    try:
        os.killpg(child.pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        child.poll()
        try:
            os.killpg(child.pid, 0)
        except ProcessLookupError:
            return False
    return True


def terminate_child(child):
    # Reaping the leader does not prove that its compiler/benchmark descendants
    # have exited. Keep the owned PGID through the whole bounded TERM grace.
    if child_group_exists(child):
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 2
        while child_group_exists(child) and time.monotonic() < deadline:
            child.poll()
            time.sleep(0.01)
        if child_group_exists(child):
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        return False
    return True


def execute(argv, record_path, *, cwd=None, stdout_path=None, timeout_seconds=PRIMARY_TIMEOUT_SECONDS):
    require(isinstance(argv, list) and argv and all(isinstance(x, str) and x for x in argv), "invalid command")
    require(type(timeout_seconds) in (float, int) and math.isfinite(timeout_seconds) and timeout_seconds > 0,
            "invalid process timeout")
    record = {"schema": SCHEMA, "argv": argv, "cwd": str(Path(cwd or '.').resolve()),
              "timeout_seconds": timeout_seconds, "before": system_snapshot(), "status": "running"}
    write_json(record_path, record)
    before_usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    child = None
    stream = None
    code = 2
    handlers = {signum: signal.getsignal(signum) for signum in (signal.SIGINT, signal.SIGTERM)}

    def interrupted(signum, frame):
        raise InterruptedError(signum, "benchmark collection interrupted")

    try:
        for signum in handlers:
            signal.signal(signum, interrupted)
        if stdout_path:
            stdout_path = Path(stdout_path)
            stdout_path.parent.mkdir(parents=True, exist_ok=True)
            stream = stdout_path.open("w")
        child = subprocess.Popen(argv, cwd=cwd, stdout=stream, start_new_session=True)
        try:
            code = child.wait(timeout=timeout_seconds)
            record["status"] = "completed" if code == 0 else "process-failed"
            code = 128 - code if code < 0 else code
        except subprocess.TimeoutExpired:
            record["status"] = "timeout"
            code = 124
    except InterruptedError as error:
        record["status"] = "interrupted"
        code = 128 + int(error.errno)
    except OSError as error:
        record.update(status="launch-failed", error=str(error))
        code = 2
    finally:
        # Repeated cancellation cannot interrupt bounded cleanup. Only the
        # session created above is signalled, including a group whose leader
        # already returned. A successful leader with descendants is incomplete.
        for signum in handlers:
            signal.signal(signum, signal.SIG_IGN)
        try:
            if child is not None:
                if child_group_exists(child):
                    if record["status"] == "completed":
                        record["status"] = "unfinished-descendants"
                        code = 2
                    record["cleanup_leader_reaped"] = terminate_child(child)
                else:
                    child.poll()
        except OSError as error:
            record["cleanup_error"] = str(error)
            if code == 0:
                code = 2
                record["status"] = "cleanup-failed"
        finally:
            try:
                if stream:
                    stream.close()
            except OSError as error:
                record["stream_close_error"] = str(error)
                if code == 0:
                    code = 2
                    record["status"] = "cleanup-failed"
            finally:
                for signum, handler in handlers.items():
                    signal.signal(signum, handler)
        after_usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        record.update(after=system_snapshot(), exit_code=code, process_usage={
            "user_cpu_seconds": after_usage.ru_utime - before_usage.ru_utime,
            "system_cpu_seconds": after_usage.ru_stime - before_usage.ru_stime,
            "voluntary_context_switches": after_usage.ru_nvcsw - before_usage.ru_nvcsw,
            "involuntary_context_switches": after_usage.ru_nivcsw - before_usage.ru_nivcsw,
            "max_resident_set_size": after_usage.ru_maxrss,
            "max_resident_set_size_unit": "bytes" if sys.platform == "darwin" else "KiB",
            "max_resident_set_size_scope": "cumulative high-water across this collector's reaped children; not sample-only RSS",
            "scope": "whole child process, not an individual timed benchmark closure",
        })
        write_json(record_path, record)
    return code


def manifest(directory, roots, revisions, binaries, lane):
    directory = Path(directory)
    require(lane in ("runtime", "json"), "invalid benchmark lane")
    builds = {side: load_report(directory / (side + "-build.json")) for side in ("base", "head")}
    require(all(build["status"] == "completed" and build["exit_code"] == 0 for build in builds.values()),
            "provenance requires successful captured builds")
    value = {"schema": SCHEMA, "lane": lane, "environment": host_identity(),
             "github": {key: os.environ.get(key, "") for key in
                        ("GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB")},
             "methodology_sha256": {name: sha256(Path(__file__).with_name(name)) for name in (
                 "benchmark_protocol.py", "run_same_runner_benchmarks.sh", "compare_benchmark_runs.py",
                 "run_with_guarded_benchmarks.py", "guarded_benchmarks.py")},
             "builds": builds, "sources": {}, "binaries": {},
             "primary_sample_order": ["base-1", "head-1", "head-2", "base-2", "base-3", "head-3"]}
    for side in ("base", "head"):
        value["sources"][side] = source_identity(roots[side], revisions[side])
        binary = Path(binaries[side]).resolve()
        require(binary.is_file() and os.access(binary, os.X_OK), "missing executable benchmark binary")
        value["binaries"][side] = {"path": str(binary), "sha256": sha256(binary)}
    require(value["sources"]["base"]["measured_harness_sha256"] == value["sources"]["head"]["measured_harness_sha256"],
            "baseline and candidate measured different harnesses")
    write_json(directory / "manifest.json", value)
    return value


def load_manifest(path):
    value = load_report(Path(path))
    require(isinstance(value, dict) and type(value.get("schema")) is int and value["schema"] == SCHEMA and value.get("lane") in ("runtime", "json"),
            "unsupported protocol manifest")
    require(set(value.get("binaries", {})) == {"base", "head"}, "incomplete binary identities")
    for binary in value["binaries"].values():
        require(isinstance(binary, dict) and set(binary) == {"path", "sha256"} and
                Path(binary["path"]).is_absolute() and isinstance(binary["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", binary["sha256"]),
                "malformed binary identity")
    return value


def verify_comparison(directory, invocation_id, source_head, exit_code):
    directory = Path(directory)
    require(exit_code in (0, 1), "comparison was not a valid guard verdict")
    output = directory / "results.json"
    report = load_report(output)
    result_map(report, "completed comparison")
    finite_numbers(report)
    require(isinstance(report.get("baseline", {}).get("guardFailures"), list), "missing guard verdict")
    expected = comparison_receipt(report, output,
                                  [directory / f"base-{index}.json" for index in range(1, 4)],
                                  [directory / f"head-{index}.json" for index in range(1, 4)],
                                  invocation_id, source_head)
    require(expected["exit_code"] == exit_code, "comparison exit disagrees with guard failures")
    require(load_report(directory / "protocol/comparison.json") == expected,
            "comparison receipt does not match this invocation, source, inputs and output")


def sample(value, side, output, missing_baseline, record_path, *, only_events=False, timeout_seconds=PRIMARY_TIMEOUT_SECONDS):
    require(side in ("base", "head"), "invalid binary role")
    binary = value["binaries"][side]
    require(sha256(binary["path"]) == binary["sha256"], "benchmark binary changed before execution")
    argv = [binary["path"], "--quick"]
    if only_events:
        argv += ["--only", "events"]
    elif value["lane"] == "json":
        argv += ["--only", "json"]
    argv += ["--json-path", str(output), "--baseline", str(missing_baseline)]
    require(not Path(missing_baseline).exists(), "sample baseline must be the intentionally missing path")
    # This is a collector-owned report destination. A process that exits zero
    # without writing fresh output must not inherit an earlier sample's data.
    Path(output).unlink(missing_ok=True)
    code = execute(argv, record_path, stdout_path=Path(output).with_suffix(".log"), timeout_seconds=timeout_seconds)
    record = load_report(Path(record_path))
    record.update(binary_role=side, binary_sha256_before=binary["sha256"], binary_sha256_after=sha256(binary["path"]))
    write_json(record_path, record)
    require(record["binary_sha256_after"] == binary["sha256"], "benchmark binary changed during execution")
    if code:
        return 2 if code == 1 else code  # exit 1 is reserved for valid comparison regressions
    report = load_report(Path(output))
    _, rows = result_map(report, str(output))
    timed_seconds = sum(row["elapsedSeconds"] for row in rows.values())
    process_wall_seconds = (record["after"]["monotonic_ns"] - record["before"]["monotonic_ns"]) / 1_000_000_000
    require(timed_seconds <= process_wall_seconds + 0.05, "reported measurement exceeds its process wall-time bound")
    record.update(report_sha256=sha256(output), total_reported_timed_seconds=timed_seconds,
                  process_wall_seconds=process_wall_seconds)
    write_json(record_path, record)
    if only_events:
        require(set(rows) == {EVENT} and rows[EVENT]["iterations"] == 300_000,
                "diagnostics must preserve the event-only 300000-delivery workload")
    return 0


def diagnostic_schedule():
    # 3 A/A pairs, 3 B/B pairs, 3 forward A/B pairs, 3 reverse A/B pairs.
    # Interleave experiment kinds, rather than putting all A/A observations in
    # one thermal phase. The schedule is fixed before any results are read.
    sequence = []
    kinds = (("AA", "base", "base"), ("BB", "head", "head"),
             ("AB", "base", "head"), ("BA", "head", "base"))
    for pair in range(1, 4):
        for label, first, second in (kinds if pair % 2 else tuple(reversed(kinds))):
            sequence.extend([(label, pair, 1, first), (label, pair, 2, second)])
    return sequence


def diagnostics(value, directory, missing_baseline, *, budget_seconds=DIAGNOSTIC_BUDGET_SECONDS):
    require(value["lane"] == "runtime", "event diagnostics are runtime-only")
    require(type(budget_seconds) in (int, float) and 0 < budget_seconds <= DIAGNOSTIC_BUDGET_SECONDS,
            "diagnostic budget cannot expand")
    directory = Path(directory)
    started = time.monotonic()
    evidence = {"schema": SCHEMA, "purpose": "diagnostic-only; never replaces primary 20% gate",
                "budget_seconds": budget_seconds, "sample_limit_seconds": DIAGNOSTIC_SAMPLE_TIMEOUT_SECONDS,
                "planned_sample_count": 24, "schedule": diagnostic_schedule(), "samples": [], "status": "in_progress"}
    destination = directory / "diagnostics.json"
    write_json(destination, evidence)
    reports = {}
    for label, pair, position, side in diagnostic_schedule():
        remaining = budget_seconds - (time.monotonic() - started) - 4  # reserve bounded termination grace
        if remaining <= 0:
            evidence.update(status="budget-exhausted", elapsed_seconds=time.monotonic()-started)
            write_json(destination, evidence)
            return 124
        name = f"{label}-{pair}-{position}"
        output = directory / (name + ".json")
        code = sample(value, side, output, missing_baseline, directory / (name + "-process.json"),
                      only_events=True, timeout_seconds=min(DIAGNOSTIC_SAMPLE_TIMEOUT_SECONDS, remaining))
        evidence["samples"].append({"name": name, "binary_role": side, "output": output.name, "exit_code": code})
        if code:
            evidence.update(status="incomplete", elapsed_seconds=time.monotonic()-started)
            write_json(destination, evidence)
            return code  # no retry, selection or additional sample after failure
        reports[(label, pair, position)] = load_report(output)
        write_json(destination, evidence)
    comparisons = {}
    for label in ("AA", "BB", "AB", "BA"):
        # BA is executed in reverse but reported as candidate minus baseline,
        # exactly like AB; never invert the effect merely by swapping labels.
        left, right = (2, 1) if label == "BA" else (1, 2)
        comparisons[label] = build_comparison_report(
            [reports[(label, pair, left)] for pair in range(1, 4)],
            [reports[(label, pair, right)] for pair in range(1, 4)], set(), 20)["baseline"]["deltas"]
    evidence.update(status="complete", elapsed_seconds=time.monotonic()-started, comparisons=comparisons,
                    limitation="event-only fresh processes; does not reproduce the full-suite predecessor workload or diagnose the original run's scheduler/thermal cause")
    write_json(destination, evidence)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="command", required=True)
    build = subs.add_parser("build")
    build.add_argument("--directory", type=Path, required=True)
    build.add_argument("--side", choices=("base", "head"), required=True)
    build.add_argument("--cwd", type=Path, required=True)
    build.add_argument("arguments", nargs=argparse.REMAINDER)
    identity = subs.add_parser("manifest")
    identity.add_argument("--directory", type=Path, required=True)
    identity.add_argument("--lane", choices=("runtime", "json"), required=True)
    for side in ("base", "head"):
        for suffix in ("root", "revision", "binary"):
            identity.add_argument("--" + side + "-" + suffix, required=True)
    run = subs.add_parser("sample")
    run.add_argument("--manifest", type=Path, required=True)
    run.add_argument("--side", choices=("base", "head"), required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--missing-baseline", type=Path, required=True)
    control = subs.add_parser("diagnostics")
    control.add_argument("--manifest", type=Path, required=True)
    control.add_argument("--directory", type=Path, required=True)
    control.add_argument("--missing-baseline", type=Path, required=True)
    receipt = subs.add_parser("verify-comparison")
    receipt.add_argument("--directory", type=Path, required=True)
    receipt.add_argument("--invocation-id", required=True)
    receipt.add_argument("--source-head", required=True)
    receipt.add_argument("--exit-code", type=int, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            require(args.arguments and args.arguments[0] == "--", "build command delimiter missing")
            code = execute(args.arguments[1:], args.directory / (args.side + "-build.json"),
                           cwd=args.cwd, timeout_seconds=BUILD_TIMEOUT_SECONDS)
            return 2 if code == 1 else code
        if args.command == "manifest":
            manifest(args.directory, {side:getattr(args, side+"_root") for side in ("base","head")},
                     {side:getattr(args, side+"_revision") for side in ("base","head")},
                     {side:getattr(args, side+"_binary") for side in ("base","head")}, args.lane)
            return 0
        if args.command == "verify-comparison":
            verify_comparison(args.directory, args.invocation_id, args.source_head, args.exit_code)
            return 0
        value = load_manifest(args.manifest)
        if args.command == "sample":
            return sample(value, args.side, args.output, args.missing_baseline,
                          args.manifest.parent / (args.output.stem + "-process.json"))
        return diagnostics(value, args.directory, args.missing_baseline)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print("benchmark protocol rejected: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
