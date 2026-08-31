#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export LC_ALL=C

require_tools=false
report_root=""

usage() {
  cat <<'USAGE'
Usage: bash Scripts/validate_hls_with_apple_tools.sh [options]

Validate the checked-in video and decoded-audio runtime HLS fixtures with
Apple's Media Stream Validator and HLS Report tools.

  --require-tools       Fail when either official Apple tool is unavailable.
  --report-root <path>  Retain JSON, HTML, and command logs below this path.
  -h, --help            Show this help.

The tools are a separate Apple Developer download. In ordinary CI the command
reports NOT RUN when Media Stream Validator is absent. Release preflight uses
--require-tools so a missing tool can never become a false-green release gate.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-tools)
      require_tools=true
      ;;
    --report-root)
      shift
      if [[ $# -eq 0 || -z "$1" ]]; then
        echo "apple-hls-conformance: --report-root requires a path" >&2
        exit 64
      fi
      report_root="$1"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "apple-hls-conformance: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

resolve_tool() {
  local override_name="$1"
  local command_name="$2"
  local override_value="${!override_name-}"

  if [[ -n "$override_value" ]]; then
    [[ -x "$override_value" ]] && printf '%s\n' "$override_value"
    return 0
  fi
  command -v "$command_name" 2>/dev/null || true
}

validator="$(resolve_tool APPLE_HLS_MEDIASTREAMVALIDATOR mediastreamvalidator)"
reporter="$(resolve_tool APPLE_HLS_REPORT hlsreport)"
if [[ -z "$reporter" ]]; then
  reporter="$(resolve_tool APPLE_HLS_REPORT hlsreport.py)"
fi

missing_tools=()
[[ -n "$validator" ]] || missing_tools+=("mediastreamvalidator")
[[ -n "$reporter" ]] || missing_tools+=("hlsreport")

if [[ -z "$validator" ]]; then
  message="apple-hls-conformance: NOT RUN; install Apple's HTTP Live Streaming Tools"
  if [[ "$require_tools" == true ]]; then
    echo "$message (missing: ${missing_tools[*]})" >&2
    exit 69
  fi
  echo "$message (missing: ${missing_tools[*]})"
  exit 0
fi

if [[ "$require_tools" == true && -z "$reporter" ]]; then
  echo "apple-hls-conformance: NOT RUN; required hlsreport is unavailable" >&2
  exit 69
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-apple-hls.XXXXXX")"
retain_reports=false
cleanup() {
  rm -rf "$scratch"
}
trap cleanup EXIT

fixture_root="$scratch/fixtures"
python3 Scripts/materialize_hls_conformance_fixtures.py \
  Tests/InnoNetworkHLSTests/HLSMediaFixtures.swift \
  "$fixture_root"

if [[ -n "$report_root" ]]; then
  mkdir -p "$report_root"
  report_directory="$(mktemp -d "$report_root/apple-hls-conformance.XXXXXX")"
  retain_reports=true
else
  report_directory="$scratch/reports"
  mkdir -p "$report_directory"
fi

validated_count=0
for fixture_name in transport-stream fragmented-mp4 audio-fmp4; do
  if [[ "$fixture_name" == "audio-fmp4" ]]; then
    playlist="$repo_root/Tests/Fixtures/HLSRuntime/audio-fmp4/index.m3u8"
  else
    playlist="$fixture_root/$fixture_name/index.m3u8"
  fi
  validation_json="$report_directory/$fixture_name.json"
  validator_log="$report_directory/$fixture_name-validator.log"

  if ! "$validator" -O "$validation_json" "$playlist" >"$validator_log" 2>&1; then
    cat "$validator_log" >&2
    echo "apple-hls-conformance: validator failed for $fixture_name" >&2
    exit 1
  fi
  cat "$validator_log"

  if [[ ! -s "$validation_json" ]]; then
    echo "apple-hls-conformance: validator omitted JSON for $fixture_name" >&2
    exit 1
  fi
  if ! python3 -m json.tool "$validation_json" >/dev/null; then
    echo "apple-hls-conformance: validator emitted invalid JSON for $fixture_name" >&2
    exit 1
  fi
  if grep -Eiq '(^|[[:space:]])error([[:space:]:]|$)|must[[:space:]]+fix' \
    "$validator_log"; then
    echo "apple-hls-conformance: validator reported a blocking issue for $fixture_name" >&2
    exit 1
  fi

  if [[ -n "$reporter" ]]; then
    report_html="$report_directory/$fixture_name.html"
    reporter_log="$report_directory/$fixture_name-report.log"
    if ! "$reporter" -o "$report_html" "$validation_json" >"$reporter_log" 2>&1; then
      cat "$reporter_log" >&2
      echo "apple-hls-conformance: hlsreport failed for $fixture_name" >&2
      exit 1
    fi
    cat "$reporter_log"
    python3 Scripts/check_apple_hls_report.py "$report_html"
  else
    echo "apple-hls-conformance: hlsreport NOT RUN; validator result only"
  fi

  validated_count=$((validated_count + 1))
done

if [[ "$retain_reports" == true ]]; then
  echo "apple-hls-conformance: reports retained at $report_directory"
fi
if [[ -n "$reporter" ]]; then
  echo "apple-hls-conformance: OK ($validated_count playlists)"
else
  echo "apple-hls-conformance: PARTIAL ($validated_count playlists; hlsreport NOT RUN)"
fi
