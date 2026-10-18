#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository="$repo_root/Platforms/Android/build/preview-repository/com/innosquad/innonetwork"
version="1.0.0"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-artifacts.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# Keep the actual artifact list explicit so an accidental module rename cannot
# silently weaken the release contract.
base_module="innonetwork"
modules=(
    "$base_module:aar"
    "$base_module-client:aar"
    "$base_module-kotlinx-serialization:aar"
    "$base_module-ksp:jar"
)

sha256_file() {
    local file="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    else
        echo "Neither shasum nor sha256sum is available." >&2
        exit 1
    fi
}

verify_artifact() {
    local file="$1"
    local checksum_file="$file.sha256"

    [[ -s "$file" ]] || {
        echo "Missing or empty release artifact: $file" >&2
        exit 1
    }
    [[ -s "$checksum_file" ]] || {
        echo "Missing release artifact checksum: $checksum_file" >&2
        exit 1
    }
    [[ "$(sha256_file "$file")" == "$(tr -d '[:space:]' < "$checksum_file")" ]] || {
        echo "Release artifact checksum mismatch: $file" >&2
        exit 1
    }
}

verify_license() {
    local archive="$1"
    local module="$2"
    unzip -p "$archive" "META-INF/$module/LICENSE" >"$work_dir/LICENSE"
    cmp "$repo_root/LICENSE" "$work_dir/LICENSE" || {
        echo "Release artifact license is missing or stale: $archive" >&2
        exit 1
    }
}

for module_spec in "${modules[@]}"; do
    module="${module_spec%%:*}"
    binary_extension="${module_spec##*:}"
    directory="$repository/$module/$version"
    prefix="$directory/$module-$version"

    verify_artifact "$prefix.$binary_extension"
    verify_artifact "$prefix-sources.jar"
    verify_artifact "$prefix-javadoc.jar"
    verify_artifact "$prefix.pom"
    verify_artifact "$prefix.module"

    verify_license "$prefix-sources.jar" "$module"
    verify_license "$prefix-javadoc.jar" "$module"
    if [[ "$binary_extension" == "aar" ]]; then
        unzip -p "$prefix.aar" classes.jar >"$work_dir/$module-classes.jar"
        verify_license "$work_dir/$module-classes.jar" "$module"
    else
        verify_license "$prefix.jar" "$module"
    fi

    jar tf "$prefix-sources.jar" | grep -Eq '\.kt$' || {
        echo "Sources JAR has no Kotlin sources: $module" >&2
        exit 1
    }
    jar tf "$prefix-javadoc.jar" | grep -qx 'index.html' || {
        echo "Documentation JAR has no index.html: $module" >&2
        exit 1
    }

    for required_pom_element in groupId artifactId version name description url licenses developers scm; do
        grep -q "<$required_pom_element>" "$prefix.pom" || {
            echo "POM is missing <$required_pom_element>: $module" >&2
            exit 1
        }
    done
done

echo "Android Maven release artifacts: OK"
