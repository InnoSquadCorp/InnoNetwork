#!/usr/bin/env python3
"""Lane-compatible entry point for exact, download-only consumer caches.

Examples, macro fixtures, and the OpenAPI tool remain independent SwiftPM
packages. Their compiled products and generated locks are never restored.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import sys

_MODULE = importlib.util.spec_from_file_location("network_ci_cache", Path(__file__).with_name("ci-cache.py"))
cache = importlib.util.module_from_spec(_MODULE)
_MODULE.loader.exec_module(cache)

LANES = ("examples", "macros", "openapi")
DEPENDENCY_PATHS = list(cache.CACHE_PATHS)


def cache_spec(root, lane, context):
    cache.require(lane in LANES, f"unsupported consumer cache lane: {lane}")
    return cache.fingerprint(cache.repository_inputs(root.resolve()), context, "consumer-" + lane)


def toolchain_context():
    return cache.toolchain_identity()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane", choices=LANES)
    parser.add_argument("--github-output", action="store_true")
    args = parser.parse_args(argv)
    if args.github_output:
        # The shared lifecycle binds observations to the same graph/toolchain.
        return cache.main(["fingerprint", "--profile", "consumer-" + args.lane])
    print(json.dumps(cache_spec(Path(__file__).resolve().parent.parent, args.lane, toolchain_context()), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
