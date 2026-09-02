#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

skip_build=false
require_apple_tools=false
require_runtime_smoke=false
apple_report_root=""

usage() {
  cat <<'USAGE'
Usage: bash Scripts/run_hls_quality_gates.sh [options]

  --skip-build           Reuse an existing Swift test build.
  --require-apple-tools  Require Apple's Media Stream Validator and HLS Report.
  --require-runtime-smoke
                         Require the macOS 27 AVPlayer decoded-audio smoke.
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
    --require-runtime-smoke)
      require_runtime_smoke=true
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

runtime_arguments=()
if [[ "$skip_build" == true ]]; then
  runtime_arguments+=(--skip-build)
fi
if [[ "$require_runtime_smoke" == true ]]; then
  runtime_arguments+=(--require-supported-runtime)
fi
if [[ ${#runtime_arguments[@]} -gt 0 ]]; then
  runtime_output="$(
    bash Scripts/run_hls_runtime_smoke.sh "${runtime_arguments[@]}"
  )"
else
  # macOS Bash 3.2 treats an empty array expansion as unbound under `set -u`.
  runtime_output="$(bash Scripts/run_hls_runtime_smoke.sh)"
fi
printf '%s\n' "$runtime_output"

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

partial_reasons=()
if [[ "$runtime_output" == *"NOT RUN"* ]]; then
  partial_reasons+=("AVPlayer runtime smoke NOT RUN")
fi
if [[ "$apple_tool_output" == *"NOT RUN"* ]]; then
  partial_reasons+=("Apple tools NOT RUN")
fi

if [[ ${#partial_reasons[@]} -gt 0 ]]; then
  partial_summary="$(printf '; %s' "${partial_reasons[@]}")"
  partial_summary="${partial_summary:2}"
  echo "hls-quality-gates: PARTIAL (Swift gates passed; $partial_summary)"
else
  echo "hls-quality-gates: OK"
fi
