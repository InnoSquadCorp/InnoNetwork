#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$repo_root/Tests/MacroCompileFailureFixtures/OptionalPathAlias"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-macro-negative.XXXXXX")"
log="$scratch/build.log"

cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT

if xcrun swift build \
    --package-path "$fixture" \
    --scratch-path "$scratch/build" \
    >"$log" 2>&1
then
    printf 'Optional path alias fixture unexpectedly compiled successfully.\n' >&2
    exit 1
fi

if ! grep -Fq "percentEncodedSegment" "$log"; then
    printf 'Optional path alias fixture failed for an unexpected reason:\n' >&2
    sed -n '1,240p' "$log" >&2
    exit 1
fi

printf 'Macro compile-failure fixtures passed.\n'
