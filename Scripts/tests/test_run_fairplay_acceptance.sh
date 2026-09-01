#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/Scripts/run_fairplay_acceptance.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-fairplay-script.XXXXXX")"
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

if bash "$script" >"$test_root/missing.log" 2>&1; then
  echo "expected missing configuration to fail" >&2
  exit 1
fi
grep -q 'INNONETWORK_FAIRPLAY_DEVICE_DESTINATION' "$test_root/missing.log"

cat >"$test_root/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$INNONETWORK_FAIRPLAY_TEST_INVOCATIONS"
test -z "${INNONETWORK_FAIRPLAY_ACCEPTANCE_AUTHORIZATION:-}"
test -z "${INNONETWORK_FAIRPLAY_ACCEPTANCE_CONTENT_IDENTIFIER_BASE64:-}"
if [[ "$*" == *" test"* ]]; then
  test -n "$TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_ASSET_URL"
  test -n "$TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_CERTIFICATE_URL"
  test -n "$TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_CONTENT_IDENTIFIER_BASE64"
  test -n "$TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_KEY_ID"
  test -n "$TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_KSM_URL"
  test -n "$TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_REQUEST_IDENTIFIER"
  test "$TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_PROTOCOL_VERSIONS" = 3
  test "$TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_AUTHORIZATION" = secret-token
fi
SH
chmod +x "$test_root/xcodebuild"

export INNONETWORK_FAIRPLAY_DEVICE_DESTINATION='platform=iOS,id=000000000000000000000000'
export INNONETWORK_FAIRPLAY_DEVELOPMENT_TEAM='ABCDE12345'
export INNONETWORK_FAIRPLAY_ACCEPTANCE_ASSET_URL='https://media.example/asset.m3u8'
export INNONETWORK_FAIRPLAY_ACCEPTANCE_CERTIFICATE_URL='https://media.example/certificate'
export INNONETWORK_FAIRPLAY_ACCEPTANCE_CONTENT_IDENTIFIER_BASE64='Y29udGVudA=='
export INNONETWORK_FAIRPLAY_ACCEPTANCE_KEY_ID='acceptance-key'
export INNONETWORK_FAIRPLAY_ACCEPTANCE_KSM_URL='https://ksm.example/license'
export INNONETWORK_FAIRPLAY_ACCEPTANCE_REQUEST_IDENTIFIER='skd://asset/key'
export INNONETWORK_FAIRPLAY_ACCEPTANCE_AUTHORIZATION='secret-token'
export INNONETWORK_FAIRPLAY_XCODEBUILD="$test_root/xcodebuild"
export INNONETWORK_FAIRPLAY_TEST_INVOCATIONS="$test_root/invocations.log"

bash "$script" >"$test_root/success.log" 2>&1
grep -q -- '-scheme InnoNetworkFairPlayAcceptance-Package' \
  "$test_root/invocations.log"
grep -q -- '-only-testing:FairPlayAcceptanceTests/HLSFairPlayAcceptanceRuntimeTests' \
  "$test_root/invocations.log"
grep -q 'fairplay-acceptance: OK' "$test_root/success.log"
if grep -q 'secret-token' "$test_root/success.log"; then
  echo "authorization value leaked to output" >&2
  exit 1
fi

INNONETWORK_FAIRPLAY_DEVICE_DESTINATION='platform=iOS Simulator,id=test' \
  bash "$script" >"$test_root/simulator.log" 2>&1 && {
    echo "expected simulator destination to fail" >&2
    exit 1
  }
grep -q 'physical iOS device' "$test_root/simulator.log"

INNONETWORK_FAIRPLAY_ACCEPTANCE_PROTOCOL_VERSIONS='2,1' \
  bash "$script" >"$test_root/v2.log" 2>&1 && {
    echo "expected non-v3 protocol configuration to fail" >&2
    exit 1
  }
grep -q 'must include SPC version 3' "$test_root/v2.log"

INNONETWORK_FAIRPLAY_ACCEPTANCE_PROTOCOL_VERSIONS='3,,2' \
  bash "$script" >"$test_root/malformed-versions.log" 2>&1 && {
    echo "expected malformed protocol configuration to fail" >&2
    exit 1
  }
grep -q 'comma-separated positive integers' \
  "$test_root/malformed-versions.log"

echo "test_run_fairplay_acceptance: OK"
