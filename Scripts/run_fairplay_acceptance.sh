#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="$repo_root/Tests/FairPlayAcceptance"
allow_provisioning_updates=false

usage() {
  cat <<'USAGE'
Usage: bash Scripts/run_fairplay_acceptance.sh [options]

Runs the SPC v3 renewal and downloaded-asset reopening gates on one physical
iOS device. FairPlay acceptance material is forwarded through test-runner
environment values instead of build settings.

Options:
  --allow-provisioning-updates  Let xcodebuild update signing assets.
  -h, --help                    Show this help.

Required environment:
  INNONETWORK_FAIRPLAY_DEVICE_DESTINATION
  INNONETWORK_FAIRPLAY_DEVELOPMENT_TEAM
  INNONETWORK_FAIRPLAY_ACCEPTANCE_ASSET_URL
  INNONETWORK_FAIRPLAY_ACCEPTANCE_CERTIFICATE_URL
  INNONETWORK_FAIRPLAY_ACCEPTANCE_CONTENT_IDENTIFIER_BASE64
  INNONETWORK_FAIRPLAY_ACCEPTANCE_KEY_ID
  INNONETWORK_FAIRPLAY_ACCEPTANCE_KSM_URL
  INNONETWORK_FAIRPLAY_ACCEPTANCE_REQUEST_IDENTIFIER

Optional environment:
  INNONETWORK_FAIRPLAY_ACCEPTANCE_AUTHORIZATION
  INNONETWORK_FAIRPLAY_ACCEPTANCE_PROTOCOL_VERSIONS  Defaults to 3.
  INNONETWORK_FAIRPLAY_ACCEPTANCE_TIMEOUT_SECONDS    Defaults to 60.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-provisioning-updates)
      allow_provisioning_updates=true
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "fairplay-acceptance: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

required_names=(
  INNONETWORK_FAIRPLAY_DEVICE_DESTINATION
  INNONETWORK_FAIRPLAY_DEVELOPMENT_TEAM
  INNONETWORK_FAIRPLAY_ACCEPTANCE_ASSET_URL
  INNONETWORK_FAIRPLAY_ACCEPTANCE_CERTIFICATE_URL
  INNONETWORK_FAIRPLAY_ACCEPTANCE_CONTENT_IDENTIFIER_BASE64
  INNONETWORK_FAIRPLAY_ACCEPTANCE_KEY_ID
  INNONETWORK_FAIRPLAY_ACCEPTANCE_KSM_URL
  INNONETWORK_FAIRPLAY_ACCEPTANCE_REQUEST_IDENTIFIER
)
missing_names=()
for name in "${required_names[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    missing_names+=("$name")
  fi
