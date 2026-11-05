#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper_dir="$repo_root/Platforms/Android/gradle/wrapper"
properties="$wrapper_dir/gradle-wrapper.properties"
wrapper_jar="$wrapper_dir/gradle-wrapper.jar"

expected_url='https\://services.gradle.org/distributions/gradle-9.8.2-bin.zip'
expected_distribution_sha='21bd5da2de49b642904077f38c0efdc7778e92b3ed0889392dca61b97e389607'
expected_wrapper_sha='3b8a25775a69158b5ad2b1d17a80a88dc7b40a352a73eb27d06c612a7ce68e98'

property_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$properties"
}

if command -v shasum >/dev/null 2>&1; then
    actual_wrapper_sha="$(shasum -a 256 "$wrapper_jar" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
    actual_wrapper_sha="$(sha256sum "$wrapper_jar" | awk '{print $1}')"
else
    echo "Neither shasum nor sha256sum is available." >&2
    exit 1
fi

[[ "$(property_value distributionUrl)" == "$expected_url" ]] || {
    echo "Unexpected Gradle distribution URL." >&2
    exit 1
}

[[ "$(property_value distributionSha256Sum)" == "$expected_distribution_sha" ]] || {
    echo "Unexpected Gradle distribution checksum." >&2
    exit 1
}

[[ "$(property_value validateDistributionUrl)" == "true" ]] || {
    echo "Gradle distribution URL validation must remain enabled." >&2
    exit 1
}

[[ "$actual_wrapper_sha" == "$expected_wrapper_sha" ]] || {
    echo "Unexpected Gradle wrapper JAR checksum: $actual_wrapper_sha" >&2
    exit 1
}

echo "Gradle wrapper integrity: OK"
