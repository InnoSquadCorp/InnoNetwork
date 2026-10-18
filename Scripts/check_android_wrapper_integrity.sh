#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper_dir="$repo_root/Platforms/Android/gradle/wrapper"
properties="$wrapper_dir/gradle-wrapper.properties"
wrapper_jar="$wrapper_dir/gradle-wrapper.jar"

expected_url='https\://services.gradle.org/distributions/gradle-9.5.1-bin.zip'
expected_distribution_sha='bafc141b619ad6350fd975fc903156dd5c151998cc8b058e8c1044ab5f7b031f'
expected_wrapper_sha='497c8c2a7e5031f6aa847f88104aa80a93532ec32ee17bdb8d1d2f67a194a9c7'

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