done
if [[ ${#missing_names[@]} -gt 0 ]]; then
  echo "fairplay-acceptance: missing required environment:" >&2
  printf '  %s\n' "${missing_names[@]}" >&2
  exit 64
fi

device_destination="$INNONETWORK_FAIRPLAY_DEVICE_DESTINATION"
development_team="$INNONETWORK_FAIRPLAY_DEVELOPMENT_TEAM"
if [[ ! "$device_destination" =~ ^platform=iOS,.*id=[^,]+ ]]; then
  echo \
    "fairplay-acceptance: destination must identify a physical iOS device by id" \
    >&2
  exit 64
fi
if [[ ! "$INNONETWORK_FAIRPLAY_DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "fairplay-acceptance: development team must be a 10-character team id" >&2
  exit 64
fi

https_names=(
  INNONETWORK_FAIRPLAY_ACCEPTANCE_ASSET_URL
  INNONETWORK_FAIRPLAY_ACCEPTANCE_CERTIFICATE_URL
  INNONETWORK_FAIRPLAY_ACCEPTANCE_KSM_URL
)
for name in "${https_names[@]}"; do
  if [[ ! "${!name}" =~ ^https:// ]]; then
    echo "fairplay-acceptance: $name must use HTTPS" >&2
    exit 64
  fi
done

protocol_versions="${INNONETWORK_FAIRPLAY_ACCEPTANCE_PROTOCOL_VERSIONS:-3}"
if [[ ! "$protocol_versions" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]]; then
  echo \
    "fairplay-acceptance: protocol versions must be comma-separated positive integers" \
    >&2
  exit 64
fi
if [[ ! ",$protocol_versions," =~ (^|,)3(,|$) ]]; then
  echo "fairplay-acceptance: protocol versions must include SPC version 3" >&2
  exit 64
fi
if ! printf '%s' \
  "$INNONETWORK_FAIRPLAY_ACCEPTANCE_CONTENT_IDENTIFIER_BASE64" \
  | /usr/bin/base64 -D >/dev/null 2>&1; then
  echo "fairplay-acceptance: content identifier is not valid base64" >&2
  exit 64
fi

xcodebuild_path="${INNONETWORK_FAIRPLAY_XCODEBUILD:-}"
if [[ -z "$xcodebuild_path" ]]; then
  xcodebuild_path="$(xcrun --find xcodebuild)"
fi
if [[ ! -x "$xcodebuild_path" ]]; then
  echo "fairplay-acceptance: xcodebuild executable is unavailable" >&2
  exit 69
fi

scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-fairplay.XXXXXX")"
cleanup() {
  if [[ -n "$scratch_root" && -d "$scratch_root" ]]; then
    rm -rf -- "$scratch_root"
  fi
}
trap cleanup EXIT

export \
  TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_ASSET_URL="$INNONETWORK_FAIRPLAY_ACCEPTANCE_ASSET_URL"
export \
  TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_CERTIFICATE_URL="$INNONETWORK_FAIRPLAY_ACCEPTANCE_CERTIFICATE_URL"
export \
  TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_CONTENT_IDENTIFIER_BASE64="$INNONETWORK_FAIRPLAY_ACCEPTANCE_CONTENT_IDENTIFIER_BASE64"
export \
  TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_KEY_ID="$INNONETWORK_FAIRPLAY_ACCEPTANCE_KEY_ID"
export \
  TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_KSM_URL="$INNONETWORK_FAIRPLAY_ACCEPTANCE_KSM_URL"
export \
  TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_REQUEST_IDENTIFIER="$INNONETWORK_FAIRPLAY_ACCEPTANCE_REQUEST_IDENTIFIER"
export \
  TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_PROTOCOL_VERSIONS="$protocol_versions"
export \
  TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_TIMEOUT_SECONDS="${INNONETWORK_FAIRPLAY_ACCEPTANCE_TIMEOUT_SECONDS:-60}"
if [[ -n "${INNONETWORK_FAIRPLAY_ACCEPTANCE_AUTHORIZATION:-}" ]]; then
  export \
    TEST_RUNNER_INNONETWORK_FAIRPLAY_ACCEPTANCE_AUTHORIZATION="$INNONETWORK_FAIRPLAY_ACCEPTANCE_AUTHORIZATION"
fi

# Keep acceptance credentials out of xcodebuild and dependency-build
# environments. Xcode forwards TEST_RUNNER_ values only to the test process.
unset \
  INNONETWORK_FAIRPLAY_ACCEPTANCE_ASSET_URL \
  INNONETWORK_FAIRPLAY_ACCEPTANCE_AUTHORIZATION \
  INNONETWORK_FAIRPLAY_ACCEPTANCE_CERTIFICATE_URL \
  INNONETWORK_FAIRPLAY_ACCEPTANCE_CONTENT_IDENTIFIER_BASE64 \
  INNONETWORK_FAIRPLAY_ACCEPTANCE_KEY_ID \
  INNONETWORK_FAIRPLAY_ACCEPTANCE_KSM_URL \
  INNONETWORK_FAIRPLAY_ACCEPTANCE_PROTOCOL_VERSIONS \
  INNONETWORK_FAIRPLAY_ACCEPTANCE_REQUEST_IDENTIFIER \
  INNONETWORK_FAIRPLAY_ACCEPTANCE_TIMEOUT_SECONDS

cd "$package_root"
"$xcodebuild_path" -list >/dev/null

test_command=(
  "$xcodebuild_path"
  -scheme InnoNetworkFairPlayAcceptance-Package
  -destination "$device_destination"
  -skipMacroValidation
  -derivedDataPath "$scratch_root/DerivedData"
  -only-testing:FairPlayAcceptanceTests/HLSFairPlayAcceptanceRuntimeTests
  DEVELOPMENT_TEAM="$development_team"
  CODE_SIGN_STYLE=Automatic
)
if [[ "$allow_provisioning_updates" == true ]]; then
  test_command+=(-allowProvisioningUpdates)
fi
test_command+=(test)

"${test_command[@]}"
echo \
  "fairplay-acceptance: OK (SPC v3 initial + renewal acceptance, persistent download + reopened offline playback)"
