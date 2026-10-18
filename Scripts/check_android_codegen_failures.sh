#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log_file="$(mktemp "${TMPDIR:-/tmp}/innonetwork-codegen-failure.XXXXXX")"
trap 'rm -f "$log_file"' EXIT

if "$repo_root/Platforms/Android/gradlew" \
    -p "$repo_root/SmokeTests/AndroidConsumer" \
    :invalid:kspDebugKotlin \
    -PusePublishedPreview=true \
    --rerun-tasks >"$log_file" 2>&1; then
    echo "Expected the invalid endpoint fixture to fail KSP validation." >&2
    exit 1
fi

grep -Fq '[InnoNetwork] missing @InnoPath properties: id' "$log_file"
grep -Fq '[InnoNetwork] unused @InnoPath properties: userID' "$log_file"
grep -Fq '[InnoNetwork] method must be a valid uppercase HTTP token' "$log_file"
grep -Fq '[InnoNetwork] POST @InnoBody properties must be non-null' "$log_file"
grep -Fq '[InnoNetwork] header names must be valid HTTP field names' "$log_file"
grep -Fq '[InnoNetwork] duplicate header name: x-request-id' "$log_file"
grep -Fq '[InnoNetwork] path must not contain dot segments' "$log_file"
grep -Fq '[InnoNetwork] endpoint properties must be public or internal' "$log_file"

echo "Android code generation negative fixtures: OK"
