#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator_runner="$repo_root/Scripts/validate_hls_with_apple_tools.sh"
materializer="$repo_root/Scripts/materialize_hls_conformance_fixtures.py"
report_checker="$repo_root/Scripts/check_apple_hls_report.py"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-apple-hls-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

fixture_root="$work_dir/materialized"
python3 "$materializer" \
  "$repo_root/Tests/InnoNetworkHLSTests/HLSMediaFixtures.swift" \
  "$fixture_root"

test -s "$fixture_root/transport-stream/index.m3u8"
test -s "$fixture_root/transport-stream/segment-0.ts"
test -s "$fixture_root/fragmented-mp4/index.m3u8"
test -s "$fixture_root/fragmented-mp4/init.mp4"
test -s "$fixture_root/fragmented-mp4/segment-0.m4s"
test -s "$fixture_root/fragmented-mp4/segment-1.m4s"
grep -Fxq '#EXT-X-ENDLIST' "$fixture_root/transport-stream/index.m3u8"
grep -Fxq '#EXT-X-MAP:URI="init.mp4"' "$fixture_root/fragmented-mp4/index.m3u8"
test "$(sed -n '1p' "$fixture_root/transport-stream/index.m3u8")" = '#EXTM3U'
test "$(sed -n '1p' "$fixture_root/fragmented-mp4/index.m3u8")" = '#EXTM3U'

expect_hash() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Unexpected fixture hash for $path: $actual" >&2
    exit 1
  fi
}

expect_hash \
  "$fixture_root/transport-stream/segment-0.ts" \
  "02ccf0367ea29464ac039eadab725e463386f96e15ac0f5995f216ff33e4e0f6"
expect_hash \
  "$fixture_root/fragmented-mp4/init.mp4" \
  "9d5dfad0b34d79e363976edeea823601ad7527d5c03ff6a793213e2a46aac44b"
expect_hash \
  "$fixture_root/fragmented-mp4/segment-0.m4s" \
  "42d991769870848bed1818b8a7b437835178cdf8b9da4ce7381f05df3cc732dd"
expect_hash \
  "$fixture_root/fragmented-mp4/segment-1.m4s" \
  "c773e6bb59a394fa3874624a3c2a540337dcb2d781fa52c33e90abf6cb902454"

cat >"$work_dir/report-ok.html" <<'EOF'
<html><body><h2>Should Fix Issues</h2><p>Target duration advice.</p><h2>Report Information</h2></body></html>
EOF
python3 "$report_checker" "$work_dir/report-ok.html"

cat >"$work_dir/report-none.html" <<'EOF'
<html><body><h2>Must Fix Issues</h2><p>None</p><h2>Report Information</h2></body></html>
EOF
python3 "$report_checker" "$work_dir/report-none.html"

cat >"$work_dir/report-failed.html" <<'EOF'
<html><body><h2>Must Fix Issues</h2><ol><li>Invalid segment.</li></ol><h2>Should Fix Issues</h2></body></html>
EOF
if python3 "$report_checker" "$work_dir/report-failed.html" >/dev/null 2>&1; then
  echo "Expected Must Fix report validation to fail." >&2
  exit 1
fi

: >"$work_dir/report-empty.html"
if python3 "$report_checker" "$work_dir/report-empty.html" >/dev/null 2>&1; then
  echo "Expected an empty HLS report to fail." >&2
  exit 1
fi

cat >"$work_dir/report-unknown.html" <<'EOF'
<html><body><p>Unknown future report format.</p></body></html>
EOF
if python3 "$report_checker" "$work_dir/report-unknown.html" >/dev/null 2>&1; then
  echo "Expected an unrecognized HLS report to fail." >&2
  exit 1
fi

cat >"$work_dir/validator-ok" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = "-O"
printf '{"validated":true}\n' >"$2"
printf 'Validated %s\n' "$3"
EOF
chmod +x "$work_dir/validator-ok"

