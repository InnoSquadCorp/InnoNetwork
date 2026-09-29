#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
xcrun swift build --jobs 2 --product InnoNetworkResumableRecoverySmoke
bin_dir="$(xcrun swift build --show-bin-path)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-resumable-recovery.XXXXXX")"
# Keep the small, credential-free evidence directory for inspection. The
# interrupted worker's immutable snapshot is isolated here, never in app data.
echo "Recovery fixture evidence: $fixture_dir"

for scenario in chunk finalize; do
  scenario_dir="$fixture_dir/$scenario"
  mkdir -p "$scenario_dir"
  "$bin_dir/InnoNetworkResumableRecoverySmoke" prepare "$scenario_dir"
  set +e
  "$bin_dir/InnoNetworkResumableRecoverySmoke" "interrupt-$scenario" "$scenario_dir"
  actual=$?
  set -e
  expected=86
  if [[ "$scenario" == "finalize" ]]; then expected=87; fi
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected fixture exit $expected, received $actual" >&2
    exit 1
  fi
  "$bin_dir/InnoNetworkResumableRecoverySmoke" "resume-$scenario" "$scenario_dir"
done
ownership_dir="$fixture_dir/ownership"
mkdir -p "$ownership_dir"
"$bin_dir/InnoNetworkResumableRecoverySmoke" ownership "$ownership_dir"
echo "resumable-process-recovery: PASS (two fresh-process recoveries; no live backend)"
