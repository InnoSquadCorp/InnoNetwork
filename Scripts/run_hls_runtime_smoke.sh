#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

require_supported_runtime=false
skip_build=false

usage() {
  cat <<'USAGE'
Usage: bash Scripts/run_hls_runtime_smoke.sh [options]

  --require-supported-runtime  Fail instead of reporting NOT RUN before macOS 27.
  --skip-build                 Reuse an existing Swift test build.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-supported-runtime)
      require_supported_runtime=true
      ;;
    --skip-build)
      skip_build=true
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "hls-runtime-smoke: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

host_major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ ! "$host_major" =~ ^[0-9]+$ || "$host_major" -lt 27 ]]; then
  message="hls-runtime-smoke: NOT RUN; macOS 27 or newer is required"
  if [[ "$require_supported_runtime" == true ]]; then
    echo "$message" >&2
    exit 69
  fi
  echo "$message"
  exit 0
fi

fixture_root="$repo_root/Tests/Fixtures/HLSRuntime"
fixture="$fixture_root/audio-fmp4"

expect_hash() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "hls-runtime-smoke: unexpected fixture hash for $path: $actual" >&2
    exit 1
  fi
}

expect_hash "$fixture/index.m3u8" \
  "6b38193f703ab2b9f8243cf3c6350ab15d5914996c209e2840842404b76ab1ab"
expect_hash "$fixture/init.mp4" \
  "0d52787f0585a037f250d945f6fbbe937bada97c3a194e3c700af51978b089ce"
expect_hash "$fixture/segment-0.m4s" \
  "d48fbab061c99e1a66d6b37b6fb020904b21af03c90da83141dc02ad9f2cab4e"
expect_hash "$fixture/segment-1.m4s" \
  "1a35ff6feaea26609b1602a50cb69fa6ce4cc15ca8e6e269d777154e3ca2fddf"
expect_hash "$fixture/segment-2.m4s" \
  "863096b38668959a66385bc34a3f67e71c9664e1ebcabb45e7d82309f9272ee9"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-hls-runtime.XXXXXX")"
ready_file="$scratch/base-url"
server_log="$scratch/server.log"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

python3 Scripts/serve_hls_runtime_fixtures.py \
  "$fixture_root" \
  "$ready_file" \
  >"$server_log" 2>&1 &
server_pid=$!

for _ in {1..100}; do
  if [[ -s "$ready_file" ]]; then
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$server_log" >&2
    echo "hls-runtime-smoke: fixture server exited before readiness" >&2
    exit 1
  fi
  sleep 0.05
done

if [[ ! -s "$ready_file" ]]; then
  cat "$server_log" >&2
  echo "hls-runtime-smoke: fixture server readiness timed out" >&2
  exit 1
fi

base_url="$(tr -d '\r\n' <"$ready_file")"
playlist_url="$base_url/audio-fmp4/index.m3u8"
curl --fail --silent --show-error "$playlist_url" \
  | grep -Fxq '#EXT-X-ENDLIST'

test_command=(
  xcrun swift test
  --filter 'HLS(DecodedAudio|IntegratedTimeline|LocalPlayback|OfflineAsset)RuntimeTests'
)
if [[ "$skip_build" == true ]]; then
  test_command+=(--skip-build)
fi

if ! INNONETWORK_HLS_RUNTIME_PLAYLIST_URL="$playlist_url" \
  "${test_command[@]}"; then
  cat "$server_log" >&2
  exit 1
fi

echo "hls-runtime-smoke: OK (macOS AVPlayer timeline/local bridge, decoded PCM, and offline movpkg)"
