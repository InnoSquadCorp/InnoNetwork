#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper_dir="$repo_root/Platforms/Android/gradle/wrapper"
properties="$wrapper_dir/gradle-wrapper.properties"
wrapper_jar="$wrapper_dir/gradle-wrapper.jar"

# A wrapper update changes these pins in a human replacement PR; see
# "Gradle updates land through a human replacement PR" in docs/CIAutomation.md.
expected_url='https\://services.gradle.org/distributions/gradle-9.9.0-bin.zip'
expected_distribution_sha='0b00b0ffe07c4d4789c12d4935a44a7057d55774b7540bd4a3f76f336deb177a'
expected_wrapper_sha='621008afc4f5d59357fcf06ffa644dd5aade5e091bdc363742710445f73cdaf8'

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
