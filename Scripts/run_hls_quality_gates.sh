#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

skip_build=false
require_apple_tools=false
apple_report_root=""

usage() {
  cat <<'USAGE'
Usage: bash Scripts/run_hls_quality_gates.sh [options]

  --skip-build           Reuse an existing Swift test build.
  --require-apple-tools  Require Apple's Media Stream Validator and HLS Report.
  --apple-report-root <path>
                         Retain Apple-tool reports below this path.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      skip_build=true
      ;;
    --require-apple-tools)
      require_apple_tools=true
      ;;
    --apple-report-root)
      shift
      if [[ $# -eq 0 || -z "$1" ]]; then
        echo "--apple-report-root requires a path" >&2
        exit 64
      fi
      apple_report_root="$1"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

if [[ "$skip_build" == true ]]; then
  xcrun swift test \
    --skip-build \
    --filter 'HLS(MediaFixtureIntegrity|ParserMutation|ParserScaling|LiveRace|AssetDownloadEventHubRace)Tests'
else
  xcrun swift test \
    --filter 'HLS(MediaFixtureIntegrity|ParserMutation|ParserScaling|LiveRace|AssetDownloadEventHubRace)Tests'
fi

if [[ "$require_apple_tools" == true && -n "$apple_report_root" ]]; then
  apple_tool_output="$(
    bash Scripts/validate_hls_with_apple_tools.sh \
    --require-tools \
    --report-root "$apple_report_root"
  )"
elif [[ "$require_apple_tools" == true ]]; then
  apple_tool_output="$(
    bash Scripts/validate_hls_with_apple_tools.sh --require-tools
  )"
elif [[ -n "$apple_report_root" ]]; then
  apple_tool_output="$(
    bash Scripts/validate_hls_with_apple_tools.sh \
    --report-root "$apple_report_root"
  )"
else
  apple_tool_output="$(bash Scripts/validate_hls_with_apple_tools.sh)"
fi
printf '%s\n' "$apple_tool_output"

if [[ "$apple_tool_output" == *"NOT RUN"* ]]; then
  echo "hls-quality-gates: PARTIAL (Swift gates passed; Apple tools NOT RUN)"
else
  echo "hls-quality-gates: OK"
fi
