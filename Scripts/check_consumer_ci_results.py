#!/usr/bin/env python3
"""Fail closed unless every required consumer lane actually succeeded."""

import json
import os
import sys

LANES = {"consumer-examples", "consumer-macros", "consumer-openapi"}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate job/result key: {key}")
        result[key] = value
    return result


def validate(results):
    if not isinstance(results, dict) or set(results) != LANES:
        raise ValueError("expected exactly the examples, macros and OpenAPI jobs")
    failed = [
        job for job, data in results.items()
        if not isinstance(data, dict) or data.get("result") != "success"
    ]
    if failed:
        raise ValueError(f"consumer lanes did not succeed: {', '.join(sorted(failed))}")


def main():
    try:
        validate(json.loads(os.environ.get("CONSUMER_JOB_RESULTS", ""),
                            object_pairs_hook=unique_object))
    except (ValueError, TypeError) as error:
        print(f"consumer-ci: {error}", file=sys.stderr)
        return 1
    print("consumer-ci: all three lanes succeeded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
