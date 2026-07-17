#!/usr/bin/env python3

import os
import pathlib
import sys

sys.dont_write_bytecode = True

from guarded_benchmarks import (
    GuardedBenchmarkContractError,
    load_guarded_benchmarks,
)


def fail(message: str, status: int) -> None:
    print(f"guarded-benchmark-runner: {message}", file=sys.stderr)
    raise SystemExit(status)


def main() -> None:
    arguments = sys.argv[1:]
    if not arguments or arguments[0] != "--" or len(arguments) == 1:
        fail(
            "usage: python3 Scripts/run_with_guarded_benchmarks.py -- "
            "<command> [arguments ...]",
            64,
        )

    repo_root = pathlib.Path(
        os.environ.get(
            "INNO_GUARDED_BENCHMARK_CONTRACT_ROOT",
            pathlib.Path(__file__).resolve().parent.parent,
        )
    )
    try:
        identifiers = load_guarded_benchmarks(repo_root)
    except GuardedBenchmarkContractError as error:
        fail(str(error), 1)

    command = arguments[1:]
    guard_arguments = [
        argument
        for identifier in identifiers
        for argument in ("--guard-benchmark", identifier)
    ]
    try:
        os.execvp(command[0], command + guard_arguments)
    except FileNotFoundError:
        fail(f"command is unavailable: {command[0]}", 69)
    except PermissionError:
        fail(f"command is not executable: {command[0]}", 77)


if __name__ == "__main__":
    main()