cat >"$work_dir/reporter-ok" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = "-o"
printf '<html><body><h2>Should Fix Issues</h2><h2>Report Information</h2></body></html>\n' >"$2"
test -s "$3"
printf 'Reported %s\n' "$3"
EOF
chmod +x "$work_dir/reporter-ok"

report_root="$work_dir/reports"
APPLE_HLS_MEDIASTREAMVALIDATOR="$work_dir/validator-ok" \
APPLE_HLS_REPORT="$work_dir/reporter-ok" \
  bash "$validator_runner" \
    --require-tools \
    --report-root "$report_root" >"$work_dir/success.log"

grep -Fq 'apple-hls-conformance: OK (2 playlists)' "$work_dir/success.log"
retained_directory="$(find "$report_root" -mindepth 1 -maxdepth 1 -type d)"
test -s "$retained_directory/transport-stream.json"
test -s "$retained_directory/transport-stream.html"
test -s "$retained_directory/fragmented-mp4.json"
test -s "$retained_directory/fragmented-mp4.html"

cat >"$work_dir/validator-error-output" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"validated":false}\n' >"$2"
echo 'error: invalid segment'
EOF
chmod +x "$work_dir/validator-error-output"

if APPLE_HLS_MEDIASTREAMVALIDATOR="$work_dir/validator-error-output" \
  APPLE_HLS_REPORT="$work_dir/reporter-ok" \
  bash "$validator_runner" --require-tools >/dev/null 2>&1; then
  echo "Expected validator error output to fail." >&2
  exit 1
fi

cat >"$work_dir/validator-nonzero" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$work_dir/validator-nonzero"

if APPLE_HLS_MEDIASTREAMVALIDATOR="$work_dir/validator-nonzero" \
  APPLE_HLS_REPORT="$work_dir/reporter-ok" \
  bash "$validator_runner" --require-tools >/dev/null 2>&1; then
  echo "Expected a nonzero validator exit to fail." >&2
  exit 1
fi

cat >"$work_dir/validator-no-json" <<'EOF'
#!/usr/bin/env bash
echo 'Validation completed without output.'
EOF
chmod +x "$work_dir/validator-no-json"

if APPLE_HLS_MEDIASTREAMVALIDATOR="$work_dir/validator-no-json" \
  APPLE_HLS_REPORT="$work_dir/reporter-ok" \
  bash "$validator_runner" --require-tools >/dev/null 2>&1; then
  echo "Expected missing validator JSON to fail." >&2
  exit 1
fi

cat >"$work_dir/validator-invalid-json" <<'EOF'
#!/usr/bin/env bash
printf 'not-json\n' >"$2"
echo 'Validation completed.'
EOF
chmod +x "$work_dir/validator-invalid-json"

if APPLE_HLS_MEDIASTREAMVALIDATOR="$work_dir/validator-invalid-json" \
  APPLE_HLS_REPORT="$work_dir/reporter-ok" \
  bash "$validator_runner" --require-tools >/dev/null 2>&1; then
  echo "Expected invalid validator JSON to fail." >&2
  exit 1
fi

if APPLE_HLS_MEDIASTREAMVALIDATOR="$work_dir/missing-validator" \
  APPLE_HLS_REPORT="$work_dir/missing-reporter" \
  bash "$validator_runner" --require-tools >/dev/null 2>&1; then
  echo "Expected strict missing-tool validation to fail." >&2
  exit 1
fi

APPLE_HLS_MEDIASTREAMVALIDATOR="$work_dir/missing-validator" \
APPLE_HLS_REPORT="$work_dir/missing-reporter" \
  bash "$validator_runner" >"$work_dir/skipped.log"
grep -Fq 'apple-hls-conformance: NOT RUN' "$work_dir/skipped.log"

bash "$repo_root/Scripts/run_hls_quality_gates.sh" --help \
  | grep -Fq -- '--require-apple-tools'
if bash "$repo_root/Scripts/run_hls_quality_gates.sh" --unknown \
  >/dev/null 2>&1; then
  echo "Expected an unknown HLS quality-gate argument to fail." >&2
  exit 1
fi

echo "Apple HLS conformance gate fixture tests passed."
