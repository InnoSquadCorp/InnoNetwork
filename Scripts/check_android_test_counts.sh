#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_minimum_tests() {
    local label="$1"
    local result_dir="$2"
    local minimum="$3"
    local total=0
    local xml_file
    local tests
    local skipped
    local failures
    local errors
    local -a xml_files

    shopt -s nullglob
    xml_files=("$result_dir"/*.xml)
    shopt -u nullglob
    if [[ ${#xml_files[@]} -eq 0 ]]; then
        echo "Missing JUnit results for $label: $result_dir" >&2
        exit 1
    fi

    for xml_file in "${xml_files[@]}"; do
        tests="$(sed -n 's/.*<testsuite[^>]* tests="\([0-9][0-9]*\)".*/\1/p' "$xml_file" | head -n 1)"
        if [[ ! "$tests" =~ ^[0-9]+$ ]]; then
            echo "Could not read the test count from $xml_file" >&2
            exit 1
        fi
        skipped="$(sed -n 's/.*<testsuite[^>]* skipped="\([0-9][0-9]*\)".*/\1/p' "$xml_file" | head -n 1)"
        failures="$(sed -n 's/.*<testsuite[^>]* failures="\([0-9][0-9]*\)".*/\1/p' "$xml_file" | head -n 1)"
        errors="$(sed -n 's/.*<testsuite[^>]* errors="\([0-9][0-9]*\)".*/\1/p' "$xml_file" | head -n 1)"
        if [[ ! "$skipped" =~ ^[0-9]+$ || ! "$failures" =~ ^[0-9]+$ || ! "$errors" =~ ^[0-9]+$ ]] ||
            (( skipped > tests || failures > 0 || errors > 0 )); then
            echo "Invalid or failed JUnit results: $xml_file" >&2
            exit 1
        fi
        total=$((total + tests - skipped))
    done

    if (( total < minimum )); then
        echo "$label executed $total tests; expected at least $minimum." >&2
        exit 1
    fi
    echo "$label tests: $total"
}

assert_minimum_tests \
    "Android transport" \
    "$repo_root/Platforms/Android/innonetwork/build/test-results/testDebugUnitTest" \
    17
assert_minimum_tests \
    "Android typed client" \
    "$repo_root/Platforms/Android/innonetwork-client/build/test-results/testDebugUnitTest" \
    4
assert_minimum_tests \
    "Android serialization" \
    "$repo_root/Platforms/Android/innonetwork-kotlinx-serialization/build/test-results/testDebugUnitTest" \
    3
assert_minimum_tests \
    "Android KSP" \
    "$repo_root/Platforms/Android/innonetwork-ksp/build/test-results/test" \
    5
assert_minimum_tests \
    "Android published consumer" \
    "$repo_root/SmokeTests/AndroidConsumer/consumer/build/test-results/testDebugUnitTest" \
    8

echo "Android executable test-count gate: OK"
