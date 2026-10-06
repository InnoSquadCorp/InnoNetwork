#!/usr/bin/env bash
# Clean canonical-repository consumers. Candidate evidence never substitutes for a tag.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 2 ]] || { echo 'Usage: verify_published_consumer.sh <version|--candidate> <expected-sha>' >&2; exit 64; }
selection="$1"
expected_sha="$2"
python3 - "$selection" "$expected_sha" <<'PY'
import re, sys
selection, sha = sys.argv[1:]
number = r'(?:0|[1-9][0-9]*)'
identifier = r'(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
version = rf'{number}\.{number}\.{number}(?:-{identifier}(?:\.{identifier})*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
if (selection != '--candidate' and re.fullmatch(version, selection) is None) or re.fullmatch(r'[a-f0-9]{40}', sha) is None:
    raise SystemExit('tagged-consumer: invalid unprefixed version or immutable SHA')
PY
for variable in INNONETWORK_LOCAL_PATH SWIFTPM_MIRROR_CONFIG \
  GIT_CONFIG_PARAMETERS GIT_CONFIG GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE GIT_NAMESPACE GIT_TEMPLATE_DIR; do
  [[ -z "${!variable:-}" ]] || { echo "tagged-consumer: $variable must not override the public source" >&2; exit 65; }
done
for command_name in python3 xcrun; do
  command -v "$command_name" >/dev/null || { echo "tagged-consumer: missing $command_name" >&2; exit 69; }
done
# Disable inherited Git URL rewrites, including the legacy routing inputs above.
# A canonical lock URL alone does not prove a local mirror was not used.
# SwiftPM's cache/config/security roots below
# are also fresh and never use checkout-local dependency overrides or mirrors.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-public-consumer.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mode=published-tag
[[ "$selection" != --candidate ]] || mode=candidate-revision
output="$repo_root/.build/published-consumer/$mode/$expected_sha"
mkdir -p "$output"
rm -f "$output/result.json"
xcrun swift --version > "$output/swift-version.txt"

verify_lock() {
  python3 - "$1" "$selection" "$expected_sha" <<'PY'
import json, pathlib, sys
path, selection, expected = sys.argv[1:]
lock = json.loads(pathlib.Path(path).read_text())
if lock.get('version') not in (2, 3) or not isinstance(lock.get('pins'), list):
    raise SystemExit('tagged-consumer: malformed resolved graph')
pins = [p for p in lock['pins'] if p.get('identity') == 'innonetwork']
if len(pins) != 1:
    raise SystemExit('tagged-consumer: exactly one canonical Core pin is required')
pin = pins[0]
if pin.get('kind') != 'remoteSourceControl' or pin.get('location') not in (
    'https://github.com/InnoSquadCorp/InnoNetwork.git',
    'https://github.com/InnoSquadCorp/InnoNetwork',
):
    raise SystemExit('tagged-consumer: Core did not resolve from the canonical public repository')
state = pin.get('state', {})
if state.get('revision') != expected or state.get('branch') is not None:
    raise SystemExit('tagged-consumer: wrong Core revision or branch-only resolution')
if selection == '--candidate':
    if state.get('version') is not None:
        raise SystemExit('tagged-consumer: candidate evidence must be revision-selected')
elif state.get('version') != selection:
    raise SystemExit('tagged-consumer: public version does not match the requested release')
print('tagged-consumer: exact public dependency identity verified')
PY
}

for profile in default core-only; do
  package_dir="$work_dir/$profile"
  mkdir -p "$package_dir/Sources/ReleaseConsumer" "$package_dir/cache" "$package_dir/config" "$package_dir/security"
  python3 - "$package_dir" "$profile" "$selection" "$expected_sha" <<'PY'
from pathlib import Path
import sys
root, profile, selection, sha = sys.argv[1:]
constraint = f'revision: "{sha}"' if selection == '--candidate' else f'exact: "{selection}"'
traits = ', traits: []' if profile == 'core-only' else ''
settings = '.define("RELEASE_CONSUMER_MACROS")' if profile == 'default' else ''
Path(root, 'Package.swift').write_text(f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ReleaseConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/InnoSquadCorp/InnoNetwork.git", {constraint}{traits})],
    targets: [.executableTarget(
        name: "ReleaseConsumer",
        dependencies: [.product(name: "InnoNetwork", package: "innonetwork")],
        swiftSettings: [{settings}])]
)
''')
PY
  cat > "$package_dir/Sources/ReleaseConsumer/ReleaseConsumer.swift" <<'SWIFT'
import Foundation
import InnoNetwork

#if RELEASE_CONSUMER_MACROS
@APIDefinition(method: .get, path: "/health", auth: .anonymous)
private struct HealthEndpoint {
    typealias APIResponse = String
}
#endif

@main
enum ReleaseConsumer {
    static func main() throws {
        guard let url = URL(string: "https://example.invalid/health"),
            let http = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)
        else { fatalError("Invalid fixed smoke response") }
        let response = Response(statusCode: 204, data: Data(), response: http)
        let _: EmptyResponse = try AnyResponseDecoder<EmptyResponse>.noContent().decode(data: Data(), response: response)
        let request = EncodedRequest<EmptyResponse>(
            method: .get, path: "/health", auth: .anonymous, responseDecoder: .noContent())
        precondition(request.path == "/health")
        let client = DefaultNetworkClient(configuration: .safeDefaults(baseURL: url))
        _ = OperationNetworkClient(client: client)
        #if RELEASE_CONSUMER_MACROS
        precondition(HealthEndpoint().path == "/health")
        #endif
        print("Public Core consumer contract passed")
    }
}
SWIFT
  common=(--package-path "$package_dir" --cache-path "$package_dir/cache" --config-path "$package_dir/config"
          --security-path "$package_dir/security" --scratch-path "$package_dir/build")
  cp "$package_dir/Package.swift" "$output/$profile.Package.swift"
  xcrun swift package "${common[@]}" resolve 2>&1 | tee "$output/$profile.resolve.log"
  cp "$package_dir/Package.resolved" "$output/$profile.Package.resolved"
  verify_lock "$package_dir/Package.resolved"
  xcrun swift run "${common[@]}" --force-resolved-versions --configuration release ReleaseConsumer \
    2>&1 | tee "$output/$profile.run.log"
  verify_lock "$package_dir/Package.resolved"
done
python3 - "$output/result.json" "$mode" "$selection" "$expected_sha" <<'PY'
import json, pathlib, sys
path, mode, selection, sha = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    'mode': mode, 'version': None if mode == 'candidate-revision' else selection,
    'revision': sha, 'profiles': ['default', 'core-only'], 'configuration': 'release',
    'result': 'success', 'public_tag_verified': mode == 'published-tag',
}, indent=2) + '\n')
PY
printf 'tagged-consumer: %s %s passed both clean profiles at %s\n' "$mode" "$selection" "$expected_sha"
