#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures_root="$repo_root/Tests/MacroCompileFailureFixtures"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-macro-negative.XXXXXX")"

cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT

fixture_count=0
while IFS= read -r fixture; do
    fixture_count=$((fixture_count + 1))
    fixture_name="$(basename "$fixture")"
    expected_file="$fixture/expected-diagnostic.txt"
    log="$scratch/$fixture_name.log"

    if [[ ! -f "$fixture/Package.swift" ]]; then
        printf '%s is missing Package.swift.\n' "$fixture_name" >&2
        exit 1
    fi

    if [[ ! -s "$expected_file" ]]; then
        printf '%s is missing a non-empty expected-diagnostic.txt.\n' "$fixture_name" >&2
        exit 1
    fi

    expected_diagnostic="$(<"$expected_file")"
    if [[ "$expected_diagnostic" == *$'\n'* ]]; then
        printf '%s expected-diagnostic.txt must contain one diagnostic substring.\n' "$fixture_name" >&2
        exit 1
    fi

    if xcrun swift build \
        --package-path "$fixture" \
        --scratch-path "$scratch/$fixture_name-build" \
        >"$log" 2>&1
    then
        printf '%s unexpectedly compiled successfully.\n' "$fixture_name" >&2
        exit 1
    fi

    if ! grep -Fq -- "$expected_diagnostic" "$log"; then
        printf '%s failed for an unexpected reason (wanted %q):\n' \
            "$fixture_name" "$expected_diagnostic" >&2
        sed -n '1,240p' "$log" >&2
        exit 1
    fi

    printf 'Macro compile-failure fixture passed: %s\n' "$fixture_name"
done < <(find "$fixtures_root" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

if [[ "$fixture_count" -eq 0 ]]; then
    printf 'No macro compile-failure fixtures found in %s.\n' "$fixtures_root" >&2
    exit 1
fi

printf 'Macro compile-failure fixtures passed.\n'
